import Foundation

// Pure logic: parsing, staleness, "today vs budget", formatting. Foundation only, so
// scripts/test.sh can compile it on its own with tests/TallyTests.swift.

enum Metric: String, CaseIterable, Sendable { case fiveHour, weekly }

struct SuddenJumpDetector {
    private var history: [String: [Reading]] = [:]
    private(set) var lastAlert: Date?

    init(lastAlert: Date? = nil) { self.lastAlert = lastAlert }

    mutating func update(window: String, reading: Reading, now: Date) -> Double? {
        guard reading.t <= now, now.timeIntervalSince(reading.t) <= 900,
              reading.resets.map({ $0 > now }) ?? true else { return nil }
        var recent = history[window] ?? []
        if let last = recent.last {
            guard reading.t > last.t else { return nil }
            if last.resets != reading.resets || (reading.resets == nil && reading.p < last.p) { recent.removeAll() }
        }
        recent.removeAll { reading.t.timeIntervalSince($0.t) > 900 }
        let lowest = recent.last.map({ reading.p > $0.p }) == true ? recent.lazy.map(\.p).min() : nil
        if recent.last?.p == reading.p { recent.removeLast() }
        recent.append(reading)
        history[window] = recent
        guard let lowest, reading.p - lowest >= 10, now.timeIntervalSince(lastAlert ?? .distantPast) >= 3600 else { return nil }
        lastAlert = now
        return reading.p - lowest
    }
}

enum LimitAlert: String, CaseIterable {
    case five80, five95, weekly80, weekly95, reset
}

struct LimitAlertState: Codable, Equatable {
    private var peak = 0.0
    private var resetsAt: Date?
    private var lastRead: Date?

    mutating func update(_ metric: Metric, reading: Reading?, now: Date) -> [LimitAlert] {
        var due: [LimitAlert] = []
        if let end = resetsAt, now >= end {
            if metric == .fiveHour && peak > 80 { due.append(.reset) }
            peak = 0
            lastRead = end
            resetsAt = nil
        }
        guard let reading, reading.t >= (lastRead ?? .distantPast), reading.t <= now,
              Staleness(age: now.timeIntervalSince(reading.t)) == .fresh,
              reading.resets.map({ $0 > now }) ?? true else { return due }
        if peak < 80 && reading.p >= 80 { due.append(metric == .fiveHour ? .five80 : .weekly80) }
        if peak < 95 && reading.p >= 95 { due.append(metric == .fiveHour ? .five95 : .weekly95) }
        peak = max(peak, reading.p)
        resetsAt = reading.resets ?? resetsAt
        lastRead = reading.t
        return due
    }
}

struct UsageWindow: Equatable, Sendable, Codable {
    var percent: Double
    var resetsAt: Date?
}

struct ServiceUsage: Equatable, Sendable, Codable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var extras: [String: UsageWindow] = [:]   // per-model weekly limits, e.g. "Sonnet"
    var readAt: Date                          // when the numbers were true (event time or fetch time)

    func staleness(now: Date) -> Staleness { Staleness(age: now.timeIntervalSince(readAt)) }
    func isStale(now: Date) -> Bool { staleness(now: now) != .fresh }

    /// The number for the menu bar, or nil when it is expired or missing. A plan without a
    /// 5-hour window (seen on Codex) falls back to its weekly window.
    func menuPercent(_ metric: Metric, now: Date) -> Double? {
        if staleness(now: now) == .expired { return nil }
        switch metric {
        case .fiveHour: return (fiveHour ?? weekly)?.percent
        case .weekly: return weekly?.percent
        }
    }
}

/// Where Claude numbers come from. The Keychain route is opt-in: `select` never builds the OAuth source when it is off.
enum ClaudeRoute {
    static func select<T>(live: Bool, file: () -> T, oauth: () -> T) -> T { live ? oauth() : file() }
}

struct UsageBackoff: Codable {
    private let minutes: Int
    let retryAt: Date

    init(after previous: Self?, now: Date) {
        switch previous?.minutes {
        case nil: minutes = 2
        case 2: minutes = 4
        case 4: minutes = 8
        default: minutes = 30
        }
        retryAt = now.addingTimeInterval(Double(minutes * 60))
    }

    func canRetry(at now: Date) -> Bool { now >= retryAt }
}

enum Staleness: Equatable {
    case fresh, stale(String), expired

    init(age: TimeInterval) {
        if age <= 15 * 60 { self = .fresh }
        else if age > 7 * 86400 { self = .expired }
        else if age >= 86400 { self = .stale("as of \(Int(age / 86400)) d ago") }
        else if age >= 3600 { self = .stale("as of \(Int(age / 3600)) h ago") }
        else { self = .stale("as of \(Int(age / 60)) min ago") }
    }

    var label: String? {
        switch self {
        case .fresh: nil
        case .stale(let age): age
        case .expired: "No recent reading"
        }
    }
}

// MARK: Claude

enum ClaudeParser {
    /// Body of GET api.anthropic.com/api/oauth/usage. Utilization is already a percent (0...100).
    static func parse(_ data: Data, readAt: Date) -> ServiceUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let o = root[key] as? [String: Any], let p = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(percent: p, resetsAt: (o["resets_at"] as? String).flatMap(parseISO))
        }
        var usage = ServiceUsage(fiveHour: window("five_hour"), weekly: window("seven_day"), readAt: readAt)
        for key in root.keys where key.hasPrefix("seven_day_") {
            guard let w = window(key) else { continue }
            let name = String(key.dropFirst("seven_day_".count))
            if name == "oauth_apps" { continue }
            usage.extras[name.prefix(1).uppercased() + name.dropFirst()] = w
        }
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }

    /// Claude Code's status line data: {"rate_limits":{"five_hour":{"used_percentage":2,"resets_at":<epoch s>},"seven_day":{...}}}.
    /// `readAt` is the file's modification time, so staleness works as for every other source.
    static func parseStatusLine(_ data: Data, readAt: Date) -> ServiceUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let o = limits[key] as? [String: Any], let p = (o["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(percent: p, resetsAt: (o["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let usage = ServiceUsage(fiveHour: window("five_hour"), weekly: window("seven_day"), readAt: readAt)
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }

    /// Access token and expiry from the JSON Claude Code keeps in the Keychain / credentials file.
    static func token(fromCredentials data: Data, now: Date) -> (token: String?, expired: Bool) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let t = o["accessToken"] as? String, !t.isEmpty else { return (nil, false) }
        if let ms = (o["expiresAt"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: ms / 1000) <= now {
            return (nil, true)
        }
        return (t, false)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Anthropic sends microseconds, which the fractional option can reject.
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return f.date(from: String(s[..<dot]) + String(s[tz...]))
        }
        return nil
    }
}

// MARK: Codex

enum CodexParser {
    /// Newest usable rate-limit event in a chunk of a rollout file (one JSON object per line).
    static func latest(in text: String) -> ServiceUsage? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let u = parse(line: Data(line.utf8)) { return u }
        }
        return nil
    }

    static func parse(line: Data) -> ServiceUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              (limits["limit_id"] as? String ?? "codex") == "codex",
              let ts = (root["timestamp"] as? String).flatMap(ClaudeParser.parseISO) else { return nil }
        var usage = ServiceUsage(readAt: ts)
        for key in ["primary", "secondary"] {
            guard let o = limits[key] as? [String: Any],
                  let p = (o["used_percent"] as? NSNumber)?.doubleValue,
                  let minutes = (o["window_minutes"] as? NSNumber)?.doubleValue else { continue }
            let w = UsageWindow(percent: p, resetsAt: (o["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            if minutes <= 360 { usage.fiveHour = w } else { usage.weekly = w }
        }
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }
}

// MARK: Today vs budget

struct DayBaseline: Codable, Equatable, Sendable {
    var last: Reading
    var since: Date?
    var used: Double
    var alerted: [Int] = []         // 80, 100
}

enum Today {
    static func record(_ previous: DayBaseline?, _ reading: Reading, calendar: Calendar = .current) -> DayBaseline {
        guard let previous else { return DayBaseline(last: reading, since: reading.t, used: 0) }
        let last = previous.last
        guard reading.t > last.t else { return previous }
        let sameDay = calendar.isDate(last.t, inSameDayAs: reading.t)
        let resetMoved = last.resets.flatMap { old in reading.resets.map { $0.timeIntervalSince(old) > 3600 } } ?? false
        let delta = resetMoved || reading.p < last.p ? reading.p : reading.p - last.p
        return DayBaseline(last: reading, since: sameDay ? previous.since : nil,
                           used: (sameDay ? previous.used : 0) + delta, alerted: sameDay ? previous.alerted : [])
    }

    /// Alert levels (80, 100) newly crossed by `used` against `budget`.
    static func newAlerts(used: Double, budget: Double, alerted: [Int]) -> [Int] {
        guard budget > 0 else { return [] }
        return [80, 100].filter { used >= budget * Double($0) / 100 && !alerted.contains($0) }
    }
}

// MARK: Pace

/// One window reading: when it was true, the percent, and when that window resets.
struct Reading: Codable, Equatable, Sendable {
    var t: Date
    var p: Double
    var resets: Date?
}

/// Straight-line projection from a window's recent provider readings.
enum Pace {
    /// How the ring buffer of a window is kept: one reading per `spacing`, the last `capacity`
    /// of them, covering a window of `length`.
    static func keeping(_ m: Metric) -> (spacing: TimeInterval, capacity: Int, length: TimeInterval) {
        if m == .fiveHour { return (spacing: 300, capacity: 64, length: 18_000) }
        return (spacing: 1_800, capacity: 340, length: 604_800)
    }

    /// Percent the bar should outline as "where the pace lands" (100 when it reaches 100%); nil when unknown.
    static func landing(_ r: Result?) -> Double? {
        switch r {
        case .reaches: 100
        case .finishes(let p): p
        default: nil
        }
    }

    enum Result: Equatable, Sendable {
        case gathering
        case reaches(Date)       // hits 100% at this time, before the window resets
        case finishes(Double)    // projected percent at reset
    }

    /// Appends `r` unless it is older than, or within the spacing of, the newest reading. Keeps the last `capacity`.
    static func record(_ buffer: [Reading], _ r: Reading, _ m: Metric = .weekly) -> [Reading] {
        let k = keeping(m)
        if let last = buffer.last, r.t.timeIntervalSince(last.t) < k.spacing { return buffer }
        return Array((buffer + [r]).suffix(k.capacity))
    }

    /// Readings of the window that `current` belongs to, oldest first, for the history strip.
    static func epoch(_ buffer: [Reading], resets: Date?, _ m: Metric) -> [Reading] {
        guard let resets else { return [] }
        let start = resets.addingTimeInterval(-keeping(m).length)
        return buffer.filter { r in r.t >= start && r.resets.map { abs($0.timeIntervalSince(resets)) <= 3600 } ?? false }
    }

    /// `current` is the newest reading; `buffer` the history before it. Only points in the same
    /// window epoch count: going back in time, a higher percent or a reset time more than an hour
    /// off means the window rolled over, so everything before it is dropped.
    static func project(_ buffer: [Reading], current: Reading, metric: Metric, now: Date) -> Result {
        guard let resets = current.resets, resets > now, resets > current.t else { return .gathering }
        let lookback: TimeInterval = metric == .fiveHour ? 3600 : 86400
        let start = max(current.t.addingTimeInterval(-lookback), resets.addingTimeInterval(-keeping(metric).length))
        var first = current
        var count = 1
        for r in buffer.reversed() where r.t >= start && r.t < first.t {
            if r.p > first.p + 0.001 { break }
            guard let end = r.resets, abs(end.timeIntervalSince(resets)) <= 3600 else { break }
            first = r
            count += 1
        }
        guard count >= 3 else { return .gathering }
        if current.p >= 100 { return .reaches(current.t) }
        let span = current.t.timeIntervalSince(first.t)
        let rate = (current.p - first.p) / span                          // percent per second
        if rate <= 1e-9 { return .finishes(current.p) }
        let atReset = current.p + rate * resets.timeIntervalSince(current.t)
        if atReset > 100 { return .reaches(current.t.addingTimeInterval((100 - current.p) / rate)) }
        return .finishes(atReset)
    }
}

// MARK: Formatting

enum Fmt {
    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))" }

    static func remaining(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        if m >= 1440 { return "\(m / 1440)d \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    /// "resets in 2h 15m, 14:30" (weekly resets get the weekday: "Tue 03:00").
    static func reset(_ date: Date, now: Date, weekday: Bool, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        f.dateFormat = weekday ? "EEE HH:mm" : "HH:mm"
        return "resets in \(remaining(date.timeIntervalSince(now))), \(f.string(from: date))"
    }

    /// "14:02", or "Sat 14:00" when the day differs from `now`.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    static func pace(_ r: Pace.Result, now: Date, calendar: Calendar = .current) -> String {
        switch r {
        case .gathering: return "Pace shows after a few readings"
        case .reaches(let d): return "At this pace you reach 100% around \(clock(d, now: now, calendar: calendar))"
        case .finishes(let p): return "On pace to finish at \(percent(p))%"
        }
    }

    static func ago(_ seconds: TimeInterval) -> String { "\(remaining(seconds)) ago" }

    static func forecast(_ result: Pace.Result, readAt: Date, reset: Date, calendar: Calendar = .current) -> String? {
        switch result {
        case .gathering: return nil
        case .finishes(let percent): return "At this pace: about \(self.percent(percent))% at reset"
        case .reaches(let time):
            if time == readAt { return "Limit reached before reset" }
            let lead = reset.timeIntervalSince(time)
            let early = lead >= 3600 ? "\(Int((lead / 3600).rounded())) h" : lead >= 60 ? "\(Int(lead / 60)) min" : "<1 min"
            return "At this pace you run out around \(clock(time, now: readAt, calendar: calendar)), \(early) before reset"
        }
    }
}
