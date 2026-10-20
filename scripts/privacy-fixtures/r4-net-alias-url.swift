// into: Packages/PebbleKit/Sources/PebbleCore
// expect: network code outside the opt-in cloud client
import AVFoundation

typealias FixturePlayer = AVPlayer
func fixturePlay(_ remote: URL) {
    let player = FixturePlayer(url: remote)
    player.play()
}
