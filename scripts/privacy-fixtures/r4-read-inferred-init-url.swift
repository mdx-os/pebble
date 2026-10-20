// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import AVFoundation

func fixturePlay(_ remote: URL) {
    let player: AVPlayer = .init(url: remote)
    player.play()
}
