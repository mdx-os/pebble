// Draws the app icon: the agent's stone, in its starting Sunrise colors,
// on the warm backdrop. The shapes follow PebbleUI/CharacterView.swift.
// Usage: swift scripts/app-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
// Writes every PNG the asset catalog's Contents.json names. Run it again
// after changing the look, then `make archive` checks the sizes.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGB { let r, g, b: CGFloat }

// Theme.backdropEnds(.light) and Theme.colors(for: .sunrise).
let backdropTop = RGB(r: 1.00, g: 0.97, b: 0.94)
let backdropBottom = RGB(r: 0.99, g: 0.99, b: 0.98)
let stoneTop = RGB(r: 1.00, g: 0.71, b: 0.42)
let stoneBottom = RGB(r: 0.95, g: 0.42, b: 0.36)

func color(_ c: RGB, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
}

func gradient(_ a: RGB, _ b: RGB) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

/// The stone and its face, centered in `rect`. CoreGraphics puts y up.
func drawStone(in ctx: CGContext, rect: CGRect) {
    let size = rect.width * 0.56
    let stone = CGRect(x: rect.midX - size / 2, y: rect.midY - size * 0.47,
                       width: size, height: size * 0.94)
    let shape = CGPath(roundedRect: stone, cornerWidth: size * 0.46, cornerHeight: size * 0.46 * 0.94, transform: nil)

    // The soft glow and the shadow underneath.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.08), blur: size * 0.24, color: color(stoneBottom, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(stoneBottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient(stoneTop, stoneBottom),
                           start: CGPoint(x: stone.minX, y: stone.maxY),
                           end: CGPoint(x: stone.maxX, y: stone.minY), options: [])
    // The highlight on the upper left.
    ctx.translateBy(x: stone.minX + size * 0.33, y: stone.maxY - size * 0.21)
    ctx.rotate(by: 24 * .pi / 180)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
    ctx.fillEllipse(in: CGRect(x: -size * 0.17, y: -size * 0.09, width: size * 0.34, height: size * 0.18))
    ctx.restoreGState()

    // Two eyes and a smile, a little below the middle.
    let faceY = stone.midY - size * 0.04
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    let eyeW = size * 0.085, eyeH = size * 0.12, gap = size * 0.22
    for dx in [-(gap + eyeW) / 2, (gap + eyeW) / 2] {
        let eye = CGRect(x: stone.midX + dx - eyeW / 2, y: faceY + size * 0.04, width: eyeW, height: eyeH)
        ctx.addPath(CGPath(roundedRect: eye, cornerWidth: eyeW / 2, cornerHeight: eyeW / 2, transform: nil))
        ctx.fillPath()
    }
    let smileW = size * 0.26, smileH = size * 0.1
    let smileTop = faceY - size * 0.04
    ctx.move(to: CGPoint(x: stone.midX - smileW / 2, y: smileTop))
    ctx.addQuadCurve(to: CGPoint(x: stone.midX + smileW / 2, y: smileTop),
                     control: CGPoint(x: stone.midX, y: smileTop - smileH * 0.45 * 2))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(size * 0.045)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

func drawBackdrop(in ctx: CGContext, rect: CGRect) {
    ctx.drawLinearGradient(gradient(backdropTop, backdropBottom),
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// iOS: one opaque square. The system rounds the corners.
func iosIcon(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    drawBackdrop(in: ctx, rect: rect)
    drawStone(in: ctx, rect: rect)
    return ctx.makeImage()!
}

/// macOS: the rounded square on Apple's grid (824 of 1024, centered), with
/// a soft shadow and clear corners.
func macIcon(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(px) / 1024
    let tile = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(color(backdropTop))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawBackdrop(in: ctx, rect: tile)
    drawStone(in: ctx, rect: tile)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift scripts/app-icon.swift <AppIcon.appiconset>\n", stderr)
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as! [String: Any]
for entry in contents["images"] as! [[String: String]] {
    guard let file = entry["filename"], let size = entry["size"] else { continue }
    let points = Double(size.split(separator: "x")[0])!
    let scale = Double(entry["scale"]?.dropLast() ?? "1")!
    let px = Int(points * scale)
    let image = entry["idiom"] == "mac" ? macIcon(px) : iosIcon(px)
    write(image, to: folder.appendingPathComponent(file))
    print("app-icon: \(file) \(px)x\(px)")
}
