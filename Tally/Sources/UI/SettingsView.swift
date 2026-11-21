import AppKit
import Carbon
import SwiftUI

enum SettingsTab: String, CaseIterable { case general = "General", sources = "Sources", budget = "Budget", alerts = "Alerts", about = "About" }

/// The global hot key, kept as JSON in UserDefaults. None by default: Tally had no shortcut before.
enum HotKeyPref {
    static let key = "tallyHotKey"
    static func load() -> KitHotKey? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KitHotKey.self, from: $0) } }
    static func save(_ k: KitHotKey?) {
        if let k, let d = try? JSONEncoder().encode(k) { UserDefaults.standard.set(d, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    static func carbon(_ k: KitHotKey) -> HotKeys.Combo {
        let f = NSEvent.ModifierFlags(rawValue: k.modifiers)
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return .init(keyCode: UInt32(k.keyCode), modifiers: UInt32(m))
    }
}

struct SettingsView: View {
    @Bindable var settings: Settings
    let model: TallyModel
    @AppStorage("tallySettingsTab") private var tab: SettingsTab = .general
    @State private var hotKey: KitHotKey? = HotKeyPref.load()
    @State private var copied = false

    var body: some View {
        KitSettings(title: "Tally settings", tabs: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: $tab) { t in
            switch t {
            case .general: general
            case .sources: sources
            case .budget: budget
            case .alerts: LimitAlertSettings(settings: settings)
            case .about:
                KitAboutView(name: "Tally", tagline: "Claude and Codex plan usage in your menu bar.", repoURL: URL(string: "https://github.com/noterikkirillov8/tally"))
            }
        }
        .kitAccent(Theme.claude)
        .onChange(of: hotKey) { _, k in HotKeyPref.save(k); SettingsController.shared.onHotKey(k) }
    }

    @ViewBuilder private var general: some View {
        KitSection {
            KitToggleRow(title: "Launch at login", isOn: $settings.launchAtLogin)
            KitRow(title: "Open Tally", detail: "Global shortcut for the panel") { KitHotKeyField(hotKey: $hotKey) }
            KitRow(title: "Intro") { Button("Show intro") { IntroController.shared.show(settings: settings) }.buttonStyle(.kitSecondary) }
        }
        KitSection(title: "Menu bar") {
            KitRow(title: "Level bars show") {
                KitSegmented(selection: $settings.metric, options: [(Metric.fiveHour, "5-hour"), (Metric.weekly, "Weekly")]).frame(width: 150)
            }
            KitToggleRow(title: "Numbers next to the bars", isOn: $settings.showNumbers)
        }
        KitSoundSection()
        HStack { Spacer(); Button("Quit Tally") { NSApp.terminate(nil) }.buttonStyle(.kitSecondary) }
    }

    @ViewBuilder private var sources: some View {
        KitSection(title: "Services") {
            KitToggleRow(title: "Claude", isOn: $settings.showClaude)
            KitToggleRow(title: "Codex", isOn: $settings.showCodex)
        }
        KitSection(title: "Claude numbers", footer: settings.liveClaude ? nil : claudeHint) {
            KitToggleRow(title: "Use my Claude Code sign-in",
                         detail: "Reads Claude Code's sign-in from your Keychain and sends it only to api.anthropic.com.",
                         isOn: Binding(get: { settings.liveClaude }, set: { settings.liveClaude = $0; model.refreshClaude(force: true) }))
            if !settings.liveClaude {
                KitRow(title: "Status file") {
                    TextField("Path", text: $settings.claudeFilePath).kitField().frame(width: 220)
                        .onSubmit { model.readClaudeFile() }
                }
                KitRow(title: "Status line helper", detail: "Copies a 3-line script to the clipboard.") {
                    Button(copied ? "Copied" : "Set up") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ClaudeFile.helper, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }.buttonStyle(.kitSecondary)
                }
            }
        }
    }

    @ViewBuilder private var budget: some View {
        KitSection(title: "Daily budget", footer: "Share of the weekly limit you plan to use in a day.") {
            KitRow(title: "Claude") { KitStepper(value: bind(\.budgetClaude), range: 1...100) { "\($0)%" } }
            KitRow(title: "Codex") { KitStepper(value: bind(\.budgetCodex), range: 1...100) { "\($0)%" } }
            KitToggleRow(title: "Alerts at 80% and 100%", isOn: $settings.alerts)
        }
    }

    /// Shown when the file is missing or older than 15 minutes.
    private var claudeHint: String? {
        let stale = model.claude.usage.map { $0.isStale(now: Date()) } ?? true
        return stale ? "Claude numbers come from Claude Code's status line. They update while Claude Code runs in a terminal." : nil
    }

    private func bind(_ key: ReferenceWritableKeyPath<Settings, Double>) -> Binding<Int> {
        Binding(get: { Int(settings[keyPath: key]) }, set: { settings[keyPath: key] = Double($0) })
    }
}

struct LimitAlertSettings: View {
    @Bindable var settings: Settings

    private func enabled(_ alert: LimitAlert) -> Binding<Bool> {
        Binding(get: { settings[alert] }, set: { settings[alert] = $0 })
    }

    var body: some View {
        KitSection(title: "5-hour limit") {
            KitToggleRow(title: "At 80% used", isOn: enabled(.five80))
            KitToggleRow(title: "At 95% used", isOn: enabled(.five95))
            KitToggleRow(title: "When the limit resets", detail: "Only after usage went above 80%.", isOn: enabled(.reset))
        }
        KitSection(title: "Weekly limit", footer: "Each alert fires once per window for each service.") {
            KitToggleRow(title: "At 80% used", isOn: enabled(.weekly80))
            KitToggleRow(title: "At 95% used", isOn: enabled(.weekly95))
        }
        KitSection(title: "Usage changes", footer: "At most one sudden-jump alert per hour across all services.") {
            KitToggleRow(title: "Sudden jumps", detail: "When a window rises 10 points or more in 15 minutes.", isOn: $settings.suddenJumpAlerts)
        }
    }
}

/// One Settings window for the app's life; created on first use.
@MainActor
final class SettingsController {
    static let shared = SettingsController()
    var onHotKey: (KitHotKey?) -> Void = { _ in }
    private var window: NSWindow?

    func show(model: TallyModel) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(KitColor.window)
        w.contentView = NSHostingView(rootView: SettingsView(settings: model.settings, model: model))
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
