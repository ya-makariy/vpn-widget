// Renders the app icon into an .iconset directory with CoreGraphics, so that
// no asset catalog or binary file is needed.
// usage: swift make-icon.swift <iconset dir>
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225

    // Background: rounded square with a dark blue-green gradient.
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.07, green: 0.15, blue: 0.26, alpha: 1), CGColor(red: 0.05, green: 0.36, blue: 0.40, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Ring with segments: the status ring from the menu bar.
    let center = CGPoint(x: s / 2, y: s / 2)
    let ringRadius = rect.width * 0.34
    let ringWidth = rect.width * 0.075
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)
    let segments = 4
    let gap = CGFloat.pi / 180 * 10
    for i in 0..<segments {
        let start = CGFloat.pi / 2 - CGFloat(i) * (2 * .pi / CGFloat(segments)) - gap / 2
        let end = start - (2 * .pi / CGFloat(segments)) + gap
        ctx.setStrokeColor(i < 3 ? CGColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
    }

    // Shield in the middle.
    let shieldW = rect.width * 0.30
    let shieldH = rect.width * 0.36
    let top = center.y + shieldH / 2
    let left = center.x - shieldW / 2
    let right = center.x + shieldW / 2
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: left, y: top - shieldH * 0.12))
    shield.addQuadCurve(to: CGPoint(x: center.x, y: top), control: CGPoint(x: center.x - shieldW * 0.25, y: top))
    shield.addQuadCurve(to: CGPoint(x: right, y: top - shieldH * 0.12), control: CGPoint(x: center.x + shieldW * 0.25, y: top))
    shield.addLine(to: CGPoint(x: right, y: center.y - shieldH * 0.05))
    shield.addQuadCurve(to: CGPoint(x: center.x, y: center.y - shieldH / 2), control: CGPoint(x: right, y: center.y - shieldH * 0.42))
    shield.addQuadCurve(to: CGPoint(x: left, y: center.y - shieldH * 0.05), control: CGPoint(x: left, y: center.y - shieldH * 0.42))
    shield.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.addPath(shield)
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    try write(draw(size: CGFloat(base)), "icon_\(base)x\(base).png")
    try write(draw(size: CGFloat(base * 2)), "icon_\(base)x\(base)@2x.png")
}
print("Rendered \(out)")
