import AppKit
import SwiftUI

/// `Tally -demo`: the normal app on fictional numbers for filming. Reads no real source (no status line file,
/// no ~/.codex, no Keychain, no network), posts no notifications, and keeps settings in its own throwaway domain.
@MainActor
enum Demo {
    static var on: Bool { CommandLine.arguments.contains("-demo") }
    static let suite = "com.erikkirillov.Tally.demo"

    /// Fresh in-memory-like domain (wiped at every start); the intro is marked seen so the panel is the first thing.
    static func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "introSeen")
        return d
    }

    /// Claude 5 h 62 %, weekly 41 %, Codex weekly 35 %, readings for a steady pace, five fictional projects.
    static func fill(_ model: TallyModel) {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        let short = UsageWindow(percent: 62, resetsAt: now.addingTimeInterval(2.25 * 3600))
        let week = UsageWindow(percent: 41, resetsAt: now.addingTimeInterval(3.2 * 86400))
        let codexWeek = UsageWindow(percent: 35, resetsAt: now.addingTimeInterval(4.1 * 86400))
        func rs(_ w: UsageWindow, _ points: [(Double, Double)]) -> [Reading] { points.map { Reading(t: ago($0.0), p: $0.1, resets: w.resetsAt) } }
        model.setFake(
            claude: ServiceState(usage: ServiceUsage(fiveHour: short, weekly: week, extras: ["Sonnet": UsageWindow(percent: 17, resetsAt: week.resetsAt)], readAt: now)),
            codex: ServiceState(usage: ServiceUsage(fiveHour: nil, weekly: codexWeek, extras: [:], readAt: now.addingTimeInterval(-90))),
            today: [.claude: 5.5, .codex: 4],
            readings: [
                TallyModel.key(.claude, .fiveHour): rs(short, [(1.0, 51), (0.75, 54), (0.5, 57), (0.25, 59.5)]),
                TallyModel.key(.claude, .weekly): rs(week, [(20, 35.5), (14, 37), (8, 38.8), (3, 40), (1, 40.6)]),
                TallyModel.key(.codex, .weekly): rs(codexWeek, [(20, 31), (14, 32), (8, 33.2), (3, 34.4), (1, 34.8)])
            ],
            dayBase: [.claude: 35.5, .codex: 31])
        model.tokens = [ProjectTokens(name: "storefront", tokens: 1_180_000, cached: 4_300_000), ProjectTokens(name: "landing-page", tokens: 742_000, cached: 2_900_000),
                        ProjectTokens(name: "api-server", tokens: 515_000, cached: 3_100_000), ProjectTokens(name: "orbit", tokens: 288_000, cached: 640_000),
                        ProjectTokens(name: "docs", tokens: 96_000, cached: 210_000)]
    }

    /// The one scripted step: 4 s after launch Claude's 5-hour number climbs 9 points over 2 s, then stays.
    static func script(_ model: TallyModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard var usage = model.claude.usage else { return }
            let from = usage.fiveHour?.percent ?? 62
            let frames = 60
            for i in 1...frames {
                let k = Double(i) / Double(frames)
                usage.fiveHour?.percent = from + 9 * (k * k * (3 - 2 * k))
                usage.readAt = Date()
                model.claude = ServiceState(usage: usage)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// `-qa <dir> -demo-only`: the panel in demo state, off-screen, tokens open.
    static func shot(_ dir: URL) {
        let model = TallyModel(settings: Settings(defaults: defaults(), qa: true), defaults: defaults(), live: false)
        fill(model)
        model.tokensOpen = true
        let controller = PanelController(model: model, qa: QAFrame(lit: 1, entrance: 1))
        controller.panel.appearance = NSAppearance(named: .darkAqua)
        controller.panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        controller.panel.setContentSize(controller.host.fittingSize)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let v = controller.host
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("demo.png"))
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
