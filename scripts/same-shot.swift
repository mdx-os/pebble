// Tells whether two screenshots show the same settled screen.
// Usage: swift scripts/same-shot.swift <a.png> <b.png>
// Exits 0 when they are the same size and differ in no more than one pixel
// in a thousand: a blinking text caret, never a launch half drawn. Used by
// scripts/screenshots.sh to wait for a screen to settle.
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, bytes)
}

let args = CommandLine.arguments
guard args.count == 3, let a = pixels(args[1]), let b = pixels(args[2]),
      a.width == b.width, a.height == b.height else { exit(1) }
var differing = 0
for i in stride(from: 0, to: a.bytes.count, by: 4)
where a.bytes[i] != b.bytes[i] || a.bytes[i + 1] != b.bytes[i + 1] || a.bytes[i + 2] != b.bytes[i + 2] {
    differing += 1
}
exit(differing * 1000 <= a.width * a.height ? 0 : 1)
