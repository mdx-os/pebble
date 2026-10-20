// into: Packages/PebbleKit/Sources/PebbleModel
// filename: Relay.swift
// expect: encryption or certificate pinning needs a fresh export review
// The reviewed file's name in another folder is not the reviewed file.
import CryptoKit

let fixtureKey = Curve25519.Signing.PrivateKey()
