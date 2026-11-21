import Foundation
import Observation
import QuartzCore
import UserNotifications

struct ServiceState: Equatable, Sendable {
    var usage: ServiceUsage?
    var error: String?
}

/// `-perf` prints timings to stdout.
enum Perf {
    nonisolated(unsafe) static var on = false
    static func log(_ s: @autoclosure () -> String) { if on { print("perf: \(s())") } }
    static func ms(since t: CFTimeInterval) -> String { String(format: "%.1f ms", (CACurrentMediaTime() - t) * 1000) }
}

@MainActor @Observable
final class TallyModel {
    var claude = ServiceState()
    var codex = ServiceState()
    var today: [Service: Double] = [:]
    var todaySince: [Service: Date] = [:]
    var readings: [String: [Reading]] = [:]   // ring buffers, key "claude.weekly"
    var windowPick: [Service: Metric] = [:]    // the window shown per service in the panel (not persisted)
    var dayBase: [Service: Double] = [:]       // weekly % at the start of today, for the budget marker
    var tokens: [ProjectTokens]?           // today's Claude Code tokens per project; nil until the first read
    var tokensOpen = false { didSet { if tokensOpen { refreshTokens() } } }
    var openTick = 0                       // bumped each time the panel opens; the needles swing on it
    var now = Date()                       // moves on the 2-minute tick so the menu bar notices staleness
    let settings: Settings
    private let defaults: UserDefaults
    private let live: Bool
    private var lastClaudeFetch = Date.distantPast
    var usageBackoff: UsageBackoff?
    private var retryTimer: Timer?
    private var fetching = false
    private var readingCodex = false
    private var watcher: FolderWatcher?
    private var claudeWatcher: FolderWatcher?
    private var watchedClaudePath = ""
    private var timer: Timer?
    private var notificationPermission: Task<Bool, Never>?
    private var jumpDetector: SuddenJumpDetector
    private let scanner = TranscriptScanner()

    init(settings: Settings, defaults: UserDefaults = .standard, live: Bool = true) {
        self.settings = settings
        self.defaults = defaults
        self.live = live
        jumpDetector = SuddenJumpDetector(lastAlert: defaults.object(forKey: "lastSuddenJumpAlert") as? Date)
        usageBackoff = defaults.data(forKey: "usageBackoff").flatMap { try? JSONDecoder().decode(UsageBackoff.self, from: $0) }
        // Last known data is on screen from the first frame; it goes stale on its own.
        for s in Service.allCases {
            let usage = defaults.data(forKey: "last.\(s.rawValue)").flatMap { try? JSONDecoder().decode(ServiceUsage.self, from: $0) }
            if s == .claude { claude = ServiceState(usage: usage) } else { codex = ServiceState(usage: usage) }
            for m in Metric.allCases {
                let k = Self.key(s, m)
                readings[k] = defaults.data(forKey: "readings2.\(k)").flatMap { try? JSONDecoder().decode([Reading].self, from: $0) } ?? []
            }
            recordToday(s, allowAlerts: false)
        }
    }

    func state(_ s: Service) -> ServiceState { s == .claude ? claude : codex }

    var showsClaudeSetup: Bool {
        settings.showClaude && claude.error != nil && claude.usage == nil && (!settings.showCodex || codex.usage == nil)
    }

    func start() {
        guard live else { return }
        refreshCodex()
        refreshClaude(force: true)
        watcher = FolderWatcher(path: CodexSource.root.path) { [weak self] in
            MainActor.assumeIsolated { self?.refreshCodex() }
        }
        watchClaudeFile()
        // One slow tick: Claude's 2-minute poll, re-checks staleness, and retries a Codex folder created later.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        for service in Service.allCases where settings.shows(service) {
            checkLimitAlerts(service, .fiveHour, reading: nil, now: now)
        }
        if watcher == nil {
            watcher = FolderWatcher(path: CodexSource.root.path) { [weak self] in MainActor.assumeIsolated { self?.refreshCodex() } }
        }
        watchClaudeFile()
        refreshCodex()
        refreshClaude(force: true)
    }

    /// FSEvents on the status line file's folder; re-created when the path setting changes.
    private func watchClaudeFile() {
        let path = settings.claudeFilePath
        let dir = URL(fileURLWithPath: ClaudeFile.expand(path)).deletingLastPathComponent().path
        guard claudeWatcher == nil || path != watchedClaudePath else { return }
        watchedClaudePath = path
        claudeWatcher = FolderWatcher(path: dir) { [weak self] in MainActor.assumeIsolated { self?.readClaudeFile() } }
    }

    /// Default Claude route: the status line file, read off the main thread. Never touches the Keychain or the network.
    func readClaudeFile() {
        guard live, settings.showClaude, !settings.liveClaude else { return }
        let path = settings.claudeFilePath
        Task {
            let usage = await Task.detached { ClaudeFile.read(path: path) }.value
            guard !settings.liveClaude else { return }
            if let usage {
                if claude.usage != usage || claude.error != nil { claude = ServiceState(usage: usage) }
                save(.claude)
            } else if claude.usage == nil { claude.error = "No Claude numbers yet. Use Set up in Settings." }
            recordToday(.claude)
        }
    }

    /// Panel opens: swing the needles and refresh in the background (Claude debounced to 30 s).
    func panelOpened() {
        openTick += 1
        guard live else { return }
        if settings.showClaude { refreshTokens() }
        refreshCodex()
        refreshClaude(force: false)
    }

    /// Today's tokens per project, read by the scanner actor (off main).
    func refreshTokens() {
        guard live else { return }
        Task { tokens = await scanner.today() }
    }

    /// Reads the newest Codex event off the main thread and publishes it in one assignment.
    func refreshCodex() {
        guard live, settings.showCodex, !readingCodex else { return }
        readingCodex = true
        let t0 = CACurrentMediaTime()
        Task {
            let usage = await Task.detached { CodexSource.read() }.value
            readingCodex = false
            Perf.log("refresh codex \(Perf.ms(since: t0))")
            if let usage {
                if codex.usage != usage || codex.error != nil { codex = ServiceState(usage: usage) }
                save(.codex)
            } else if codex.usage == nil { codex.error = "No Codex usage found yet. Run Codex once." }
            recordToday(.codex)
        }
    }

    func refreshClaude(force: Bool) {
        guard live, settings.showClaude, !fetching else { return }
        if !ClaudeRoute.select(live: settings.liveClaude, file: { false }, oauth: { true }) { readClaudeFile(); return }   // Keychain and network only when opted in
        if let usageBackoff, !usageBackoff.canRetry(at: Date()) { scheduleRetry(usageBackoff); return }
        guard Date().timeIntervalSince(lastClaudeFetch) >= (force ? 120 : 30) - 1 else { return }
        retryTimer?.invalidate(); retryTimer = nil
        fetching = true
        lastClaudeFetch = Date()
        let t0 = CACurrentMediaTime()
        Task {
            let result = await ClaudeSource.fetch()
            fetching = false
            Perf.log("refresh claude \(Perf.ms(since: t0)) (network)")
            switch result {
            case .failure(.busy):
                let backoff = UsageBackoff(after: usageBackoff, now: Date())
                usageBackoff = backoff
                defaults.set(try? JSONEncoder().encode(backoff), forKey: "usageBackoff")
                if settings.liveClaude { claude.error = nil; scheduleRetry(backoff) }
                return
            case .success(let usage):
                if settings.liveClaude { claude = ServiceState(usage: usage); save(.claude) }
            case .failure(.message(let text)):
                if settings.liveClaude { claude.error = text }
            }
            if usageBackoff != nil { usageBackoff = nil; defaults.removeObject(forKey: "usageBackoff") }
            guard settings.liveClaude else { return }
            recordToday(.claude)
        }
    }

    private func scheduleRetry(_ backoff: UsageBackoff) {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, backoff.retryAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                if self.settings.liveClaude { self.refreshClaude(force: true) }
            }
        }
    }

    // MARK: Cache, readings, pace

    static func key(_ s: Service, _ m: Metric) -> String { "\(s.rawValue).\(m.rawValue)" }

    /// Last good reading and the pace ring buffers survive a restart (numbers only, never the token).
    private func save(_ s: Service) {
        guard let usage = state(s).usage else { return }
        let now = Date()
        if let d = try? JSONEncoder().encode(usage) { defaults.set(d, forKey: "last.\(s.rawValue)") }
        if live, !settings.isQA, settings.shows(s), settings.suddenJumpAlerts {
            func checkJump(_ window: UsageWindow?, key: String, label: String) {
                guard let window else { return }
                let reading = Reading(t: usage.readAt, p: window.percent, resets: window.resetsAt)
                guard let jump = jumpDetector.update(window: "\(s.rawValue).\(key)", reading: reading, now: now) else { return }
                defaults.set(now, forKey: "lastSuddenJumpAlert")
                let content = UNMutableNotificationContent()
                content.title = "\(s.name) usage jumped \(Fmt.percent(jump))% in 15 min"
                content.body = label
                deliver(content, id: "tally.suddenJump")
            }
            checkJump(usage.fiveHour, key: "fiveHour", label: "5-hour limit")
            checkJump(usage.weekly, key: "weekly", label: "Weekly limit")
            for (name, window) in usage.extras { checkJump(window, key: "model.\(name)", label: "\(name) weekly limit") }
        }
        for m in Metric.allCases {
            guard let w = m == .fiveHour ? usage.fiveHour : usage.weekly else { continue }
            let k = Self.key(s, m)
            let reading = Reading(t: usage.readAt, p: w.percent, resets: w.resetsAt)
            checkLimitAlerts(s, m, reading: reading, now: now)
            let buffer = Pace.record(readings[k] ?? [], reading, m)
            if buffer != readings[k] {
                readings[k] = buffer
                if let d = try? JSONEncoder().encode(buffer) { defaults.set(d, forKey: "readings2.\(k)") }
            }
        }
    }

    func window(_ s: Service, _ m: Metric) -> UsageWindow? { m == .fiveHour ? state(s).usage?.fiveHour : state(s).usage?.weekly }

    /// The window shown for a service: the panel pick, else the menu bar metric, else whichever window exists.
    func metric(for s: Service) -> Metric {
        let u = state(s).usage
        let has: (Metric) -> Bool = { $0 == .fiveHour ? u?.fiveHour != nil : u?.weekly != nil }
        if let p = windowPick[s], has(p) { return p }
        if has(settings.metric) { return settings.metric }
        return has(.fiveHour) ? .fiveHour : .weekly
    }

    /// This window's readings, for the history strip.
    func series(_ s: Service, _ m: Metric) -> [Reading] {
        Pace.epoch(readings[Self.key(s, m)] ?? [], resets: window(s, m)?.resetsAt, m)
    }

    /// Projection of a window; nil when there is no fresh reading of it.
    func pace(_ s: Service, _ m: Metric, now: Date) -> Pace.Result? {
        guard let u = state(s).usage, !u.isStale(now: now), let w = window(s, m) else { return nil }
        return Pace.project(readings[Self.key(s, m)] ?? [], current: Reading(t: u.readAt, p: w.percent, resets: w.resetsAt), metric: m, now: now)
    }

    /// Weekly % where today's budget runs out (start of day plus budget); nil when unknown.
    func budgetLimit(_ s: Service) -> Double? { dayBase[s].map { $0 + settings.budget(s) } }

    // MARK: Today vs budget

    func setFake(claude: ServiceState, codex: ServiceState, today: [Service: Double], readings: [String: [Reading]] = [:], dayBase: [Service: Double] = [:]) {
        self.claude = claude; self.codex = codex; self.today = today; self.readings = readings; self.dayBase = dayBase
    }

    private func recordToday(_ s: Service, allowAlerts: Bool = true) {
        guard let usage = state(s).usage, let weekly = usage.weekly else { return }
        let key = "baseline.\(s.rawValue)"
        let saved = defaults.data(forKey: key)
        let previous = saved.flatMap { try? JSONDecoder().decode(DayBaseline.self, from: $0) }
        let seed = previous ?? readings[Self.key(s, .weekly)]?.reduce(nil as DayBaseline?) { Today.record($0, $1) }
        var base = Today.record(seed, Reading(t: usage.readAt, p: weekly.percent, resets: weekly.resetsAt))
        if previous == nil, let saved {
            struct LegacyAlerts: Decodable { let day: String; let alerted: [Int] }
            let date = Calendar.current.dateComponents([.year, .month, .day], from: base.last.t)
            let day = String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
            if let legacy = try? JSONDecoder().decode(LegacyAlerts.self, from: saved), legacy.day == day { base.alerted = legacy.alerted }
        }
        let current = Calendar.current.isDateInToday(base.last.t) && base.last.t == usage.readAt
        today[s] = current ? base.used : nil
        todaySince[s] = current ? base.since : nil
        dayBase[s] = current ? weekly.percent - base.used : nil
        if current, allowAlerts, settings.alerts, !usage.isStale(now: Date()) {
            let fire = Today.newAlerts(used: base.used, budget: settings.budget(s), alerted: base.alerted)
            for level in fire { notify(s, level: level, used: base.used) }
            base.alerted += fire
        }
        if base != previous, let d = try? JSONEncoder().encode(base) { defaults.set(d, forKey: key) }
    }

    private func notify(_ s: Service, level: Int, used: Double) {
        let c = UNMutableNotificationContent()
        c.title = "\(s.name): \(level)% of today's budget"
        let period = todaySince[s].map { "since \(Fmt.clock($0, now: Date()))" } ?? "today"
        c.body = "\(Fmt.percent(used))% of the weekly limit used \(period) (budget \(Fmt.percent(settings.budget(s)))%)."
        deliver(c, id: "tally.\(s.rawValue).\(level)")
    }

    private func checkLimitAlerts(_ service: Service, _ metric: Metric, reading: Reading?, now: Date) {
        guard live, !settings.isQA, settings.shows(service) else { return }
        let key = "limitAlerts.\(Self.key(service, metric))"
        let previous = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LimitAlertState.self, from: $0) } ?? LimitAlertState()
        var state = previous
        let due = state.update(metric, reading: reading, now: now)
        if state != previous { defaults.set(try? JSONEncoder().encode(state), forKey: key) }
        for alert in due where settings[alert] {
            let content = UNMutableNotificationContent()
            if alert == .reset {
                content.title = "Your 5-hour limit has reset"
                content.body = service.name
            } else {
                let level = alert == .five80 || alert == .weekly80 ? 80 : 95
                content.title = "\(service.name): \(level)% of your \(metric == .fiveHour ? "5-hour" : "weekly") limit"
            }
            deliver(content, id: "tally.\(service.rawValue).\(alert.rawValue)")
        }
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) {
        guard live, !settings.isQA else { return }
        let center = UNUserNotificationCenter.current()
        if notificationPermission == nil {
            notificationPermission = Task {
                defer { notificationPermission = nil }
                switch await center.notificationSettings().authorizationStatus {
                case .authorized, .provisional: return true
                case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) == true
                default: return false
                }
            }
        }
        let permission = notificationPermission
        Task {
            guard await permission?.value == true else { return }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
