// Renders the Sharkbox app icon (blue rounded square, white shark fin) into an .iconset directory.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS-style rounded square with a vertical gradient
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.21, yRadius: s * 0.21)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.25, blue: 0.62, alpha: 1))!.draw(in: bg, angle: -90)
    // water
    let water = NSBezierPath()
    water.move(to: NSPoint(x: rect.minX, y: rect.minY))
    water.line(to: NSPoint(x: rect.minX, y: s * 0.36))
    var x = rect.minX
    let wave = s * 0.08
    while x < rect.maxX {
        water.curve(to: NSPoint(x: x + wave * 2, y: s * 0.36),
                    controlPoint1: NSPoint(x: x + wave * 0.5, y: s * 0.36 + wave * 0.6),
                    controlPoint2: NSPoint(x: x + wave * 1.5, y: s * 0.36 - wave * 0.6))
        x += wave * 2
    }
    water.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    water.close()
    bg.addClip()
    NSColor(calibratedRed: 0.0, green: 0.18, blue: 0.48, alpha: 0.55).setFill()
    water.fill()
    // fin
    let fin = NSBezierPath()
    fin.move(to: NSPoint(x: s * 0.28, y: s * 0.37))
    fin.curve(to: NSPoint(x: s * 0.60, y: s * 0.80),
              controlPoint1: NSPoint(x: s * 0.40, y: s * 0.45), controlPoint2: NSPoint(x: s * 0.53, y: s * 0.62))
    fin.curve(to: NSPoint(x: s * 0.74, y: s * 0.37),
              controlPoint1: NSPoint(x: s * 0.63, y: s * 0.60), controlPoint2: NSPoint(x: s * 0.69, y: s * 0.45))
    fin.close()
    NSColor.white.setFill()
    fin.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("icons written to \(outDir)")
