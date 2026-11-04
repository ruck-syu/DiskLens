// Renders the DiskLens app icon (a rounded square with treemap blocks) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: ~824px body centered, 185px corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.12, alpha: 1)])!
    .draw(in: shape, angle: -90)

shape.addClip()
let inset = body.insetBy(dx: 120, dy: 120)
func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hue: CGFloat, _ b: CGFloat = 0.9) {
    let r = NSRect(x: inset.minX + x * inset.width, y: inset.minY + y * inset.height,
                   width: w * inset.width, height: h * inset.height).insetBy(dx: 9, dy: 9)
    let p = NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26)
    NSGradient(colors: [NSColor(calibratedHue: hue, saturation: 0.62, brightness: b, alpha: 1),
                        NSColor(calibratedHue: hue, saturation: 0.75, brightness: b * 0.78, alpha: 1)])!
        .draw(in: p, angle: -60)
}
block(0, 0, 0.58, 1, 0.58)
block(0.58, 0.45, 0.42, 0.55, 0.47)
block(0.58, 0, 0.24, 0.45, 0.08)
block(0.82, 0.22, 0.18, 0.23, 0.92)
block(0.82, 0, 0.18, 0.22, 0.75)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
