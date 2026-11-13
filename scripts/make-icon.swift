#!/usr/bin/env swift
// Draws the Better Preview app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]   (also writes build/AppIcon-1024.png for preview)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let icnsPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root.appendingPathComponent("Resources/AppIcon.icns").path

func hex(_ s: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((s >> 16) & 255) / 255, green: CGFloat((s >> 8) & 255) / 255,
            blue: CGFloat(s & 255) / 255, alpha: a)
}
// Catppuccin Mocha
let crust = hex(0x11111b), mantle = hex(0x181825), base = hex(0x1e1e2e), surface0 = hex(0x313244)
let text = hex(0xcdd6f4), mauve = hex(0xcba6f7), blue = hex(0x89b4fa), overlay = hex(0x6c7086)

/// Draws the icon into the current context on a 1024 x 1024 canvas.
func draw() {
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824 px rounded square centred in 1024, with a soft shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    base.setFill(); tilePath.fill()
    ctx.restoreGState()
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colors: [surface0, base, mantle], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -90)

    // Document page with folded corner.
    let page = NSRect(x: 292, y: 218, width: 440, height: 588)
    let fold: CGFloat = 130
    let r: CGFloat = 26
    let p = NSBezierPath()
    p.move(to: NSPoint(x: page.minX + r, y: page.minY))
    p.line(to: NSPoint(x: page.maxX - r, y: page.minY))
    p.curve(to: NSPoint(x: page.maxX, y: page.minY + r), controlPoint1: NSPoint(x: page.maxX - r / 2, y: page.minY), controlPoint2: NSPoint(x: page.maxX, y: page.minY + r / 2))
    p.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    p.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    p.line(to: NSPoint(x: page.minX + r, y: page.maxY))
    p.curve(to: NSPoint(x: page.minX, y: page.maxY - r), controlPoint1: NSPoint(x: page.minX + r / 2, y: page.maxY), controlPoint2: NSPoint(x: page.minX, y: page.maxY - r / 2))
    p.line(to: NSPoint(x: page.minX, y: page.minY + r))
    p.curve(to: NSPoint(x: page.minX + r, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + r / 2), controlPoint2: NSPoint(x: page.minX + r / 2, y: page.minY))
    p.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    hex(0xe9ecfa).setFill(); p.fill()
    ctx.restoreGState()
    ctx.saveGState()
    p.addClip()
    NSGradient(colors: [hex(0xf5f6fd), hex(0xd9deef)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: page, angle: -90)
    ctx.restoreGState()

    // Folded corner.
    let f = NSBezierPath()
    f.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    f.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 22))
    f.curve(to: NSPoint(x: page.maxX - fold + 22, y: page.maxY - fold), controlPoint1: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 8), controlPoint2: NSPoint(x: page.maxX - fold + 8, y: page.maxY - fold))
    f.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    f.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -4, height: -6), blur: 10, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSGradient(colors: [hex(0xb9c0dd), hex(0xdfe3f3)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: f, angle: -45)
    ctx.restoreGState()

    // Faint text lines.
    for (i, w) in [300.0, 340, 250].enumerated() {
        let y = page.maxY - 190 - CGFloat(i) * 46
        let line = NSBezierPath(roundedRect: NSRect(x: page.minX + 54, y: y, width: CGFloat(w), height: 18), xRadius: 9, yRadius: 9)
        hex(0xb4bbd6).setFill(); line.fill()
    }

    // Vim ":" and a block cursor in accent colours.
    let dot: CGFloat = 52
    let colonX = page.minX + 115
    for y in [page.minY + 70, page.minY + 70 + 112] {
        let d = NSBezierPath(ovalIn: NSRect(x: colonX, y: y, width: dot, height: dot))
        mauve.setFill(); d.fill()
    }
    let block = NSBezierPath(roundedRect: NSRect(x: colonX + dot + 46, y: page.minY + 62, width: 112, height: 176), xRadius: 14, yRadius: 14)
    NSGradient(colors: [mauve, blue], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: block, angle: -90)
    ctx.restoreGState()

    // Subtle inner edge on the tile.
    hex(0xffffff, 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    edge.lineWidth = 3; edge.stroke()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let s = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("bp-icon-\(getpid())")
let set = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let big = root.appendingPathComponent("build/AppIcon-1024.png")
try png(size: 1024).write(to: big)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", icnsPath]
try task.run(); task.waitUntilExit()
try? fm.removeItem(at: work)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icnsPath)")
