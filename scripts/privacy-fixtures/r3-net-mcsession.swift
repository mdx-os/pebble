// into: Packages/PebbleKit/Sources/PebbleCore
// expect: network code outside the opt-in cloud client
import MultipeerConnectivity

func fixtureSession(_ peer: MCPeerID) -> MCSession { MCSession(peer: peer) }
