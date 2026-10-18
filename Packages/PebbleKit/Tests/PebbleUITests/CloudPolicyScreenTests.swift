#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// The cloud setting and the preview say the policy in `CloudPolicy`'s
/// words, and sign-in keeps nothing once the cloud is off or Forget
/// everything has run.
@MainActor
struct CloudPolicyScreenTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let token = MadeUpToken.make(header: #"{"alg":"RS256"}"#, payload: #"{"sub":"001234"}"#,
                                 signature: MadeUpToken.base64url("signature"))

    func memory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("policy-memory-\(UUID().uuidString).json")
        return MemoryStore(fileURL: url)
    }

    /// Signed in once, so the key is made, and given a second token that
    /// waits for the next preview, so forgetting has a token to let go of.
    func signedIn(_ keychain: InMemoryCloudKeychain) throws -> AppleCloudAuth {
        let auth = AppleCloudAuth(keychain: keychain)
        _ = try #require(auth.startAppleSignIn())
        try auth.accept(identityToken: Data(token.utf8))
        #expect(auth.signIn(for: endpoint) != nil)
        #expect(keychain.all[AppleCloudAuth.deviceKeyAccount] != nil, "the key is made on the device")
        _ = try #require(auth.startAppleSignIn())
        try auth.accept(identityToken: Data(token.utf8))
        #expect(auth.holdsTokenOrNonce)
        return auth
    }

    static let viewSource: String = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift"),
                            encoding: .utf8)) ?? ""
    }()

    /// The setting shows a card of the policy's lines, and the preview the
    /// policy's line under where it goes, both read from `CloudPolicy`.
    @Test func theSettingAndThePreviewShowThePolicy() {
        #expect(CloudHelpView.policyLines == CloudPolicy.current.lines)
        #expect(CloudPreviewSheet.policyLine == CloudPolicy.current.previewLine)
        let source = Self.viewSource
        #expect(source.contains("switchCard\n                    policyCard\n                    privateWordsCard\n"))
        #expect(source.contains("ForEach(Array(Self.policyLines.enumerated()), id: \\.offset)"))
        #expect(source.contains("Text(CloudWords.policyTitle)"))
        #expect(source.contains("Label(Self.policyLine, systemImage: \"building.2\")"))
    }

    /// Turning the cloud off removes the device key and lets go of any
    /// Apple token waiting for a preview.
    @Test func turningTheCloudOffRemovesTheDeviceKey() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = try signedIn(keychain)
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: memory(), auth: auth)
        #expect(help.usesCloudForNewChats)
        // With the cloud on, a new chat may leave the device.
        #expect(help.privacyPlace(local: LocalStubModel()) == .mayLeaveDevice)
        help.turnOff()
        #expect(keychain.all.isEmpty)
        #expect(!auth.holdsTokenOrNonce)
        #expect(auth.signIn(for: endpoint) == nil)
    }

    /// Forget everything removes them too, on or off.
    @Test func forgetEverythingRemovesTheDeviceKey() throws {
        for on in [true, false] {
            let keychain = InMemoryCloudKeychain()
            let auth = try signedIn(keychain)
            let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: on, for: endpoint)),
                                 endpoint: endpoint, memory: memory(), auth: auth)
            try help.forgetPrivateWords()
            #expect(keychain.all.isEmpty, "on: \(on)")
            #expect(!auth.holdsTokenOrNonce, "on: \(on)")
        }
        // And when the setting couldn't be opened at launch.
        let keychain = InMemoryCloudKeychain()
        let auth = try signedIn(keychain)
        try CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory(), auth: auth).forgetPrivateWords()
        #expect(keychain.all.isEmpty)
        #expect(!auth.holdsTokenOrNonce)
    }

    /// Over the Apple hop, whose values are covered, the preview says what
    /// goes under the dots: an Apple sign-in token, used once. On the card
    /// and aloud, and only for that hop.
    @Test func thePreviewSaysWhatTheAppleHopCarries() throws {
        let auth = try signedIn(InMemoryCloudKeychain())
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
        let apple = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                           signIn: auth.signIn(for: endpoint))
        #expect(CloudPreviewSheet.carriesAppleSignIn(apple))
        let spoken = CloudPreviewSheet.spokenLines(apple)
        let covered = try #require(spoken.firstIndex(of: CloudWords.previewSignInCovered))
        #expect(spoken[covered + 1] == CloudWords.previewSignInCarries)
        #expect(spoken.contains("Sent with the sign-in: appleToken, hidden. deviceKey, hidden. nonce, hidden."))
        #expect(CloudWords.previewSignInCarries == CloudPolicy.current.previewSignInLine)
        #expect(CloudWords.previewSignInCarries.contains("an Apple sign-in token, used once"))
        #expect(Self.viewSource.contains("Label(CloudWords.previewSignInCarries, systemImage: \"apple.logo\")"))
        // Another sign-in's hop isn't said to be Apple's, and no hop says nothing.
        let other = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                           signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)))
        #expect(!CloudPreviewSheet.carriesAppleSignIn(other))
        #expect(!CloudPreviewSheet.spokenLines(other).contains(CloudWords.previewSignInCarries))
        let none = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor())
        #expect(!CloudPreviewSheet.carriesAppleSignIn(none))
    }

    /// An empty address, even with the policy named, means the cloud can't
    /// be turned on.
    @Test func anEmptyAddressCantBeTurnedOn() {
        let read = CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: "",
                                                      CloudEndpoint.policyKey: CloudPolicy.currentVersion])
        #expect(read == nil)
        let help = CloudHelp(store: InMemoryCloudHelpStore(), endpoint: read, memory: memory())
        #expect(!help.isAvailable)
        #expect(!help.setOn(true))
        help.confirmTurnOn()
        #expect(!help.usesCloudForNewChats)
        #expect(help.privacyPlace(local: LocalStubModel()) == .onDevice)
    }
}
#endif
