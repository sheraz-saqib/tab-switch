// Draws the app icon in code (no image assets). Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let S: CGFloat = 1024
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rr(_ r: CGRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt tile centred in 1024, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = c(0x000000, 0.35); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
c(0x1C1D21).setFill(); rr(tile, 185).fill()
NSGraphicsContext.restoreGraphicsState()
// faint top edge highlight
c(0xFFFFFF, 0.06).setStroke(); let edge = rr(tile.insetBy(dx: 2, dy: 2), 183); edge.lineWidth = 3; edge.stroke()

// Window card with title-bar dots.
func card(_ r: CGRect, body: NSColor, bar: NSColor, dots: [NSColor]) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = c(0x000000, 0.45); s.shadowBlurRadius = 18; s.shadowOffset = NSSize(width: 0, height: -8); s.set()
    body.setFill(); rr(r, 34).fill()
    NSGraphicsContext.restoreGraphicsState()
    let barH: CGFloat = r.height * 0.17
    NSGraphicsContext.saveGraphicsState(); rr(r, 34).addClip()
    bar.setFill(); NSBezierPath(rect: CGRect(x: r.minX, y: r.maxY - barH, width: r.width, height: barH)).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (i, d) in dots.enumerated() {
        d.setFill()
        NSBezierPath(ovalIn: CGRect(x: r.minX + 30 + CGFloat(i) * 34, y: r.maxY - barH / 2 - 11, width: 22, height: 22)).fill()
    }
}

let grey = c(0x5A5E68)
// back cards, fanned up-left like the switcher row
card(CGRect(x: 214, y: 486, width: 420, height: 300), body: c(0x2E3036), bar: c(0x3A3D45), dots: [grey, grey, grey])
card(CGRect(x: 288, y: 400, width: 440, height: 316), body: c(0x383B42), bar: c(0x464A53), dots: [grey, grey, grey])

// front (selected) card
let front = CGRect(x: 362, y: 238, width: 470, height: 340)
card(front, body: c(0xF3EFE6), bar: c(0xE2DDD1), dots: [c(0xEC6A5E), c(0xF4BF4F), c(0x61C554)])
// two content lines
c(0xC9C3B5).setFill()
rr(CGRect(x: front.minX + 40, y: front.minY + 150, width: 300, height: 26), 13).fill()
rr(CGRect(x: front.minX + 40, y: front.minY + 100, width: 210, height: 26), 13).fill()
// selection ring
let ring = rr(front.insetBy(dx: -16, dy: -16), 48); ring.lineWidth = 14
c(0xFFA62B).setStroke(); ring.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
