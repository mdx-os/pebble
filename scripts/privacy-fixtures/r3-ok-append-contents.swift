// into: Packages/PebbleKit/Sources/PebbleCore
// expect: ok
// contentsOf: on a method, not an initializer, reads nothing.
import Foundation

func fixtureJoined(_ more: [Int], _ lines: inout [String], _ announcer: FixtureAnnouncer) -> [Int] {
    var all = [1]
    all.append(contentsOf: more)
    lines.append(contentsOf: announcer.lines(for: more))
    try? FileManager.default.copyItem(atPath: "a", toPath: "b")
    return all
}

struct FixtureAnnouncer { func lines(for items: [Int]) -> [String] { items.map { "\($0)" } } }
