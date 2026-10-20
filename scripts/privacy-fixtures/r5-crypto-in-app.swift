// into: App/Sources
// expect: encryption or certificate pinning needs a fresh export review
// CryptoKit in the app, outside the one reviewed file.
import CryptoKit

let fixtureDigest = SHA256.hash(data: Data())
