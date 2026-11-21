import SwiftUI

/// Fixed animation progress for QA renders of the open moment (nil in the app).
struct QAFrame: Equatable { var lit: Double; var entrance: Double }
extension EnvironmentValues { @Entry var tallyQA: QAFrame? = nil }

/// The signature: a wide LED level bar. Lit segments to the reading (accent, amber past 70, red past 90),
/// hollow outlined segments from the reading to where the current pace lands, and an optional
/// 1 pt marker (today's budget limit). On open the segments light left to right (KitMotion.stagger),
/// then the projection fades in. New readings move the same segments smoothly.
struct LedBar: View {
    static let segments = 40
    let service: Service
    let value: Double?          // percent; nil: no fresh data, bar stays dark
    let landing: Double?        // percent where the pace ends up (100 = reaches the limit)
    let marker: Double?         // percent
    let openTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tallyQA) private var qa
    @State private var lit: Int
    @State private var showProjection = true

    init(service: Service, value: Double?, landing: Double?, marker: Double?, openTick: Int) {
        self.service = service; self.value = value; self.landing = landing; self.marker = marker; self.openTick = openTick
        _lit = State(initialValue: Self.count(value))
    }

    /// Segments lit for a percent: those whose end is at or below it, and at least one for any use.
    static func count(_ v: Double?) -> Int {
        guard let v, v > 0 else { return 0 }
        return max(1, Int((v / 100 * Double(segments) + 0.0001).rounded(.down)))
    }

    var body: some View {
        let n = Self.segments
        let target = Self.count(value)
        let shownLit = qa.map { Int((Double(target) * $0.lit).rounded()) } ?? lit
        let projection = qa.map { max(0, ($0.lit - 0.8) / 0.2) } ?? (showProjection ? 1 : 0)
        HStack(spacing: 2) {
            ForEach(0..<n, id: \.self) { i in
                let pos = Double(i + 1) / Double(n)
                let on = i < shownLit
                let hollow = landing.map { value != nil && i >= target && pos <= $0 / 100 + 0.0001 } ?? false
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? color(pos) : KitColor.well)
                    .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Theme.accent(service), lineWidth: 1).opacity(hollow ? projection : 0))
                    .animation(qa != nil ? nil : reduceMotion ? .easeOut(duration: 0.15) : KitMotion.stagger(i, step: 0.006, max: 0.25), value: on)
                    .animation(qa != nil ? nil : KitMotion.soft, value: hollow)
            }
        }
        .drawingGroup()
        .frame(height: 18)
        .overlay(alignment: .leading) {
            if let marker, marker >= 0, marker <= 100 {
                GeometryReader { g in
                    Rectangle().fill(KitColor.text2).frame(width: 1, height: 24)
                        .offset(x: (g.size.width * marker / 100).rounded() - 0.5, y: -3)
                }
            }
        }
        .animation(qa != nil ? nil : KitMotion.list, value: showProjection)
        .onChange(of: target) { lit = target }
        .onChange(of: openTick) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { lit = 0; showProjection = false }
            DispatchQueue.main.async {
                lit = target
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.3)) { showProjection = true }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(service.name) level")
        .accessibilityValue(value.map { "\(Fmt.percent($0)) percent" } ?? "no data")
    }

    private func color(_ pos: Double) -> Color { pos > 0.9 ? KitColor.red : pos > 0.7 ? KitColor.amber : Theme.accent(service) }
}

/// History of one window over the whole window (start at the left, reset at the right): readings as a
/// polyline ending in a lit dot at "now", then a dashed line to where the pace lands at reset.
struct HistoryStrip: View {
    let service: Service
    let readings: [Reading]     // this window's readings, oldest first, the current one last
    let resets: Date?
    let length: TimeInterval
    let landing: Double?        // percent at reset on the current pace
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { ctx, size in
            let hair = 1 / scale
            let top: CGFloat = 3, bottom = size.height - 3
            func y(_ p: Double) -> CGFloat { bottom - (bottom - top) * CGFloat(min(100, max(0, p)) / 100) }
            for g in [0.0, 50, 100] {
                var l = Path(); l.move(to: CGPoint(x: 0, y: y(g))); l.addLine(to: CGPoint(x: size.width, y: y(g)))
                ctx.stroke(l, with: .color(KitColor.line), lineWidth: hair)
            }
            guard let resets, !readings.isEmpty else { return }
            let start = resets.addingTimeInterval(-length)
            func x(_ t: Date) -> CGFloat { size.width * CGFloat(min(1, max(0, t.timeIntervalSince(start) / length))) }
            // Keep a point only when it is at least 2 px right of the last kept one; the newest point is always kept.
            var pts: [CGPoint] = []
            for (i, r) in readings.enumerated() {
                let p = CGPoint(x: x(r.t), y: y(r.p))
                if i == readings.count - 1 {
                    if let last = pts.last, p.x - last.x < 2 { pts.removeLast() }
                    pts.append(p)
                } else if pts.last.map({ p.x - $0.x >= 2 }) ?? true { pts.append(p) }
            }
            let accent = Theme.accent(service)
            if pts.count > 1 {
                var line = Path(); line.addLines(pts)
                ctx.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            let now = pts[pts.count - 1]
            if let landing, now.x < size.width - 1 {
                var d = Path(); d.move(to: now); d.addLine(to: CGPoint(x: size.width, y: y(landing)))
                ctx.stroke(d, with: .color(KitColor.text3), style: StrokeStyle(lineWidth: hair, dash: [3, 3]))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: now.x - 2.5, y: now.y - 2.5, width: 5, height: 5)), with: .color(accent))
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }
}
