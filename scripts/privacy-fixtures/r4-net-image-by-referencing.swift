// into: Packages/PebbleKit/Sources/PebbleCore
// expect: network code outside the opt-in cloud client
import AppKit

func fixtureDraw(_ remote: URL, in rect: NSRect) {
    let image = NSImage(byReferencing: remote)
    image.draw(in: rect)
}
