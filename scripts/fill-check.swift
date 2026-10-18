// Checks that a screenshot shows the orange fill with white words on it.
// Usage: swift scripts/fill-check.swift <png> <left> <top> <right> <bottom> [--badge]
//        swift scripts/fill-check.swift --self-test
// The region is in fractions of the image, 0 to 1, left before right and
// top before bottom. Run by scripts/check-screenshots.sh after `make
// screenshots`. With --badge the region is the end of a row, where only a
// count of a digit or two sits, so a smaller patch of fill and fewer white
// pixels will do. --self-test draws its own cases and checks each.
//
// How much fill and how many white pixels are enough is a share of the
// region, never a count of pixels, so a shot taken at 1x passes just as the
// same shot at 2x or 3x does.
//
// Passes when the region holds a patch of Theme.tintFill in dark mode
// (0.74, 0.33, 0.08), or in light mode (0.66, 0.29, 0.07), which is inside
// the tolerance, and that patch has white words on it, not black or
// gray ones. A gray sidebar selection, or a Done drawn as orange words on
// glass, has no such patch and fails.
//
// White counts only inside a patch of fill: each row of each connected
// patch, from its first fill pixel to its last. So the white of a light
// sheet between Done and another orange control on the same row is never
// taken for words.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("fill-check: \(reason)\n".utf8))
    exit(1)
}

struct Pixels {
    let width: Int
    let height: Int
    var data: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
    }

    init?(image: CGImage) {
        self.init(width: image.width, height: image.height)
        let drawn: Bool = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn { return nil }
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// Paints x0..<x1, y0..<y1 in one color, for the self-test.
    mutating func paint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: (UInt8, UInt8, UInt8)) {
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                data[i] = color.0; data[i + 1] = color.1; data[i + 2] = color.2; data[i + 3] = 255
            }
        }
    }
}

/// Why `pixels` fails in the region `box` (left, top, right, bottom as
/// fractions), or a line saying what passed.
func check(_ pixels: Pixels, _ box: [Double], badge: Bool) -> Result<String, CheckFailure> {
    guard box.count == 4, box.allSatisfy({ (0...1).contains($0) }) else {
        return .failure(CheckFailure("the region \(box) must be four fractions from 0 to 1"))
    }
    guard box[0] < box[2], box[1] < box[3] else {
        return .failure(CheckFailure("the region \(box) must have left before right and top before bottom"))
    }
    let width = pixels.width, height = pixels.height
    let x0 = Int(box[0] * Double(width)), x1 = Int(box[2] * Double(width))
    let y0 = Int(box[1] * Double(height)), y1 = Int(box[3] * Double(height))
    guard x0 < x1, y0 < y1 else {
        return .failure(CheckFailure("the region \(box) is less than a pixel across in a \(width) by \(height) image"))
    }
    // Theme.tintFill in dark mode, with room for the glass's sheen.
    let fill = (189, 84, 20)
    let tolerance = 40
    let regionWidth = x1 - x0, regionHeight = y1 - y0
    var isFill = [Bool](repeating: false, count: regionWidth * regionHeight)
    var count = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let (r, g, b) = pixels.rgb(x, y)
            if abs(r - fill.0) <= tolerance, abs(g - fill.1) <= tolerance, abs(b - fill.2) <= tolerance {
                isFill[(y - y0) * regionWidth + (x - x0)] = true
                count += 1
            }
        }
    }
    // A share of the region, whatever the scale: a sidebar row or a Done
    // button covers 6 to 14 percent of its region, the end of a row with its
    // count about as much of its narrower one.
    let area = Double(regionWidth * regionHeight)
    guard Double(count) >= area * (badge ? 0.015 : 0.03) else {
        return .failure(CheckFailure("no orange fill in the region (\(count) pixels)"))
    }

    // Each connected patch of fill, and in each of its rows the span from
    // its first fill pixel to its last. The words are looked for only
    // there: on the fill itself, never in the corners around a rounded
    // shape, and never in the gap between two patches.
    var seen = [Bool](repeating: false, count: isFill.count)
    var onFill = [Bool](repeating: false, count: isFill.count)
    for start in isFill.indices where isFill[start] && !seen[start] {
        var spans: [Int: (Int, Int)] = [:]
        var stack = [start]
        seen[start] = true
        while let at = stack.popLast() {
            let x = at % regionWidth, y = at / regionWidth
            let span = spans[y] ?? (x, x)
            spans[y] = (min(span.0, x), max(span.1, x))
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < regionWidth && ny >= 0 && ny < regionHeight {
                let next = ny * regionWidth + nx
                if isFill[next] && !seen[next] {
                    seen[next] = true
                    stack.append(next)
                }
            }
        }
        for (y, span) in spans {
            for x in span.0...span.1 { onFill[y * regionWidth + x] = true }
        }
    }

    // The words on the fill: white, never black or gray.
    var white = 0, dark = 0
    for at in onFill.indices where onFill[at] {
        let (r, g, b) = pixels.rgb(x0 + at % regionWidth, y0 + at / regionWidth)
        if r >= 225, g >= 225, b >= 225 { white += 1 }
        if r <= 90, g <= 90, b <= 90 { dark += 1 }
    }
    // The words cover 0.2 to 0.6 percent of the region, a count about 0.05.
    guard Double(white) >= area * (badge ? 0.0002 : 0.001) else {
        return .failure(CheckFailure("the words on the fill aren't white (\(white) white pixels)"))
    }
    guard dark * 4 < white else {
        return .failure(CheckFailure("dark words on the fill (\(dark) dark, \(white) white pixels)"))
    }
    return .success("\(count) fill pixels, \(white) white on it")
}

struct CheckFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Draws the cases the check exists for and checks each comes out right.
func selfTest() -> Never {
    let orange: (UInt8, UInt8, UInt8) = (189, 84, 20)
    let white: (UInt8, UInt8, UInt8) = (255, 255, 255)
    let gray: (UInt8, UInt8, UInt8) = (110, 110, 110)
    var problems: [String] = []
    func expect(_ name: String, _ pixels: Pixels, _ box: [Double] = [0, 0, 1, 1], passes: Bool) {
        let result = check(pixels, box, badge: false)
        let passed = if case .success = result { true } else { false }
        if passed != passes {
            problems.append("\(name): \(passes ? "failed" : "passed"), expected the other")
        }
    }
    // Done: a patch of fill with white words inside it.
    var done = Pixels(width: 200, height: 100)
    done.paint(0, 0, 200, 100, (30, 30, 30))
    done.paint(40, 30, 160, 70, orange)
    for letter in 0..<4 { done.paint(60 + letter * 22, 42, 72 + letter * 22, 58, white) }
    expect("white words on the fill", done, passes: true)
    // The same with gray words.
    var grayWords = done
    for letter in 0..<4 { grayWords.paint(60 + letter * 22, 42, 72 + letter * 22, 58, gray) }
    expect("gray words on the fill", grayWords, passes: false)
    // A light sheet: two orange things on one row with only the white
    // sheet between them, and no words on either.
    var light = Pixels(width: 200, height: 100)
    light.paint(0, 0, 200, 100, white)
    light.paint(10, 30, 60, 70, orange)
    light.paint(140, 30, 190, 70, orange)
    expect("white background between two patches", light, passes: false)
    // Bad regions fail with a reason rather than a crash.
    expect("right before left", done, [0.8, 0, 0.2, 1], passes: false)
    expect("bottom before top", done, [0, 0.9, 1, 0.1], passes: false)
    expect("past the image", done, [0, 0, 1.5, 1], passes: false)
    expect("less than a pixel", done, [0.5, 0.5, 0.501, 0.501], passes: false)
    if !problems.isEmpty { fail("self-test: " + problems.joined(separator: "; ")) }
    print("fill-check: self-test passed")
    exit(0)
}

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--self-test" { selfTest() }
let badge = args.count == 7 && args[6] == "--badge"
guard args.count == 6 || badge else {
    fail("usage: fill-check.swift <png> <left> <top> <right> <bottom> [--badge]")
}
let box = args[2...5].compactMap(Double.init)
guard box.count == 4 else { fail("the region must be four numbers: \(args[2...5].joined(separator: " "))") }
let path = args[1]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let pixels = Pixels(image: image) else {
    fail("\(path): not an image")
}
switch check(pixels, box, badge: badge) {
case .success(let line): print("fill-check: \(path): \(line)")
case .failure(let failure): fail("\(path): \(failure.reason)")
}
