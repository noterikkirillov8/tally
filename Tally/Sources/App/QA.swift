import AppKit
import SwiftUI

/// `Tally -qa <dir>`: draws the real views with fake data into PNGs (no permissions, no network,
/// no real settings), then quits.
@MainActor
enum QA {
    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(where: { $0 == "-qa" || $0 == "-intro-preview" }), i + 1 < args.count else { return false }
        let introOnly = args[i] == "-intro-preview"
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            if introOnly { intro(dir) } else { run(dir); intro(dir); usageBusy(dir) }
            NSApp.terminate(nil)
        }
        return true
    }

    static func usage(five: Double?, week: Double, extras: [String: Double] = [:], age: TimeInterval = 120) -> ServiceState {
        let now = Date()
        func w(_ p: Double, _ hours: Double) -> UsageWindow { .init(percent: p, resetsAt: now.addingTimeInterval(hours * 3600)) }
        return ServiceState(usage: ServiceUsage(fiveHour: five.map { w($0, 2.25) }, weekly: w(week, 74),
                                                extras: extras.mapValues { w($0, 74) }, readAt: now.addingTimeInterval(-age)))
    }

    /// Renders a SwiftUI view into a PNG from a window that is never shown.
    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false; w.backgroundColor = .clear; w.isReleasedWhenClosed = false
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))     // never ordered front: nothing appears on screen
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Start, middle and end frame of every intro scene, plus the self test frames of scene 1.
    private static func intro(_ dir: URL) {
        for scene in IntroScene.allCases {
            for (tag, k) in [("a-start", 0.04), ("b-middle", 0.5), ("c-end", 1.0)] {
                render(IntroChrome(index: scene.rawValue) { IntroStage(scene: scene, t: scene.duration * k) },
                       size: NSSize(width: 640, height: 440), to: dir.appendingPathComponent("intro-\(scene.rawValue + 1)-\(tag).png"))
            }
        }
        for (tag, t) in [("d-selftest-flash", 1.15), ("e-selftest-zero", 1.3), ("f-selftest-rising", 2.1)] {
            render(IntroChrome(index: 0) { IntroStage(scene: .levels, t: t) }, size: NSSize(width: 640, height: 440),
                   to: dir.appendingPathComponent("intro-1-\(tag).png"))
        }
    }

    static func forecast(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.forecast")!
        let model = TallyModel(settings: Settings(defaults: defaults, qa: true), defaults: defaults, live: false)
        let readAt = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 21, minute: 40))!
        let short = UsageWindow(percent: 62, resetsAt: readAt.addingTimeInterval(7200))
        let week = UsageWindow(percent: 51, resetsAt: readAt.addingTimeInterval(25 * 3600 + 1200))
        let sample = ServiceState(usage: ServiceUsage(fiveHour: short, weekly: week, extras: [:], readAt: readAt))
        model.setFake(claude: sample, codex: sample, today: [:], readings: [
            TallyModel.key(.claude, .fiveHour): [Reading(t: readAt.addingTimeInterval(-3600), p: 54, resets: short.resetsAt), Reading(t: readAt.addingTimeInterval(-1800), p: 58, resets: short.resetsAt)],
            TallyModel.key(.codex, .weekly): [Reading(t: readAt.addingTimeInterval(-43200), p: 15, resets: week.resetsAt), Reading(t: readAt.addingTimeInterval(-21600), p: 33, resets: week.resetsAt)]
        ])
        model.windowPick = [.claude: .fiveHour, .codex: .weekly]
        let view = VStack(spacing: 0) {
            ServiceCard(model: model, service: .claude, now: readAt)
            KitDivider()
            ServiceCard(model: model, service: .codex, now: readAt)
        }.frame(width: Theme.width).background(KitColor.window).environment(\.colorScheme, .dark).environment(\.tallyQA, QAFrame(lit: 1, entrance: 1))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("29-reset-forecast.png"))
        }
    }

    static func usedSince(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.usedSince")!
        let model = TallyModel(settings: Settings(defaults: defaults, qa: true), defaults: defaults, live: false)
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3600)
        var sample = usage(five: nil, week: 24)
        sample.usage?.readAt = end
        let first = Today.record(nil, Reading(t: start, p: 21, resets: nil))
        let latest = Today.record(first, Reading(t: end, p: 24, resets: nil))
        model.setFake(claude: ServiceState(), codex: sample, today: [.codex: latest.used], dayBase: [.codex: 21])
        model.todaySince[.codex] = latest.since
        let card = ServiceCard(model: model, service: .codex, now: end).frame(width: Theme.width)
            .background(KitColor.window).environment(\.colorScheme, .dark).environment(\.tallyQA, QAFrame(lit: 1, entrance: 1))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("24-used-since.png"))
        }
    }

    static func usageBusy(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.usageBusy")!
        let settings = Settings(defaults: defaults, qa: true)
        settings.liveClaude = true
        let model = TallyModel(settings: settings, defaults: defaults, live: false)
        let now = Calendar.current.date(bySettingHour: 21, minute: 38, second: 0, of: Date())!
        var sample = usage(five: 34, week: 61)
        sample.usage?.readAt = now.addingTimeInterval(-120)
        sample.usage?.fiveHour?.resetsAt = now.addingTimeInterval(8100)
        model.setFake(claude: sample, codex: ServiceState(), today: [:])
        model.usageBackoff = UsageBackoff(after: nil, now: now)
        let card = ServiceCard(model: model, service: .claude, now: now).frame(width: Theme.width)
            .background(KitColor.window).environment(\.colorScheme, .dark).environment(\.tallyQA, QAFrame(lit: 1, entrance: 1))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("25-usage-busy.png"))
        }
    }

    static func staleCodex(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.staleCodex")!
        let model = TallyModel(settings: Settings(defaults: defaults, qa: true), defaults: defaults, live: false)
        let sample = usage(five: nil, week: 48, age: 2 * 3600)
        model.setFake(claude: ServiceState(), codex: sample, today: [:])
        let card = ServiceCard(model: model, service: .codex, now: Date()).frame(width: Theme.width)
            .background(KitColor.window).environment(\.colorScheme, .dark).environment(\.tallyQA, QAFrame(lit: 1, entrance: 1))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("26-stale-codex.png"))
        }
    }

    static func claudeSetup(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.claudeSetup")!
        let model = TallyModel(settings: Settings(defaults: defaults, qa: true), defaults: defaults, live: false)
        model.setFake(claude: ServiceState(error: "No Claude numbers yet."), codex: ServiceState(), today: [:])
        model.tokens = [ProjectTokens(name: "Paper Planes", tokens: 1240)]
        let panel = PopoverView(model: model, state: PanelState(), qa: QAFrame(lit: 1, entrance: 1))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("27-claude-setup.png"))
        }
    }

    static func limitAlerts(_ dir: URL) {
        let defaults = UserDefaults(suiteName: "Tally.qa.limitAlerts")!
        let settings = Settings(defaults: defaults, qa: true)
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Tally settings · Alerts").font(KitFont.title).foregroundStyle(KitColor.text)
            LimitAlertSettings(settings: settings)
        }.padding(20).frame(width: 520).background(KitColor.window).kitAccent(Theme.claude).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("28-settings-alerts.png"))
        }
    }

    private static func run(_ dir: URL) {
        let suite = "com.erikkirillov.Tally.qa"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults, qa: true)
        let model = TallyModel(settings: settings, defaults: defaults, live: false)

        func shot(_ name: String, dark: Bool = true, frame: QAFrame? = nil) {
            let controller = PanelController(model: model, qa: frame ?? QAFrame(lit: 1, entrance: 1))
            controller.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))   // never ordered front: nothing appears on screen
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let size = controller.host.fittingSize
            controller.panel.setContentSize(size)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let v = controller.host
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }

        /// Eight half-hour readings per window leading up to the current one, rising `perHour` percent an hour.
        func series(_ s: ServiceState, _ s2: Service, perHour: Double, weekly: Double? = nil) -> [String: [Reading]] {
            guard let u = s.usage else { return [:] }
            var out: [String: [Reading]] = [:]
            for m in Metric.allCases {
                guard let w = m == .fiveHour ? u.fiveHour : u.weekly else { continue }
                let rate = m == .fiveHour ? perHour * 4 : perHour
                let count = m == .fiveHour ? 20 : 150           // 5-hour: 10 h of half-hours is clipped to the window; weekly: ~75 h
                // Deterministic bursts and plateaus that add up to `rate` an hour.
                let shape: [Double] = [0, 0, 0.2, 2.6, 1.8, 0.4, 0, 0, 0.1, 1.2, 3.1, 0.8, 0, 0.3]
                let weights = (0..<count).map { shape[$0 % shape.count] }
                let scale = rate * Double(count) / 2 / max(weights.reduce(0, +), 0.1)
                var p = max(0, w.percent - weights.reduce(0, +) * scale)
                out[TallyModel.key(s2, m)] = weights.enumerated().map { i, wt in
                    p += wt * scale
                    return Reading(t: u.readAt.addingTimeInterval(-Double(count - 1 - i) * 1800 - 1800), p: min(p, w.percent), resets: w.resetsAt)
                }
            }
            return out
        }
        func scene(_ c: ServiceState, _ x: ServiceState, today: [Service: Double], claudePace: Double = 0.35, codexPace: Double = 0.3,
                   pick: [Service: Metric] = [:]) {
            model.setFake(claude: c, codex: x, today: today,
                          readings: series(c, .claude, perHour: claudePace).merging(series(x, .codex, perHour: codexPace)) { a, _ in a },
                          dayBase: [.claude: (c.usage?.weekly?.percent ?? 0) - (today[.claude] ?? 0), .codex: (x.usage?.weekly?.percent ?? 0) - (today[.codex] ?? 0)])
            model.windowPick = pick
        }

        usedSince(dir)
        forecast(dir)
        staleCodex(dir)
        claudeSetup(dir)
        scene(usage(five: 34, week: 61.5, extras: ["Sonnet": 12]), usage(five: nil, week: 24), today: [.claude: 6.2, .codex: 3.0])
        shot("01-normal")
        shot("07-normal-light", dark: false)
        // The open moment at fixed progress: panel scale/fade and LED segments lighting left to right, then the projection.
        shot("17-open-start", frame: QAFrame(lit: 0.0, entrance: 0.4))
        shot("18-open-middle", frame: QAFrame(lit: 0.5, entrance: 0.85))
        shot("19-open-end", frame: QAFrame(lit: 1.0, entrance: 1))
        scene(usage(five: 34, week: 61.5, extras: ["Sonnet": 12, "Opus": 40]), usage(five: nil, week: 24), today: [.claude: 6.2, .codex: 3.0], pick: [.claude: .weekly])
        shot("02-weekly-budget-marker")
        scene(usage(five: 78, week: 70), usage(five: nil, week: 74), today: [.claude: 9.5, .codex: 11.2], claudePace: 0.6, codexPace: 0.15)
        shot("03-amber")
        scene(usage(five: 96, week: 93, extras: ["Sonnet": 40, "Opus": 71]), usage(five: nil, week: 93), today: [.claude: 14.0, .codex: 15.5],
              claudePace: 1.2, codexPace: 0.9, pick: [.claude: .weekly])
        shot("04-danger-reaches-100")
        shot("08-danger-light", dark: false)
        var claudeFailed = usage(five: 34, week: 61.5, age: 3 * 3600); claudeFailed.error = "Claude Code sign-in expired. Use Claude Code once."
        scene(claudeFailed, ServiceState(usage: nil, error: "No Codex usage found yet. Run Codex once."), today: [.claude: 6.2])
        shot("05-stale-and-unavailable")
        model.setFake(claude: ServiceState(), codex: ServiceState(), today: [:])
        shot("06-skeleton")
        scene(usage(five: 34, week: 61.5), usage(five: nil, week: 24), today: [:])
        settings.showCodex = false
        shot("09-one-service")
        settings.showClaude = false
        shot("10-nothing-on")
        settings.showClaude = true; settings.showCodex = true
        // Where it went: collapsed (shown in every panel above), open, light, empty, loading.
        model.tokens = [ProjectTokens(name: "copper-shop", tokens: 1_240_000, cached: 4_100_000), ProjectTokens(name: "harbor", tokens: 812_000, cached: 5_600_000), ProjectTokens(name: "orbit", tokens: 455_300, cached: 912_000),
                        ProjectTokens(name: "paper-planes", tokens: 120_400), ProjectTokens(name: "Other", tokens: 18_900, cached: 64_200)]
        model.tokensOpen = true
        shot("20-tokens-open")
        shot("21-tokens-open-light", dark: false)
        model.tokens = []
        shot("22-tokens-empty")
        model.tokens = nil
        shot("23-tokens-loading")
        model.tokensOpen = false
        // Settings window, every tab, off-screen.
        func settingsShot(_ name: String, tab: SettingsTab, dark: Bool = true) {
            UserDefaults.standard.set(tab.rawValue, forKey: "tallySettingsTab")
            let host = NSHostingView(rootView: SettingsView(settings: settings, model: model))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        for (n, t) in SettingsTab.allCases.enumerated() { settingsShot("11-settings-\(n + 1)-\(t.rawValue.lowercased())", tab: t) }
        settingsShot("12-settings-light", tab: .general, dark: false)
        UserDefaults.standard.set("General", forKey: "tallySettingsTab")

        // Menu bar: the drawn image on dark and light bars, 1x and a 4x zoom.
        func bar(_ name: String, dark: Bool, claude: ServiceState, codex: ServiceState, numbers: Bool = false) {
            model.setFake(claude: claude, codex: codex, today: [:])
            settings.showNumbers = numbers
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let image = StatusIcon.image(readings: StatusIcon.levels(model: model))
            let button = NSButton(title: "", image: image, target: nil, action: nil)
            button.attributedTitle = StatusIcon.title(model: model)
            button.isBordered = false; button.imagePosition = .imageLeft; button.font = KitFontAppKit.number
            button.frame = NSRect(x: 12, y: 0, width: button.fittingSize.width, height: 24)
            let zoom = NSImageView(image: image)
            zoom.imageScaling = .scaleProportionallyUpOrDown
            zoom.frame = NSRect(x: button.frame.maxX + 28, y: 4, width: image.size.width * 4, height: image.size.height * 4)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: zoom.frame.maxX + 16, height: 72))
            box.appearance = appearance
            box.wantsLayer = true
            appearance.performAsCurrentDrawingAppearance { box.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor }
            button.frame.origin.y = 24
            box.addSubview(button); box.addSubview(zoom)
            if let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) {
                box.cacheDisplay(in: box.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        bar("13-menubar-normal", dark: true, claude: usage(five: 34, week: 61), codex: usage(five: 12, week: 24))
        bar("14-menubar-numbers", dark: true, claude: usage(five: 78, week: 61), codex: usage(five: 94, week: 24), numbers: true)
        bar("15-menubar-stale", dark: true, claude: usage(five: 34, week: 61, age: 3600), codex: ServiceState(), numbers: true)
        bar("16-menubar-light", dark: false, claude: usage(five: 34, week: 61), codex: usage(five: 72, week: 24), numbers: true)
    }
}
