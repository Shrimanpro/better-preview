// Generates build/test-assets/{long.pdf,short.pdf,photo.png}. Run: swift scripts/make-test-assets.swift
import AppKit
import CoreText

let dir = URL(fileURLWithPath: "build/test-assets", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func makePDF(_ name: String, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(dir.appendingPathComponent(name) as CFURL, mediaBox: &box, nil)!
    let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "zathura",
                 "preview", "vim", "motion", "needle", "theme", "scroll"]
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        var text = "Page \(p) of \(pages)\n\n"
        var seed = UInt64(p) &* 6364136223846793005 &+ 1442695040888963407
        for i in 0..<420 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            text += words[Int(seed >> 33) % words.count] + (i % 12 == 11 ? ".\n" : " ")
        }
        if p % 50 == 0 { text += "\nUNIQUEMARKER\(p)" }
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 72, y: 40, width: CGFloat(p) / CGFloat(pages) * 468, height: 6))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

makePDF("long.pdf", pages: 500)
makePDF("short.pdf", pages: 3)

let image = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
    NSGradient(colors: [.systemTeal, .systemIndigo, .systemPink])!.draw(in: rect, angle: 30)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 600, y: 300, width: 400, height: 400)).fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("photo.png"))
print("wrote", dir.path)
