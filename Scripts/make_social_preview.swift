// SPDX-License-Identifier: AGPL-3.0-or-later
// Rebuild the original social artwork with: swift Scripts/make_social_preview.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let paper = color(0xf7f5ec), ink = color(0x202f29), green = color(0x234d40), accent = color(0xb45533)
paper.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 640).fill()
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, serif: Bool = false, ink: NSColor = ink) {
    let font = serif ? NSFont(name: "Georgia", size: size)! : NSFont.systemFont(ofSize: size, weight: .medium)
    (value as NSString).draw(at: NSPoint(x: x, y: 640 - top - font.ascender - 8),
        withAttributes: [.font: font, .foregroundColor: ink])
}
NSImage(contentsOf: root.appendingPathComponent("Resources/Brand/mark.png"))!.draw(in: NSRect(x: 55, y: 514, width: 66, height: 66))
text("cadence", x: 132, top: 59, size: 42, serif: true)
text("Learn the music", x: 62, top: 177, size: 66, serif: true)
text("you love.", x: 62, top: 252, size: 66, serif: true)
text("Make it your own.", x: 62, top: 336, size: 48, serif: true, ink: green)
text("Piano, guitar & music theory. Connected.", x: 65, top: 439, size: 22)
text("FREE & OPEN SOURCE  /  FOR MAC", x: 65, top: 554, size: 16, ink: green)
let panel = NSBezierPath(roundedRect: NSRect(x: 750, y: 42, width: 488, height: 556), xRadius: 24, yRadius: 24)
green.setFill(); panel.fill()
text("HEAR. PLAY. CREATE.", x: 790, top: 87, size: 17, ink: paper)
text("Dm7", x: 790, top: 172, size: 34, serif: true, ink: paper)
text("D♭7", x: 949, top: 172, size: 34, serif: true, ink: color(0xe9b494))
text("Cmaj7", x: 1090, top: 172, size: 34, serif: true, ink: paper)
func voice(_ points: [(CGFloat, CGFloat)], _ colour: NSColor) {
    colour.setStroke(); colour.setFill()
    let path = NSBezierPath(); path.lineWidth = 3
    for (i, point) in points.enumerated() {
        let p = NSPoint(x: point.0, y: 640 - point.1)
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.stroke()
    for p in points { NSBezierPath(ovalIn: NSRect(x: p.0 - 7, y: 640 - p.1 - 7, width: 14, height: 14)).fill() }
}
voice([(824, 286), (987, 317), (1150, 317)], color(0xe9b494))
voice([(824, 365), (987, 365), (1150, 397)], paper)
text("C", x: 817, top: 247, size: 19, ink: paper)
text("C♭", x: 974, top: 279, size: 19, ink: paper)
text("B", x: 1143, top: 279, size: 19, ink: paper)
text("F", x: 817, top: 379, size: 19, ink: paper)
text("F", x: 980, top: 379, size: 19, ink: paper)
text("E", x: 1143, top: 410, size: 19, ink: paper)
text("BASS", x: 791, top: 490, size: 13, ink: paper)
text("D   →   D♭   →   C", x: 888, top: 482, size: 28, serif: true, ink: color(0xe9b494))
NSGraphicsContext.restoreGraphicsState()
let output = root.appendingPathComponent("site/assets/social-preview.png")
try rep.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
