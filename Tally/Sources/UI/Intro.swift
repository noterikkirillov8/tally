import SwiftUI
import AppKit

/// First-launch intro: five scenes built from Tally's real views (LedBar, RollingFigure, HistoryStrip, PaceLine,
/// BudgetLine, StatusIcon, KitPanel) on a scripted demo. Every scene is a pure function of its local time `t`
/// (a keyframe timeline of `ramp`s), so the same code plays live and renders off-screen for QA.

enum IntroScene: Int, CaseIterable {
    case levels, pace, history, budget, menuBar

    var duration: Double { self == .levels ? 5.4 : 4.4 }
    var title: String {
        switch self {
        case .levels: "Your limits, lit up"
        case .pace: "See where you will land"
        case .history: "Your week, drawn"
        case .budget: "Stay inside a daily budget"
        case .menuBar: "Always in the menu bar"
        }
    }
    var line: String {
        switch self {
        case .levels: "Claude and Codex usage as level bars, always current."
        case .pace: "Hollow segments show where your pace ends at the reset."
        case .history: "Every reading is kept, so a busy day is easy to spot."
        case .budget: "The marker shows today's share of the weekly limit."
        case .menuBar: "Two bars, always there. Click for the full panel."
        }
    }
}

/// Eased 0...1 progress of a keyframe that starts at `at` and lasts `over` seconds.
private func ramp(_ t: Double, _ at: Double, _ over: Double) -> Double {
    let x = min(max((t - at) / over, 0), 1)
    return 1 - pow(1 - x, 3)
}
private func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

// MARK: Chrome

/// The window content: stage, title and line, step LEDs and buttons. The stage is injected so the live
/// player and the QA renderer share everything else.
struct IntroChrome<Stage: View>: View {
    let index: Int
    var onSkip: () -> Void = {}
    var onNext: () -> Void = {}
    @ViewBuilder var stage: Stage

    var body: some View {
        let scene = IntroScene(rawValue: index) ?? .levels
        let last = index == IntroScene.allCases.count - 1
        VStack(spacing: 0) {
            stage.frame(height: 292).clipped()
            VStack(spacing: 6) {
                Text(scene.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(KitColor.text)
                Text(scene.line).font(KitFont.body).foregroundStyle(KitColor.text2)
            }
            .id(index)
            .transition(.asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .offset(x: -24).combined(with: .opacity)))
            .frame(height: 52)
            Spacer(minLength: 0)
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<IntroScene.allCases.count, id: \.self) { i in
                        KitLed(on: i == index, size: 7).animation(KitMotion.soft, value: index)
                    }
                }
                HStack {
                    Button("Skip", action: onSkip).buttonStyle(.kitQuiet).focusable(false)
                    Spacer()
                    if last { Button("Get started", action: onNext).buttonStyle(.kitPrimary).focusable(false) }
                    else { Button("Next", action: onNext).buttonStyle(.kitSecondary).focusable(false) }
                }
            }
            .padding(.horizontal, KitSpace.xl).padding(.bottom, KitSpace.l)
        }
        .frame(width: 640, height: 440)
        .background(KitColor.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .kitAccent(Theme.claude)
    }
}

/// The one clock: an IntroFlow plus a single 30 Hz timer. `t` is the current scene's local time and the only
/// input of the stage, so Next, Back and Skip can never leave pending work behind.
@MainActor @Observable
final class IntroModel {
    var index = 0
    var t = 0.0
    var direction = 1.0               // +1 forward (slides left), -1 back (slides right)
    @ObservationIgnored var flow = IntroFlow(durations: IntroScene.allCases.map { $0.duration + 0.3 })
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var timer: Timer?
    var isLast: Bool { index == IntroScene.allCases.count - 1 }

    func start() {
        flow = IntroFlow(durations: flow.durations, now: CACurrentMediaTime())
        let tm = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime()
        flow.tick(now: now)
        sync()
        if flow.scene == index { t = flow.time(now: now) }
    }
    func next() { flow.next(now: CACurrentMediaTime()); sync() }
    func back() { flow.back(now: CACurrentMediaTime()); sync() }
    /// Skip and Get started.
    func finish() { flow.close(); sync() }

    /// The slide direction is published one tick before the index, so the outgoing view slides the right way.
    private func sync() {
        if flow.closed { stop(); onClose(); return }
        guard flow.scene != index else { return }
        let d = flow.scene > index ? 1.0 : -1.0
        if direction != d { direction = d; return }
        t = 0
        withAnimation(KitMotion.list) { index = flow.scene }
    }
}

struct IntroView: View {
    let model: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slide = AnyTransition.asymmetric(insertion: .offset(x: 24 * model.direction).combined(with: .opacity),
                                             removal: .offset(x: -24 * model.direction).combined(with: .opacity))
        let scene = IntroScene(rawValue: model.index) ?? .levels
        IntroChrome(index: model.index, onSkip: { model.finish() }, onNext: { model.next() }) {
            IntroStage(scene: scene, t: reduceMotion ? scene.duration : min(model.t, scene.duration), motion: !reduceMotion)
                .id(model.index)
                .transition(reduceMotion ? .opacity : slide)
        }
    }
}

// MARK: Stage

struct IntroStage: View {
    let scene: IntroScene
    let t: Double
    var motion = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch scene {
            case .levels: levels
            case .pace: pace
            case .history: history
            case .budget: budget
            case .menuBar: menuBar
            }
            spotlight
            cursorLayer
        }
        .frame(width: 640, height: 292, alignment: .topLeading)
        .kitAccent(Theme.claude)
    }

    /// Where the pool of light sits over time: (time, rect in stage coordinates). It glides between keys.
    private var focus: [(Double, CGRect)] {
        switch scene {
        case .levels: [(0.3, CGRect(x: 94, y: 43, width: 452, height: 104)), (2.5, CGRect(x: 94, y: 43, width: 452, height: 104)),
                       (3.2, CGRect(x: 94, y: 146, width: 452, height: 104)), (4.2, CGRect(x: 88, y: 38, width: 464, height: 216))]
        case .pace: [(0.3, CGRect(x: 92, y: 80, width: 456, height: 132)), (1.0, CGRect(x: 386, y: 124, width: 146, height: 66)),
                     (2.9, CGRect(x: 386, y: 124, width: 146, height: 66)), (3.6, CGRect(x: 108, y: 166, width: 330, height: 34))]
        case .history: [(0.3, CGRect(x: 92, y: 63, width: 456, height: 166)), (1.0, CGRect(x: 106, y: 146, width: 436, height: 60))]
        case .budget: [(0.3, CGRect(x: 92, y: 80, width: 456, height: 132)), (0.9, CGRect(x: 380, y: 120, width: 152, height: 56)),
                       (2.9, CGRect(x: 380, y: 120, width: 152, height: 56)), (3.6, CGRect(x: 108, y: 166, width: 220, height: 32))]
        case .menuBar: [(0.3, CGRect(x: 392, y: 8, width: 72, height: 40)), (2.3, CGRect(x: 392, y: 8, width: 72, height: 40)),
                        (3.0, CGRect(x: 344, y: 44, width: 290, height: 200))]
        }
    }

    /// The stage dims to 45% except a crisp pool cut to the focused element's rounded rect (4 pt padding),
    /// with a 1 px accent hairline; clipped to the stage.
    private var spotlight: some View {
        let r = motion ? IntroDemo.rect(focus, t) : focus.last!.1
        let a = ramp(t, 0, 0.5)
        return ZStack {
            SpotCut(rect: r.insetBy(dx: -4, dy: -4), size: CGSize(width: 640, height: 292))
                .fill(Color.black.opacity(0.55 * a), style: FillStyle(eoFill: true)).blur(radius: 1)
            SpotCut(rect: r.insetBy(dx: -4, dy: -4), size: CGSize(width: 640, height: 292), ring: true)
                .stroke(Theme.claude.opacity(0.35 * a), lineWidth: 1)
        }
        .frame(width: 640, height: 292).clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder private var cursorLayer: some View {
        switch scene {
        case .levels, .history: EmptyView()
        case .pace: cursor([(0.6, 520, 250), (1.6, 470, 142), (3.2, 470, 142)], tip: "Where you land at reset", tipAt: 2.0)
        case .budget: cursor([(0.4, 540, 240), (1.4, 431, 150), (3.6, 431, 150)], tip: "Today's budget", tipAt: 1.6)
        case .menuBar: cursor([(0.2, 300, 190), (1.9, 432, 30), (3.5, 432, 30)], pressAt: 2.3)
        }
    }

    /// Tally's power-on self test: every segment flashes full for 120 ms, drops to zero, then rises to the value.
    private func selfTest(_ at: Double) -> (lit: Double, flash: Bool) {
        if t < at { return (0, false) }
        if t < at + 0.12 { return (1, true) }
        if t < at + 0.3 { return (0, false) }
        return (ramp(t, at + 0.3, 1.6), false)
    }

    // 1. Self test, then the bars rise to their values while the % rolls; the second card arrives.
    private var levels: some View {
        let a = selfTest(1.1), b = selfTest(2.9), arrive = ramp(t, 0.4, 0.5)
        return VStack(spacing: KitSpace.m) {
            IntroCard(service: .claude, label: "5-hour", value: 62, lit: a.lit, flash: a.flash)
            IntroCard(service: .codex, label: "Weekly", value: 41, lit: b.lit, flash: b.flash)
                .opacity(arrive).offset(y: 8 * (1 - arrive))
        }
        .frame(width: 640, height: 292)
    }

    // 2. The projection grows as hollow segments and the pace line arrives.
    private var pace: some View {
        let grow = ramp(t, 0.6, 1.6), line = ramp(t, 1.9, 0.5)
        let reaches = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 14, minute: 0, weekday: 7), matchingPolicy: .nextTime) ?? Date()
        return IntroCard(service: .claude, label: "Weekly", value: 61, landing: lerp(61, 100, grow)) {
            PaceLine(result: .reaches(reaches), now: Date()).opacity(line).offset(y: 6 * (1 - line))
        }
        .frame(width: 640, height: 292)
    }

    // 3. The history line draws itself, then the dashed projection.
    private var history: some View {
        let p = ramp(t, 0.5, 2.6), proj = ramp(t, 3.1, 0.8)
        let value = 61.5 * IntroDemo.cumulative(p)
        return VStack(spacing: KitSpace.m) {
            IntroCard(service: .claude, label: "Weekly", value: value.rounded(),
                      landing: proj > 0 ? lerp(value, 100, proj) : nil, strip: IntroDemo.readings(p, final: 61.5))
        }
        .frame(width: 640, height: 292)
    }

    // 4. The bar grows toward today's budget marker; the line rolls and turns amber.
    private var budget: some View {
        let k = ramp(t, 0.7, 2.4), mark = ramp(t, 0.3, 0.9)
        let base = 55.3, today = lerp(0, 11.8, k), limit = base + 13
        return IntroCard(service: .claude, label: "Weekly", value: (base + today).rounded(), marker: lerp(100, limit, mark)) {
            BudgetLine(used: today, budget: 13)
        }
        .frame(width: 640, height: 292)
    }

    // 5. The menu bar icon fills, a click opens the panel.
    private var menuBar: some View {
        let fill = ramp(t, 0.3, 1.5), click = t > 2.3 ? 1.0 : 0.0, panel = ramp(t, 2.4, 0.5)
        let pulse = ramp(t, 2.3, 0.15) - ramp(t, 2.45, 0.2)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                Spacer()
                Image(nsImage: StatusIcon.image(levels: [62 * fill, 41 * fill])).renderingMode(.template).resizable().interpolation(.high)
                    .frame(width: 23, height: 24).foregroundStyle(KitColor.text)
                    .padding(.horizontal, 5).background(RoundedRectangle(cornerRadius: 5).fill(KitColor.text.opacity(0.14 * click)))
                    .scaleEffect(1 - 0.08 * pulse)
                Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(KitColor.text2).frame(width: 20)
                Image(systemName: "battery.75percent").font(.system(size: 13)).foregroundStyle(KitColor.text2).frame(width: 24)
                Text("Fri 14:02").font(.system(size: 12, weight: .medium)).foregroundStyle(KitColor.text2).frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(width: 560, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(KitColor.well))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KitColor.line, lineWidth: 1))
            .offset(x: 40, y: 14)

            KitPanel(title: "Tally", width: 340) {
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(KitColor.text2)
            } content: {
                IntroCard(service: .claude, label: "5-hour", value: 62, bordered: false)
                KitDivider()
                IntroCard(service: .codex, label: "Weekly", value: 41, bordered: false)
            }
            .scaleEffect(0.8 + 0.2 * panel, anchor: .top).opacity(panel)
            .scaleEffect(0.78, anchor: .top)
            .offset(x: 600 - 340 * 0.78 - 18, y: 52)
        }
        .frame(width: 640, height: 292, alignment: .topLeading)
    }

    @ViewBuilder
    private func cursor(_ path: [(Double, Double, Double)], pressAt: Double? = nil, tip: String? = nil, tipAt: Double = 0) -> some View {
        if motion {
            let p = IntroDemo.position(path, t)
            let pressed = pressAt.map { t > $0 && t < $0 + 0.18 } ?? false
            ZStack(alignment: .topLeading) {
                if let tip {
                    let r = ramp(t, tipAt, 0.3)
                    Text(tip).font(KitFont.detail).foregroundStyle(KitColor.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(KitColor.raised))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KitColor.line, lineWidth: 1))
                        .fixedSize().offset(x: 14, y: 20).opacity(r)
                }
                GhostCursor().scaleEffect(pressed ? 0.88 : 1, anchor: .topLeading).animation(KitMotion.press, value: pressed)
            }
            .offset(x: p.x, y: p.y)
        }
    }
}

enum IntroDemo {
    /// Cursor position on a smoothstep between waypoints (time, x, y); holds at both ends.
    static func position(_ path: [(Double, Double, Double)], _ t: Double) -> CGPoint {
        guard let first = path.first, let last = path.last else { return .zero }
        if t <= first.0 { return CGPoint(x: first.1, y: first.2) }
        if t >= last.0 { return CGPoint(x: last.1, y: last.2) }
        for i in 1..<path.count where t <= path[i].0 {
            let a = path[i - 1], b = path[i]
            let k = (t - a.0) / (b.0 - a.0), s = k * k * (3 - 2 * k)
            return CGPoint(x: lerp(a.1, b.1, s), y: lerp(a.2, b.2, s))
        }
        return CGPoint(x: last.1, y: last.2)
    }

    /// Spotlight rectangle: smoothstep between keys, holding at both ends.
    static func rect(_ keys: [(Double, CGRect)], _ t: Double) -> CGRect {
        guard let first = keys.first, let last = keys.last else { return .zero }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let a = keys[i - 1], b = keys[i], k = (t - a.0) / (b.0 - a.0), e = k * k * (3 - 2 * k)
            return CGRect(x: lerp(a.1.minX, b.1.minX, e), y: lerp(a.1.minY, b.1.minY, e), width: lerp(a.1.width, b.1.width, e), height: lerp(a.1.height, b.1.height, e))
        }
        return last.1
    }

    private static let shape: [Double] = [0, 0, 0.2, 2.6, 1.8, 0.4, 0, 0, 0.1, 1.2, 3.1, 0.8, 0, 0.3]
    private static let steps = 60
    /// Share (0...1) of the final percent reached at progress `p` of the elapsed window.
    static func cumulative(_ p: Double) -> Double {
        let w = (0..<steps).map { shape[$0 % shape.count] + 0.05 }
        let total = w.reduce(0, +), n = min(max(p, 0), 1) * Double(steps)
        let whole = Int(n)
        let done = w.prefix(whole).reduce(0, +) + (whole < steps ? w[whole] * (n - Double(whole)) : 0)
        return done / total
    }

    /// Weekly readings up to progress `p` of the 74 hours that have elapsed in a 168 hour window.
    static func readings(_ p: Double, final: Double) -> IntroReadings {
        let resets = Date().addingTimeInterval(94 * 3600), start = resets.addingTimeInterval(-168 * 3600)
        var out: [Reading] = []
        let n = Int(Double(steps) * min(max(p, 0), 1))
        for i in 0...max(n, 0) {
            let q = Double(i) / Double(steps)
            out.append(Reading(t: start.addingTimeInterval(q * 74 * 3600), p: final * cumulative(q), resets: resets))
        }
        let nowT = start.addingTimeInterval(p * 74 * 3600)
        out.append(Reading(t: nowT, p: final * cumulative(p), resets: resets))
        return IntroReadings(readings: out, resets: resets)
    }
}

struct IntroReadings { let readings: [Reading]; let resets: Date }

// MARK: Pieces

/// One service card as in the panel (header, figure and LED bar, optional strip and extra lines). `lit` is the
/// open-moment progress (segments and figure); it is driven by the timeline instead of an open event.
struct IntroCard<Extra: View>: View {
    let service: Service
    let label: String
    let value: Double
    var lit = 1.0
    var landing: Double? = nil
    var marker: Double? = nil
    var strip: IntroReadings? = nil
    var bordered = true
    var flash = false
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.m) {
            HStack(spacing: 6) {
                KitLed(on: lit > 0.02 || flash, color: Theme.accent(service))
                Text(service.name).font(KitFont.header).foregroundStyle(KitColor.text).fixedSize()
                Text("just now").font(KitFont.detail).foregroundStyle(KitColor.text3).padding(.leading, 4)
                Spacer()
                Text(label).font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
            HStack(spacing: KitSpace.m) {
                RollingFigure(value: flash ? 0 : Int(value.rounded()), openTick: 0)
                LedBar(service: service, value: flash ? 100 : value, landing: landing, marker: marker, openTick: 0)
            }
            .environment(\.tallyQA, QAFrame(lit: lit, entrance: 1))
            if let strip {
                VStack(alignment: .trailing, spacing: 3) {
                    HistoryStrip(service: service, readings: strip.readings, resets: strip.resets, length: 168 * 3600, landing: landing)
                    Text("resets Sat 20:00").font(.system(size: 10).monospacedDigit()).foregroundStyle(KitColor.text3)
                }
            }
            extra
        }
        .padding(KitSpace.l)
        .frame(width: bordered ? 440 : nil)
        .frame(maxWidth: bordered ? nil : .infinity)
        .overlay { if bordered { RoundedRectangle(cornerRadius: KitSpace.radius + 2).strokeBorder(KitColor.line, lineWidth: 1) } }
    }
}

extension IntroCard where Extra == EmptyView {
    init(service: Service, label: String, value: Double, lit: Double = 1, landing: Double? = nil, marker: Double? = nil,
         strip: IntroReadings? = nil, bordered: Bool = true, flash: Bool = false) {
        self.init(service: service, label: label, value: value, lit: lit, landing: landing, marker: marker, strip: strip, bordered: bordered, flash: flash) { EmptyView() }
    }
}

/// A drawn arrow, light with a 1 px dark outline; its tip is at the view's origin.
struct GhostCursor: View {
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 15)); p.addLine(to: CGPoint(x: 3.8, y: 11.6))
            p.addLine(to: CGPoint(x: 6.4, y: 17.4)); p.addLine(to: CGPoint(x: 9, y: 16.3)); p.addLine(to: CGPoint(x: 6.4, y: 10.6))
            p.addLine(to: CGPoint(x: 11.4, y: 10.6)); p.closeSubpath()
        }
        .fill(KitColor.text)
        .overlay(Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 15)); p.addLine(to: CGPoint(x: 3.8, y: 11.6))
            p.addLine(to: CGPoint(x: 6.4, y: 17.4)); p.addLine(to: CGPoint(x: 9, y: 16.3)); p.addLine(to: CGPoint(x: 6.4, y: 10.6))
            p.addLine(to: CGPoint(x: 11.4, y: 10.6)); p.closeSubpath()
        }.stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineJoin: .round)))
        .frame(width: 12, height: 18, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: Window

@MainActor
final class IntroController {
    static let shared = IntroController()
    private let presenter = IntroPresenter()
    private var model: IntroModel?
    var isShowing: Bool { presenter.isShowing }

    /// Opens the centred intro window. Only ever called on first launch or from "Show intro". Marked seen as soon
    /// as it is shown, so a window that fails to appear never repeats and the app works either way.
    func show(settings: Settings) {
        settings.introSeen = true
        if presenter.isShowing { presenter.focus(); return }
        let m = IntroModel()
        model = m
        m.onClose = { [weak self] in self?.presenter.close() }
        presenter.onClose = { [weak m] in m?.finish() }
        presenter.onNext = { [weak m] in m?.next() }
        presenter.onBack = { [weak m] in m?.back() }
        presenter.show(IntroView(model: m), size: CGSize(width: 640, height: 440))
        m.start()
    }
}

/// Stage minus a rounded hole (radius 12 = element radius 8 + 4 pt padding); `ring` draws only the hole outline.
struct SpotCut: Shape {
    var rect: CGRect
    var size: CGSize
    var ring = false
    func path(in _: CGRect) -> Path {
        var p = Path()
        if !ring { p.addRect(CGRect(x: -4, y: -4, width: size.width + 8, height: size.height + 8)) }
        let hole = rect.intersection(CGRect(origin: .zero, size: size))
        if !hole.isNull { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12)) }
        return p
    }
}
