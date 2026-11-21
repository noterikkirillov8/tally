import AppKit

/// Menu bar image: two tiny vertical level bars (Claude, Codex) filled to their percent.
/// Drawn at any scale by a handler, so it is crisp at 1x and 2x. Missing or expired readings are empty outlines.
@MainActor
enum StatusIcon {
    static let barWidth: CGFloat = 6, barHeight: CGFloat = 14, gap: CGFloat = 3

    static func image(levels: [Double?]) -> NSImage {
        image(readings: levels.map { Level(percent: $0, dimmed: false) })
    }

    struct Level {
        let percent: Double?
        let dimmed: Bool
    }

    static func image(readings levels: [Level]) -> NSImage {
        let n = max(levels.count, 1)
        let size = NSSize(width: CGFloat(n) * barWidth + CGFloat(n - 1) * gap, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            for (i, level) in levels.enumerated() {
                let x = CGFloat(i) * (barWidth + gap)
                let frame = NSRect(x: x + 0.5, y: 1.5, width: barWidth - 1, height: barHeight - 1)
                let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
                outline.lineWidth = 1
                outline.stroke()
                guard let percent = level.percent else { continue }
                NSColor.black.withAlphaComponent(level.dimmed ? 0.55 : 1).setFill()
                let inner = NSRect(x: x + 2, y: 3, width: barWidth - 4, height: barHeight - 4)
                let h = percent > 0 ? max(1, inner.height * min(1, percent / 100)) : 0
                NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: h), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func levels(model: TallyModel) -> [Level] {
        let shown = Service.allCases.filter { model.settings.shows($0) }
        return (shown.isEmpty ? Service.allCases : shown).map {
            let usage = model.state($0).usage
            let percent = usage?.menuPercent(model.settings.metric, now: model.now)
            return Level(percent: percent, dimmed: percent != nil && usage?.isStale(now: model.now) == true)
        }
    }

    static func title(model: TallyModel) -> NSAttributedString {
        let title = NSMutableAttributedString(string: "")
        if model.settings.showNumbers {
            for (index, level) in levels(model: model).enumerated() {
                let text = (index == 0 ? " " : "  ") + (level.percent.map(Fmt.percent) ?? "—")
                title.append(NSAttributedString(string: text, attributes: level.dimmed ? [.foregroundColor: NSColor.secondaryLabelColor] : [:]))
            }
        }
        return title
    }
}
