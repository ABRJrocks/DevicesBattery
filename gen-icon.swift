// Renders AppIcon.icns: green-gradient squircle + white battery glyph.
// Run: swift gen-icon.swift  (regenerates Assets/AppIcon.icns)
import AppKit

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = image.copy() as! NSImage
    img.lockFocus()
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

let canvas = NSImage(size: NSSize(width: 1024, height: 1024))
canvas.lockFocus()

// macOS icon grid: 824pt squircle centered on a 1024 canvas, r ≈ 22.37%.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 184, yRadius: 184)

// Soft drop shadow behind the squircle.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.black.withAlphaComponent(0.01).setFill()
path.fill()
NSShadow().set()

NSGradient(colors: [
    NSColor(red: 0.24, green: 0.86, blue: 0.41, alpha: 1),   // vivid green
    NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 1),   // deep green
])!.draw(in: path, angle: -90)

// Subtle top highlight for depth.
let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 24), xRadius: 168, yRadius: 168)
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.25),
    NSColor.white.withAlphaComponent(0.0),
])!.draw(in: highlight, angle: -90)

// White battery-with-bolt glyph.
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
let symbol = NSImage(systemSymbolName: "battery.100percent.bolt", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let glyph = tinted(symbol, .white)
let scale = 560.0 / glyph.size.width
let gs = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
glyph.draw(in: NSRect(x: 512 - gs.width / 2, y: 512 - gs.height / 2,
                      width: gs.width, height: gs.height))

canvas.unlockFocus()

// Emit the iconset and compile to icns.
let fm = FileManager.default
let iconset = "Assets/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                   ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    canvas.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Assets/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "Assets/AppIcon.icns written" : "iconutil failed")
