import Foundation
import Observation
import ServiceManagement

enum Service: String, CaseIterable, Sendable {
    case claude, codex
    var name: String { self == .claude ? "Claude" : "Codex" }
    var letter: String { self == .claude ? "C" : "X" }
    var defaultBudget: Double { self == .claude ? 13 : 14 }
}

/// User settings, kept in UserDefaults. Changes apply at once.
@MainActor @Observable
final class Settings {
    private let defaults: UserDefaults

    var metric: Metric { didSet { defaults.set(metric.rawValue, forKey: "metric") } }
    var showClaude: Bool { didSet { defaults.set(showClaude, forKey: "showClaude") } }
    var showCodex: Bool { didSet { defaults.set(showCodex, forKey: "showCodex") } }
    var showNumbers: Bool { didSet { defaults.set(showNumbers, forKey: "showNumbers") } }
    var budgetClaude: Double { didSet { defaults.set(budgetClaude, forKey: "budgetClaude") } }
    var budgetCodex: Double { didSet { defaults.set(budgetCodex, forKey: "budgetCodex") } }
    var alerts: Bool { didSet { defaults.set(alerts, forKey: "alerts") } }
    var suddenJumpAlerts: Bool { didSet { defaults.set(suddenJumpAlerts, forKey: "suddenJumpAlerts") } }
    private var mutedLimitAlerts: Set<LimitAlert> {
        didSet { defaults.set(mutedLimitAlerts.map(\.rawValue), forKey: "mutedLimitAlerts") }
    }
    var launchAtLogin: Bool {
        didSet {
            guard !isQA, launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }
    /// Opt-in: read Claude Code's sign-in from the Keychain and ask api.anthropic.com. Off: read the status line file.
    var liveClaude: Bool { didSet { defaults.set(liveClaude, forKey: "liveClaude") } }
    var claudeFilePath: String { didSet { defaults.set(claudeFilePath, forKey: "claudeFilePath") } }
    var introSeen: Bool { didSet { defaults.set(introSeen, forKey: "introSeen") } }
    let isQA: Bool

    init(defaults: UserDefaults = .standard, qa: Bool = false) {
        self.defaults = defaults
        isQA = qa
        metric = Metric(rawValue: defaults.string(forKey: "metric") ?? "") ?? .fiveHour
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? true
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        showNumbers = defaults.bool(forKey: "showNumbers")
        budgetClaude = defaults.object(forKey: "budgetClaude") as? Double ?? Service.claude.defaultBudget
        budgetCodex = defaults.object(forKey: "budgetCodex") as? Double ?? Service.codex.defaultBudget
        alerts = defaults.bool(forKey: "alerts")
        suddenJumpAlerts = defaults.object(forKey: "suddenJumpAlerts") as? Bool ?? true
        mutedLimitAlerts = Set((defaults.stringArray(forKey: "mutedLimitAlerts") ?? []).compactMap(LimitAlert.init(rawValue:)))
        liveClaude = defaults.bool(forKey: "liveClaude")
        claudeFilePath = defaults.string(forKey: "claudeFilePath") ?? ClaudeFile.defaultPath
        introSeen = defaults.bool(forKey: "introSeen")
        launchAtLogin = !qa && SMAppService.mainApp.status == .enabled
    }

    func shows(_ s: Service) -> Bool { s == .claude ? showClaude : showCodex }
    subscript(alert: LimitAlert) -> Bool {
        get { !mutedLimitAlerts.contains(alert) }
        set { if newValue { mutedLimitAlerts.remove(alert) } else { mutedLimitAlerts.insert(alert) } }
    }
    func budget(_ s: Service) -> Double { s == .claude ? budgetClaude : budgetCodex }
}
