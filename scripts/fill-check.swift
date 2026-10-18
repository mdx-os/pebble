// Checks that a screenshot shows the orange fill with white words on it.
// Usage: swift scripts/fill-check.swift <png> <left> <top> <right> <bottom>
// The region is in fractions of the image, 0 to 1. Run by
// scripts/check-screenshots.sh after `make screenshots`.
//
// Passes when the region holds a patch of Theme.tintFill in dark mode
// (0.74, 0.33, 0.08), and that patch has white words on it, not black or
// gray ones. A gray sidebar selection, or a Done drawn as orange words on
// glass, has no such patch and fails.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("fill-check: \(reason)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 6, let box = Optional(args[2...5].compactMap(Double.init)), box.count == 4 else {
    fail("usage: fill-check.swift <png> <left> <top> <right> <bottom>")
}
let path = args[1]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("\(path): not an image")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}

// Theme.tintFill in dark mode, with room for the glass's sheen.
let fill = (189, 84, 20)
let tolerance = 40
let x0 = Int(box[0] * Double(width)), x1 = Int(box[2] * Double(width))
let y0 = Int(box[1] * Double(height)), y1 = Int(box[3] * Double(height))
var count = 0
// Each row's first and last fill pixel, so the words are looked for on
// the fill itself, never in the dark corners around a rounded shape.
var spans: [Int: (Int, Int)] = [:]
for y in y0..<y1 {
    for x in x0..<x1 {
        let (r, g, b) = rgb(x, y)
        if abs(r - fill.0) <= tolerance, abs(g - fill.1) <= tolerance, abs(b - fill.2) <= tolerance {
            count += 1
            let span = spans[y] ?? (x, x)
            spans[y] = (min(span.0, x), max(span.1, x))
        }
    }
}
// About a row of a sidebar or a Done button at 2x or 3x.
guard count >= 4_000 else { fail("\(path): no orange fill in the region (\(count) pixels)") }

// The words on the fill: white, never black or gray.
var white = 0, dark = 0
for (y, span) in spans {
    for x in span.0...span.1 {
        let (r, g, b) = rgb(x, y)
        if r >= 225, g >= 225, b >= 225 { white += 1 }
        if r <= 90, g <= 90, b <= 90 { dark += 1 }
    }
}
guard white >= 150 else { fail("\(path): the words on the fill aren't white (\(white) white pixels)") }
guard dark * 4 < white else { fail("\(path): dark words on the fill (\(dark) dark, \(white) white pixels)") }
print("fill-check: \(path): \(count) fill pixels, \(white) white on it")
