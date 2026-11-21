import AppKit
import SwiftUI
import QuartzCore
import UserNotifications

@main
@MainActor
final class TallyApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "-qa", args[3] == "-forecast-only" {
            NSApp?.setActivationPolicy(.prohibited)
            QA.forecast(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-alerts-only" {
            NSApp?.setActivationPolicy(.prohibited)
            QA.limitAlerts(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-claude-setup-only" {
            NSApp?.setActivationPolicy(.prohibited)
            QA.claudeSetup(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-stale-only" {
            NSApp?.setActivationPolicy(.prohibited)
            QA.staleCodex(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-busy-only" {
            NSApp?.setActivationPolicy(.prohibited)
            QA.usageBusy(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-demo-only" {
            NSApp?.setActivationPolicy(.prohibited)
            Demo.shot(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.count == 4, args[1] == "-qa", args[3] == "-since-only" {
            QA.usedSince(URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        let app = NSApplication.shared
        let delegate = TallyApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var model: TallyModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if QA.runIfAsked() { return }
        let args = CommandLine.arguments
        Perf.on = args.contains("-perf") || args.contains("-perf-auto")
        let demo = Demo.on
        let demoDefaults = demo ? Demo.defaults() : nil
        let settings = demo ? Settings(defaults: demoDefaults!, qa: true) : Settings()
        let auto = args.contains("-perf-auto")
        model = TallyModel(settings: settings, defaults: demoDefaults ?? (auto ? UserDefaults(suiteName: "com.erikkirillov.Tally.perf")! : .standard), live: !auto && !demo)
        if demo { Demo.fill(model); Demo.script(model) }
        if auto { model.setFake(claude: QA.usage(five: 34, week: 61.5, extras: ["Sonnet": 12]), codex: QA.usage(five: nil, week: 24), today: [.claude: 6.2, .codex: 3]) }
        panel = PanelController(model: model)
        if !auto {
            if !demo { UNUserNotificationCenter.current().delegate = self }
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.target = self
            statusItem.button?.action = #selector(toggle)
            statusItem.button?.imagePosition = .imageLeft
        }
        if auto { NSApp.setActivationPolicy(.prohibited) }
        model.start()
        if !auto && !settings.introSeen {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.panel.close()    // never the intro and the panel together
                IntroController.shared.show(settings: settings)
            }
        }
        if !auto { updateIcon() }
        // Redraw the menu bar item when data or settings change; no timer, only observation.
        if !auto { observe() }
        let register = { (k: KitHotKey?) in
            guard let k else { HotKeys.shared.unregister(1); return }
            HotKeys.shared.register(1, HotKeyPref.carbon(k)) { [weak self] in
                self?.toggle()
            }
        }
        if !auto && !demo { register(HotKeyPref.load()); SettingsController.shared.onHotKey = register }
        panel.warmUp()
        if auto { runPerfAuto() }
    }

    @objc private func toggle() {
        if IntroController.shared.isShowing { panel.close(); IntroController.shared.show(settings: model.settings); return }
        panel.toggle(from: statusItem.button!, model: model)
    }

    private func observe() {
        withObservationTracking {
            _ = StatusIcon.levels(model: model); _ = StatusIcon.title(model: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon(); self?.observe() }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(readings: StatusIcon.levels(model: model))
        statusItem.button?.attributedTitle = StatusIcon.title(model: model)
        statusItem.button?.font = KitFontAppKit.number
    }

    /// `-perf-auto`: five programmatic opens with fake data (no Keychain, no network), timings printed, then quit.
    private func runPerfAuto() {
        Task { @MainActor in
            let t0 = CACurrentMediaTime()
            let r = CodexSource.read()
            print("perf: codex read (\(r == nil ? "no data" : "ok")) \(Perf.ms(since: t0)), off the main thread in the app")
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(500))
                panel.toggle(from: nil, model: model)
                try? await Task.sleep(for: .milliseconds(500))
                panel.toggle(from: nil, model: model)
            }
            NSApp.terminate(nil)
        }
    }
}

enum KitFontAppKit { static var number: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium) } }

/// One long-lived borderless panel with one hosting view: opening only moves it and orders it front.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: Panel
    let host: NSHostingView<PopoverView>
    private var closedAt = Date.distantPast
    private var link: CADisplayLink?
    private var openStart: CFTimeInterval = 0
    var isShown: Bool { panel.isVisible }

    let state = PanelState()

    init(model: TallyModel, qa: QAFrame? = nil) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: PopoverView(model: model, state: state, qa: qa))
        super.init()
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.delegate = self
        host.wantsLayer = true
        host.layer?.cornerRadius = KitSpace.panelRadius
        host.layer?.masksToBounds = true
        host.rootView = PopoverView(model: model, state: state, qa: qa) { [weak self] in self?.resize($0) }
    }

    /// Lays the view tree out and draws it once, invisibly, so the first real open is as fast as the rest.
    func warmUp() {
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
        state.shown = false
    }

    /// Fade out with the kit's exit, then order out (unless it was reopened meanwhile).
    func close() {
        guard state.shown else { return }
        state.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            if let self, !self.state.shown { self.panel.orderOut(nil) }
        }
    }

    /// `button` nil: perf runs, the panel opens far off-screen and the app is not activated.
    func toggle(from button: NSStatusBarButton?, model: TallyModel) {
        let t0 = CACurrentMediaTime()
        if state.shown { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.25 { return }   // the click that closed it
        let sinceClick = NSApp.currentEvent.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
        if let button { place(under: button) } else { panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize), display: false) }
        model.panelOpened()
        if button != nil { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        state.shown = true
        if Perf.on {
            openStart = t0
            Perf.log("open: handler \(Perf.ms(since: t0))" + (sinceClick.map { String(format: ", click event arrived %.1f ms before handler", $0 * 1000) } ?? ""))
            link?.invalidate()
            link = host.displayLink(target: self, selector: #selector(frame(_:)))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc private func frame(_ l: CADisplayLink) {
        Perf.log("open: first frame \(Perf.ms(since: openStart)) after the click handler started")
        l.invalidate(); link = nil
    }

    func place(under button: NSStatusBarButton) {
        guard let w = button.window else { return }
        let b = w.convertToScreen(button.convert(button.bounds, to: nil))
        let size = host.fittingSize
        var x = b.midX - size.width / 2
        if let screen = w.screen { x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8) }
        panel.setFrame(NSRect(x: x, y: b.minY - 6 - size.height, width: size.width, height: size.height), display: false)
    }

    private func resize(_ size: CGSize) {
        guard panel.isVisible, size.height > 0 else { return }
        var f = panel.frame
        f.origin.y += f.height - size.height
        f.size = size
        guard f != panel.frame else { return }
        // Never a snap: the panel grows or shrinks in 0.28 s, ease-out.
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            c.allowsImplicitAnimation = true
            panel.animator().setFrame(f, display: true)
        }
    }

    func windowDidResignKey(_ notification: Notification) { closedAt = Date(); close() }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (delegate as? PanelController)?.close() }
}
