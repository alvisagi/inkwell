// Renders the app icon into app/Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // Big Sur grid: 824pt body centered, with a soft shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.20, green: 0.62, blue: 0.68, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.06, green: 0.24, blue: 0.36, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Faint typesetting grid.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(3 * s)
    for i in 1..<8 {
        let x = body.minX + CGFloat(i) * body.width / 8
        ctx.move(to: CGPoint(x: x, y: body.minY)); ctx.addLine(to: CGPoint(x: x, y: body.maxY))
        let y = body.minY + CGFloat(i) * body.height / 8
        ctx.move(to: CGPoint(x: body.minX, y: y)); ctx.addLine(to: CGPoint(x: body.maxX, y: y))
    }
    ctx.strokePath()
    // A baseline.
    ctx.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.78, blue: 0.35, alpha: 0.9).cgColor)
    ctx.setLineWidth(10 * s)
    ctx.move(to: CGPoint(x: body.minX + 120 * s, y: body.minY + 250 * s))
    ctx.addLine(to: CGPoint(x: body.maxX - 120 * s, y: body.minY + 250 * s))
    ctx.strokePath()
    ctx.restoreGState()

    // The letter.
    let font = NSFont(name: "Georgia-Bold", size: 600 * s) ?? NSFont.systemFont(ofSize: 600 * s, weight: .heavy)
    let text = NSAttributedString(string: "t", attributes: [.font: font, .foregroundColor: NSColor.white])
    let bounds = text.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    text.draw(at: CGPoint(x: body.midX - bounds.width / 2 - bounds.minX, y: body.minY + 262 * s + font.descender))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
print("icon written to \(output)")
