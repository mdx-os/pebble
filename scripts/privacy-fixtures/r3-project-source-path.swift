// into: Extra
// project: s~(      - App/Sources\n)~$1      - path: Extra\n~
// expect: network code outside the opt-in cloud client
// The same folder, written as a path: entry.
import Foundation

let fixtureExtra = URLSession.shared
