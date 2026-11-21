// Draws the Tally app icon (flat: graphite body, a lit LED level bar with a hollow projection) into the asset catalog.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func c(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)
    c(0x1B1C1F).setFill(); path.fill()
    c(0x2C2D31).setStroke(); path.lineWidth = 6 * s; path.stroke()
    // LED
    c(0xD97757).setFill()
    NSBezierPath(ovalIn: NSRect(x: 226 * s, y: 736 * s, width: 44 * s, height: 44 * s)).fill()
    // The level bar: 14 segments, 8 lit, 3 hollow, the rest dark.
    let n = 14, w = 36.0, gap = 14.0, h = 300.0
    let total = Double(n) * w + Double(n - 1) * gap
    let x0 = (1024 - total) / 2, y0 = 362.0
    for i in 0..<n {
        let r = NSRect(x: (x0 + Double(i) * (w + gap)) * s, y: y0 * s, width: w * s, height: h * s)
        let p = NSBezierPath(roundedRect: r, xRadius: 8 * s, yRadius: 8 * s)
        if i < 8 { c(0xD97757).setFill(); p.fill() }
        else if i < 11 {
            c(0xD97757).setStroke()
            let q = NSBezierPath(roundedRect: r.insetBy(dx: 3 * s, dy: 3 * s), xRadius: 6 * s, yRadius: 6 * s)
            q.lineWidth = 6 * s; q.stroke()
        } else { c(0x2B2C30).setFill(); p.fill() }
    }
    // Budget marker
    c(0xECEBE7).setFill()
    NSRect(x: (x0 + 11 * (w + gap) - gap / 2 - 3) * s, y: (y0 - 36) * s, width: 6 * s, height: (h + 72) * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "Tally/Resources/Assets.xcassets/AppIcon.appiconset/"
for px in [16, 32, 64, 128, 256, 512, 1024] { try! draw(px).write(to: URL(fileURLWithPath: dir + "icon_\(px).png")) }
