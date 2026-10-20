// into: Packages/PebbleKit/Sources/PebbleCore
// expect: network code outside the opt-in cloud client
import Network

let fixtureConnection = NWConnection(host: "example.com", port: 443, using: .tls)
