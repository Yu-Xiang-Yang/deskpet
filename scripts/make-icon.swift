// Draws the app icon (a paw print and a sparkle on a pastel plate) and writes Resources/AppIcon.icns.
//
//   swiftc -O -sdk "$(xcrun --show-sdk-path)" scripts/make-icon.swift -o /tmp/make-icon
//   /tmp/make-icon Resources [preview.png]
//
// The artwork is generated from shapes only.

import AppKit
import CoreGraphics

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let previewPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func bitmap(_ pixels: Int, _ draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(context.cgContext, CGFloat(pixels) / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The Big Sur icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpaceCreateDeviceRGB()
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0.25, 0.1, 0.35, 0.3))
    ctx.addPath(plate)
    ctx.setFillColor(color(1, 0.8, 0.9))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(1.0, 0.72, 0.85), color(0.66, 0.58, 1.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.35), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Paw print: one main pad and four toe beans.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.35, 0.2, 0.55, 0.35))
    ctx.setFillColor(color(1, 1, 1))
    let pad = CGMutablePath()
    pad.move(to: CGPoint(x: 512, y: 560))
    pad.addCurve(to: CGPoint(x: 680, y: 380), control1: CGPoint(x: 610, y: 560), control2: CGPoint(x: 700, y: 470))
    pad.addCurve(to: CGPoint(x: 512, y: 300), control1: CGPoint(x: 668, y: 310), control2: CGPoint(x: 580, y: 300))
    pad.addCurve(to: CGPoint(x: 344, y: 380), control1: CGPoint(x: 444, y: 300), control2: CGPoint(x: 356, y: 310))
    pad.addCurve(to: CGPoint(x: 512, y: 560), control1: CGPoint(x: 324, y: 470), control2: CGPoint(x: 414, y: 560))
    ctx.addPath(pad)
    for (x, y, rx, ry) in [(330.0, 580.0, 58.0, 72.0), (440, 668, 62, 78), (584, 668, 62, 78), (694, 580, 58, 72)] {
        ctx.addEllipse(in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    }
    ctx.fillPath()
    ctx.restoreGState()

    // Beans tinted pink.
    ctx.setFillColor(color(1.0, 0.56, 0.72, 0.55))
    ctx.addEllipse(in: CGRect(x: 452, y: 368, width: 120, height: 90))
    ctx.fillPath()

    // Four-point sparkle at the top right.
    let c = CGPoint(x: 760, y: 770)
    let star = CGMutablePath()
    let r1: CGFloat = 70, r2: CGFloat = 16
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let r = i % 2 == 0 ? r1 : r2
        let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
    }
    star.closeSubpath()
    ctx.addPath(star)
    ctx.setFillColor(color(1.0, 0.92, 0.5))
    ctx.fillPath()
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let rep = bitmap(size * scale, drawIcon)
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.icns").path]
try! process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "iconutil failed")
try? fileManager.removeItem(at: iconset)

if let previewPath {
    try! bitmap(512, drawIcon).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewPath))
}
print("Wrote \(outputDirectory)/AppIcon.icns")
