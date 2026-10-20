// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import AppKit

func fixtureDraw(_ remote: URL, in rect: NSRect) {
    let image: NSImage = .init(byReferencing: remote)
    image.draw(in: rect)
}
