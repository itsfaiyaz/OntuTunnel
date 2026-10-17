// Renders Resources/AppIcon.icns (run once: swift scripts/make-icon.swift)
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(red: 0.02, green: 0.047, blue: 0.106, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.106, blue: 0.235, alpha: 1))!.draw(in: path, angle: -90)
    // tunnel arch
    let arch = NSBezierPath()
    arch.lineWidth = s * 0.055
    arch.lineCapStyle = .round
    arch.appendArc(withCenter: NSPoint(x: s / 2, y: s * 0.30), radius: s * 0.27, startAngle: 0, endAngle: 180)
    NSColor(red: 0.243, green: 0.545, blue: 1, alpha: 0.35).setStroke()
    arch.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.34, weight: .bold)
        .applying(.init(paletteColors: [NSColor(red: 0.243, green: 0.545, blue: 1, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "arrow.right.arrow.left", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes where size <= 512 {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Resources/AppIcon.icns")
