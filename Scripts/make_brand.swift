// SPDX-License-Identifier: AGPL-3.0-or-later
// Rebuild with: swift Scripts/make_brand.swift
// mark.json is the shared vector source for the native mark, app icon and website.
import AppKit
import Foundation

struct Mark: Decodable {
    let viewBox: Double
    let strokeWidth: Double
    let curve: [[Double]]
    let lines: [[Double]]
    let dot: [Double]
    let ink: String
    let paper: String
    let accent: String
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let mark = try JSONDecoder().decode(
    Mark.self, from: Data(contentsOf: root.appendingPathComponent("Design/Brand/mark.json")))
func color(_ hex: String) -> NSColor {
    let n = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(
        srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255,
        alpha: 1)
}
func drawMark(_ foreground: NSColor, accent: NSColor) {
    foreground.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: mark.curve[0][0], y: mark.curve[0][1]))
    for p in mark.curve.dropFirst() {
        path.curve(
            to: NSPoint(x: p[4], y: p[5]), controlPoint1: NSPoint(x: p[0], y: p[1]),
            controlPoint2: NSPoint(x: p[2], y: p[3]))
    }
    path.lineWidth = mark.strokeWidth
    path.lineCapStyle = .round
    path.stroke()
    for p in mark.lines {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: p[0], y: p[1]))
        line.line(to: NSPoint(x: p[2], y: p[3]))
        line.lineWidth = 3.5
        line.lineCapStyle = .round
        line.stroke()
    }
    accent.setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: mark.dot[0] - mark.dot[2], y: mark.dot[1] - mark.dot[2], width: mark.dot[2] * 2, height: mark.dot[2] * 2)
    ).fill()
}
func image(size: Int, icon: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 100, y: -CGFloat(size) / 100)
    if icon {
        color(mark.ink).setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 90, height: 90), xRadius: 20, yRadius: 20).fill()
        context.translateBy(x: 9, y: 9)
        context.scaleBy(x: 0.82, y: 0.82)
    }
    drawMark(color(icon ? mark.paper : mark.ink), accent: color(mark.accent))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let brand = root.appendingPathComponent("Resources/Brand")
let site = root.appendingPathComponent("site/assets")
for path in [brand, site] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
let png = image(size: 1024, icon: true).representation(using: .png, properties: [:])!
try png.write(to: brand.appendingPathComponent("app-icon.png"))
try png.write(to: site.appendingPathComponent("app-icon.png"))
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try image(size: size * scale, icon: true).representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent(name))
    }
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", directory.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
let commands =
    "M \(mark.curve[0][0]) \(mark.curve[0][1]) "
    + mark.curve.dropFirst().map { "C " + $0.map(String.init(describing:)).joined(separator: " ") }.joined(
        separator: " ")
let lines = mark.lines.map { "<path d=\"M \($0[0]) \($0[1]) L \($0[2]) \($0[3])\"/>" }.joined()
let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="Cadence">
    <g fill="none" stroke="\(mark.ink)" stroke-linecap="round"><path stroke-width="\(mark.strokeWidth)" d="\(commands)"/><g stroke-width="3.5">\(lines)</g></g><circle cx="\(mark.dot[0])" cy="\(mark.dot[1])" r="\(mark.dot[2])" fill="\(mark.accent)"/></svg>
    """
try Data(svg.utf8).write(to: root.appendingPathComponent("Design/Brand/mark.svg"))
try Data(svg.utf8).write(to: site.appendingPathComponent("mark.svg"))
try image(size: 192, icon: false).representation(using: .png, properties: [:])!.write(
    to: brand.appendingPathComponent("mark.png"))
print("Rebuilt app icon and brand assets from mark.json")
