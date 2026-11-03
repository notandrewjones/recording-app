// Draws App/Assets.xcassets/AppIcon.appiconset: one record dot shared across a 2x2 multiview, each channel isolated.
// Run from the repo root: swift tools/make-app-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = "App/Assets.xcassets/AppIcon.appiconset"
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: [bottom, top] as CFArray, locations: [0, 1])!
}

/// Apple's icon grid: an 824-point shape centred on a 1024-point canvas, with continuous corners.
func squirclePath(center: CGFloat, radius: CGFloat) -> CGPath {
    let exponent = 5.0
    let path = CGMutablePath()
    for step in 0..<720 {
        let angle = Double(step) / 720 * 2 * .pi
        let x = copysign(pow(abs(cos(angle)), 2 / exponent), cos(angle))
        let y = copysign(pow(abs(sin(angle)), 2 / exponent), sin(angle))
        let point = CGPoint(x: center + radius * x, y: center + radius * y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    let center: CGFloat = 512
    let tile = squirclePath(center: center, radius: 412)
    // Small sizes get a bigger dot and wider gaps, or the split closes up.
    let dotRadius: CGFloat = size < 64 ? 262 : 214
    let gap: CGFloat = max(26, 1.6 / scale)
    let wall: CGFloat = 316

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    context.addPath(tile)
    context.setFillColor(color(0.08, 0.08, 0.09))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient(color(0.13, 0.135, 0.15), color(0.05, 0.05, 0.06)),
        start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: []
    )
    context.restoreGState()

    context.addPath(tile)
    context.setStrokeColor(color(1, 1, 1, 0.09))
    context.setLineWidth(3)
    context.strokePath()

    let side = wall - gap / 2
    let quadrants = [
        CGRect(x: center + gap / 2, y: center + gap / 2, width: side, height: side),
        CGRect(x: center - wall, y: center + gap / 2, width: side, height: side),
        CGRect(x: center + gap / 2, y: center - wall, width: side, height: side),
        CGRect(x: center - wall, y: center - wall, width: side, height: side),
    ]
    for quadrant in quadrants {
        context.saveGState()
        context.addPath(CGPath(roundedRect: quadrant, cornerWidth: 42, cornerHeight: 42, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient(color(0.27, 0.275, 0.30), color(0.17, 0.175, 0.19)),
            start: CGPoint(x: 0, y: quadrant.minY), end: CGPoint(x: 0, y: quadrant.maxY), options: []
        )
        context.addEllipse(in: CGRect(x: center - dotRadius, y: center - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        context.clip()
        context.drawLinearGradient(
            gradient(color(1.0, 0.27, 0.26), color(0.80, 0.06, 0.10)),
            start: CGPoint(x: 0, y: center - dotRadius), end: CGPoint(x: 0, y: center + dotRadius), options: []
        )
        context.restoreGState()
    }
    return context.makeImage()!
}

try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
for size in sizes {
    let url = URL(fileURLWithPath: "\(outputDirectory)/icon_\(size).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(size: size), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}
