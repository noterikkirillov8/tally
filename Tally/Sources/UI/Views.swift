import SwiftUI
import AppKit

enum Theme {
    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x8AA4C8)
    static let width: CGFloat = 360

    static func accent(_ s: Service) -> Color { s == .claude ? claude : codex }
}

/// Whether the panel is showing; drives the entrance and exit.
@MainActor @Observable
final class PanelState { var shown = false; var hairPending = true }

struct PopoverView: View {
    let model: TallyModel
    let state: PanelState
    var qa: QAFrame? = nil
    var onResize: (CGSize) -> Void = { _ in }
    @State private var hair = 0.0          // width of the power-on hairline, 0...1
    @State private var hairOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TallyModel, state: PanelState, qa: QAFrame? = nil, onResize: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.state = state
        self.qa = qa
        self.onResize = onResize
    }

    var body: some View {
        KitPanel(title: "Tally", width: Theme.width) {
            KitIconButton(symbol: "gearshape", help: "Settings") { SettingsController.shared.show(model: model) }
                .keyboardShortcut(",", modifiers: .command)
        } content: {
            MainView(model: model)
        }
        .kitAccent(Theme.claude)
        .environment(\.tallyQA, qa)
        .modifier(Entrance(shown: state.shown, qa: qa, reduceMotion: reduceMotion))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.claude).frame(height: 1)
                .scaleEffect(x: max(hair, 0.001), y: 1).padding(.horizontal, KitSpace.panelRadius)
                .opacity(hairOn ? 1 : 0).allowsHitTesting(false)
        }
        .onChange(of: state.shown) { if state.shown { powerOn() } }
        .onGeometryChange(for: CGSize.self, of: \.size) { onResize($0) }
    }

    /// The very first open of a session: the top hairline lights in the accent from the centre outward, then settles.
    private func powerOn() {
        guard state.hairPending, qa == nil, !reduceMotion else { return }
        state.hairPending = false
        hair = 0; hairOn = true
        withAnimation(.easeOut(duration: 0.25)) { hair = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeOut(duration: 0.3)) { hairOn = false } }
    }
}

/// Panel entrance: scale 0.96 to 1 from the top edge plus fade (fade only with Reduce Motion).
private struct Entrance: ViewModifier {
    let shown: Bool
    let qa: QAFrame?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if let qa {
            content.scaleEffect(0.96 + 0.04 * qa.entrance, anchor: .top).opacity(qa.entrance)
        } else if reduceMotion {
            content.opacity(shown ? 1 : 0).animation(.easeOut(duration: 0.14), value: shown)
        } else {
            content.kitPanelEntrance(shown)
        }
    }
}

// MARK: Main

struct MainView: View {
    let model: TallyModel

    var body: some View {
        // The one clock in the view: staleness and "resets in" re-evaluate every 30 s.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let shown = Service.allCases.filter { model.settings.shows($0) }
            VStack(spacing: 0) {
                if shown.isEmpty {
                    KitEmptyState(symbol: "chart.bar.xaxis", text: "Turn a service on in Settings.")
                } else if model.showsClaudeSetup {
                    ClaudeSetup(model: model)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element) { i, s in
                        if i > 0 { KitDivider() }
                        ServiceCard(model: model, service: s, now: ctx.date)
                    }
                }
                if !shown.isEmpty, shown.contains(.claude) { KitDivider(); TokensSection(model: model) }
            }
        }
    }
}

private struct ClaudeSetup: View {
    let model: TallyModel

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.m) {
            Text("Claude plan usage").font(KitFont.header).foregroundStyle(KitColor.text)
            VStack(alignment: .leading, spacing: KitSpace.xs) {
                Text("Only use the Claude desktop app? Check your limits on the web.")
                Link("Open Claude usage", destination: URL(string: "https://claude.ai/settings/usage")!)
                    .buttonStyle(.kitSecondary)
            }
            KitDivider()
            VStack(alignment: .leading, spacing: KitSpace.xs) {
                Toggle("Use my Claude Code sign-in", isOn: Binding(get: { model.settings.liveClaude }, set: {
                    model.settings.liveClaude = $0; model.refreshClaude(force: true)
                })).toggleStyle(.kitSwitch)
                Text("Run `claude` in Terminal and sign in once. Tally reads the Keychain token only to ask Anthropic for usage. It never stores or logs the token.")
                if model.settings.liveClaude, let error = model.claude.error { Text(error) }
            }
            VStack(alignment: .leading, spacing: KitSpace.xs) {
                Text("Use the Terminal status line").font(KitFont.body).foregroundStyle(KitColor.text)
                Text("Copy the helper in Settings → Sources and use it as your Claude Code status line. Its file gives Tally your 5-hour and weekly limits and reset times. No token needed.")
                    .help("The status line JSON includes rate_limits.five_hour.used_percentage, rate_limits.seven_day.used_percentage and each window’s resets_at.")
            }
        }
        .font(KitFont.detail).foregroundStyle(KitColor.text2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(KitSpace.l)
    }
}

struct ServiceCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: TallyModel
    let service: Service
    let now: Date

    var body: some View {
        let state = model.state(service)
        let usage = state.usage
        let age = usage?.staleness(now: now)
        let stale = age != .fresh
        let metric = model.metric(for: service)
        let window = age == .expired ? nil : model.window(service, metric)
        let fresh = !stale && window != nil
        let pace = model.pace(service, metric, now: now)
        let landing = fresh ? Pace.landing(pace) : nil
        let budget = model.settings.budget(service)
        let today = usage.flatMap { Calendar.current.isDate($0.readAt, inSameDayAs: now) ? model.today[service] : nil }
        let period = model.todaySince[service].map { "Since \(Fmt.clock($0, now: now))," } ?? "Today"
        let backoff = service == .claude && model.settings.liveClaude ? model.usageBackoff : nil
        VStack(alignment: .leading, spacing: KitSpace.m) {
            HStack(spacing: 6) {
                KitLed(on: !stale, color: Theme.accent(service))
                Text(service.name).font(KitFont.header).foregroundStyle(KitColor.text).lineLimit(1).fixedSize()
                if let usage, !stale {
                    Text("as of \(Fmt.clock(usage.readAt, now: usage.readAt))")
                        .font(KitFont.detail).foregroundStyle(KitColor.text2).padding(.leading, 4)
                        .lineLimit(1).fixedSize()
                }
                Spacer()
                if usage?.fiveHour != nil && usage?.weekly != nil {
                    KitSegmented(selection: Binding(get: { metric }, set: { v in withAnimation(KitMotion.list) { model.windowPick[service] = v } }),
                                 options: [(Metric.fiveHour, "5-hour"), (Metric.weekly, "Weekly")]).frame(width: 156)
                } else {
                    Text(metric == .fiveHour ? "5-hour" : "Weekly").font(KitFont.detail).foregroundStyle(KitColor.text2)
                }
            }
            HStack(spacing: KitSpace.m) {
                RollingFigure(value: window.map { Int($0.percent.rounded()) }, openTick: model.openTick)
                LedBar(service: service, value: window?.percent, landing: landing,
                       marker: fresh && metric == .weekly && today != nil ? model.budgetLimit(service) : nil, openTick: model.openTick)
                    .help(fresh && metric == .weekly && today != nil ? "\(period) \(String(format: "%.1f", today!))% of the \(Fmt.percent(budget))% budget" : "")
            }
            .opacity(stale && window != nil ? 0.62 : 1)
            VStack(alignment: .trailing, spacing: 3) {
                HistoryStrip(service: service, readings: strip(model, metric, window, usage), resets: window?.resetsAt,
                             length: Pace.keeping(metric).length, landing: landing)
                    .opacity(stale ? 0.5 : 1)
            }
            if let label = age?.label {
                Text(label).font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
            if fresh, let w = window {
                VStack(alignment: .leading, spacing: 4) {
                    if let pace, let reset = w.resetsAt, let usage, let line = Fmt.forecast(pace, readAt: usage.readAt, reset: reset) {
                        let color: Color = if case .reaches = pace { Theme.accent(service) } else { Color(hex: colorScheme == .dark ? 0x9ABBA5 : 0x456950) }
                        Text(line).font(KitFont.detail).foregroundStyle(color)
                            .transition(.kitRow)
                    }
                    if let r = w.resetsAt, r > now {
                        Text("Resets in \(Fmt.remaining(r.timeIntervalSince(now))), \(Fmt.clock(r, now: now))").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    }
                    if metric == .weekly, let today, budget > 0, model.todaySince[service] != nil || today >= budget * 0.8 {
                        BudgetLine(used: today, budget: budget, period: period).transition(.kitRow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if metric == .weekly, window != nil, let usage, !usage.extras.isEmpty {
                let top = usage.extras.sorted { $0.value.percent > $1.value.percent }.prefix(2)
                HStack(spacing: KitSpace.l) {
                    ForEach(Array(top), id: \.key) { k, w in
                        VStack(spacing: 4) {
                            HStack { Text(k).font(KitFont.detail).foregroundStyle(KitColor.text2); Spacer()
                                Text("\(Fmt.percent(w.percent))%").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text) }
                            KitMeter(value: w.percent / 100, segments: 12).kitAccent(Theme.accent(service))
                        }
                    }
                }
                .opacity(stale ? 0.62 : 1)
                .transition(.kitRow)
            }
            if let e = backoff.map({ "Usage service busy, retrying at \(Fmt.clock($0.retryAt, now: now))" }) ?? state.error {
                Text(e).font(KitFont.detail).foregroundStyle(KitColor.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(KitSpace.l)
    }

    /// This window's history with the current reading as its last point.
    private func strip(_ model: TallyModel, _ m: Metric, _ w: UsageWindow?, _ usage: ServiceUsage?) -> [Reading] {
        guard let w, let usage else { return [] }
        var r = model.series(service, m)
        if r.last.map({ usage.readAt > $0.t }) ?? true { r.append(Reading(t: usage.readAt, p: w.percent, resets: w.resetsAt)) }
        return r
    }
}

/// The big %: counts up from 0 in a few steps on open (in step with the LED segments lighting) and rolls
/// its digits whenever a new reading arrives.
struct RollingFigure: View {
    let value: Int?
    let openTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tallyQA) private var qa
    @State private var shown: Int?
    @State private var counting: Task<Void, Never>?

    init(value: Int?, openTick: Int) {
        self.value = value; self.openTick = openTick
        _shown = State(initialValue: value)
    }

    var body: some View {
        let display = qa.map { q in value.map { Int((Double($0) * q.lit).rounded()) } } ?? shown
        Text(display.map { "\($0)%" } ?? "—")
            .font(KitFont.figure(28, .semibold))
            .foregroundStyle(display == nil ? KitColor.text3 : KitColor.text)
            .frame(width: 96, alignment: .leading)
            .lineLimit(1).minimumScaleFactor(0.8)
            .kitRollingNumber(display ?? -1)
            .onChange(of: value) { counting?.cancel(); shown = value }
            .onChange(of: openTick) {
                counting?.cancel()
                guard let target = value, !reduceMotion else { shown = value; return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { shown = 0 }
                counting = Task { @MainActor in
                    for k in 1...6 {
                        try? await Task.sleep(for: .milliseconds(45))
                        if Task.isCancelled { return }
                        shown = target * k / 6
                    }
                }
            }
    }
}

struct PaceLine: View {
    let result: Pace.Result
    let now: Date

    var body: some View {
        let color: Color = switch result {
        case .gathering: KitColor.text3
        case .reaches: KitColor.amber
        case .finishes(let p): p >= 90 ? KitColor.amber : KitColor.text2
        }
        Text(Fmt.pace(result, now: now)).font(KitFont.detail).foregroundStyle(color)
            .kitRollingNumber(Fmt.pace(result, now: now))
    }
}

/// "Today 6.2% of the 13% budget", amber from 80%, red at the budget.
struct BudgetLine: View {
    let used: Double
    let budget: Double
    var period = "Today"

    var body: some View {
        let color: Color = budget > 0 && used >= budget ? KitColor.red : budget > 0 && used >= budget * 0.8 ? KitColor.amber : KitColor.text2
        Text("\(period) \(String(format: "%.1f", used))% of the \(Fmt.percent(budget))% budget").font(KitFont.detail.monospacedDigit()).foregroundStyle(color)
            .kitRollingNumber(Int((used * 10).rounded()))
    }
}

// MARK: Where it went

/// "Today by project": Claude Code tokens per project folder today. Details are collapsed by default.
/// These are tokens, not plan percent, and the label says so.
struct TokensSection: View {
    let model: TallyModel
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(KitMotion.list) { model.tokensOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(KitColor.text3)
                        .rotationEffect(.degrees(model.tokensOpen ? 90 : 0))
                    Text("Today by project").font(KitFont.key).foregroundStyle(model.tokensOpen ? KitColor.text : KitColor.text2)
                    Spacer()
                    if let projects = model.tokens {
                        Text("\(Transcripts.tokens(projects.reduce(0) { $0 + $1.tokens })) tokens today")
                            .font(KitFont.detail.monospacedDigit()).foregroundStyle(KitColor.text2)
                    }
                }
                .padding(.horizontal, KitSpace.l)
                .frame(height: 40)
                .background(hover ? KitColor.well : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
            .accessibilityLabel("Today by project")
            .accessibilityAddTraits(model.tokensOpen ? .isSelected : [])
            if model.tokensOpen { rows.transition(.kitRow) }
        }
    }

    @ViewBuilder private var rows: some View {
        if let list = model.tokens {
            if list.isEmpty {
                Text("No Claude Code activity today.").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, KitSpace.l).padding(.bottom, KitSpace.m)
            } else {
                let total = max(list.reduce(0) { $0 + $1.tokens }, 1)
                VStack(spacing: 0) {
                    ForEach(list) { p in
                        HStack(spacing: KitSpace.m) {
                            Text(p.name).font(KitFont.body).foregroundStyle(p.name == "Other" ? KitColor.text2 : KitColor.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            KitMeter(value: Double(p.tokens) / Double(total), segments: 10, warn: nil, danger: nil, color: Theme.claude).frame(width: 84)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Transcripts.tokens(p.tokens)).font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text)
                                    .kitRollingNumber(p.tokens)
                                if p.cached > 0 {
                                    Text("+ \(Transcripts.tokens(p.cached)) cached").font(KitFont.detail).foregroundStyle(KitColor.text2)
                                }
                            }
                            .frame(minWidth: 88, alignment: .trailing)
                        }
                        .frame(height: 36)
                        .padding(.horizontal, KitSpace.l)
                        .transition(.kitRow)
                    }
                }
                .padding(.bottom, KitSpace.s)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack { RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 90, height: 10); Spacer()
                        KitMeter(value: 0, segments: 10).frame(width: 84); Spacer().frame(width: 56) }
                        .frame(height: 30).padding(.horizontal, KitSpace.l)
                }
            }
            .padding(.bottom, KitSpace.s)
        }
    }
}
