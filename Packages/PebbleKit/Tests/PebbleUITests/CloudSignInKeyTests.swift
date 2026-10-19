#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// A Keychain whose removal can be made to fail, as a locked or damaged
/// Keychain's might. Reading and writing always work.
final class StuckCloudKeychain: CloudKeychain, @unchecked Sendable {
    struct Stuck: Error {}
    let kept = InMemoryCloudKeychain()
    private let lock = NSLock()
    private var _removeFails = false

    var removeFails: Bool {
        get { lock.withLock { _removeFails } }
        set { lock.withLock { _removeFails = newValue } }
    }

    func read(_ account: String) throws -> String? { try kept.read(account) }
    func write(_ value: String, for account: String) throws { try kept.write(value, for: account) }
    func remove(_ account: String) throws {
        if removeFails { throw Stuck() }
        try kept.remove(account)
    }
}

/// What the setting and Forget everything say when the Keychain keeps the
/// sign-in key, that the key is never sent again, what the preview shows
/// of the session a sign-in brings back, and that with no sign-in a chat
/// sends nothing.
@MainActor
struct CloudSignInKeyTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!
    let token = MadeUpToken.make(header: #"{"alg":"RS256"}"#, payload: #"{"sub":"001234"}"#,
                                 signature: MadeUpToken.base64url("signature"))
    private let scratch = ScratchFiles()

    func memory() -> MemoryStore {
        MemoryStore(fileURL: scratch.add(FileManager.default.temporaryDirectory
            .appendingPathComponent("key-test-\(UUID().uuidString).json")))
    }

    func signInToApple(_ auth: AppleCloudAuth) throws {
        _ = try #require(auth.startAppleSignIn())
        try auth.accept(identityToken: Data(token.utf8))
    }

    /// Signed in once, so the key is made and kept.
    func withKey(_ keychain: StuckCloudKeychain) throws -> AppleCloudAuth {
        let auth = AppleCloudAuth(keychain: keychain)
        try signInToApple(auth)
        #expect(try auth.signIn(for: endpoint) != nil)
        #expect(keychain.kept.all[AppleCloudAuth.deviceKeyAccount] != nil)
        return auth
    }

    /// Turning off says the key may still be on this device when the
    /// Keychain kept it, and the next sign-in doesn't send it. Turning on
    /// tries the removal again, and says so while it still fails.
    @Test func turningOffSaysTheKeyMayStillBeHere() throws {
        let keychain = StuckCloudKeychain()
        let auth = try withKey(keychain)
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: memory(), auth: auth)
        keychain.removeFails = true
        help.turnOff()
        #expect(help.status == CloudWords.signInKeyMayStay)
        #expect(help.status?.contains("may still be on this device") == true)
        #expect(help.signInKeyMayStay)
        #expect(!auth.holdsTokenOrNonce)
        try signInToApple(auth)
        #expect(throws: CloudModelError.oldKeyStayed) { try auth.signIn(for: endpoint) }
        // Turning on tries again: still kept, and said.
        help.confirmTurnOn()
        #expect(help.usesCloudForNewChats)
        #expect(help.status == CloudWords.signInKeyMayStay)
        // Once the Keychain lets go, turning on erases it and says nothing.
        help.turnOff()
        keychain.removeFails = false
        help.confirmTurnOn()
        #expect(help.status == nil)
        #expect(!help.signInKeyMayStay)
        #expect(keychain.kept.all.isEmpty)
        // A switch off that couldn't be saved says both.
        let failing = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        let stuck = try withKey(keychain)
        let other = CloudHelp(store: failing, endpoint: endpoint, memory: memory(), auth: stuck)
        failing.savesToFail = .max
        keychain.removeFails = true
        other.turnOff()
        let line = try #require(other.status)
        #expect(line.hasSuffix(" " + CloudWords.signInKeyMayStay), "\(line)")
        #expect(line != CloudWords.signInKeyMayStay)
    }

    /// Forget everything's line says the key may still be on this device
    /// when the Keychain kept it, and the next sign-in doesn't send it.
    @Test func forgetEverythingSaysTheKeyMayStillBeHere() throws {
        let keychain = StuckCloudKeychain()
        let auth = try withKey(keychain)
        let notes = memory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: notes, auth: auth)
        keychain.removeFails = true
        let model = HomeView.memoryModel(store: notes, place: .onDevice, cloud: help)
        model.forgetEverything()
        let line = try #require(model.status)
        #expect(line == MemoryWords.forgotten + " " + CloudWords.signInKeyMayStay, "\(line)")
        try signInToApple(auth)
        #expect(throws: CloudModelError.oldKeyStayed) { try auth.signIn(for: endpoint) }
        // With the key gone, the line is the usual one.
        keychain.removeFails = false
        let again = HomeView.memoryModel(store: notes, place: .onDevice, cloud: help)
        again.forgetEverything()
        #expect(again.status == MemoryWords.forgotten)
        #expect(keychain.kept.all.isEmpty)
    }

    /// At launch with the cloud off, a key a forget left behind is erased.
    /// With the cloud on it is the key in use, and is kept.
    @Test func launchWithTheCloudOffErasesALeftoverKey() throws {
        let keychain = StuckCloudKeychain()
        _ = try withKey(keychain)
        _ = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                      endpoint: endpoint, memory: memory(), auth: AppleCloudAuth(keychain: keychain))
        #expect(keychain.kept.all[AppleCloudAuth.deviceKeyAccount] != nil, "on, so the key is in use")
        _ = CloudHelp(store: InMemoryCloudHelpStore(), endpoint: endpoint, memory: memory(),
                      auth: AppleCloudAuth(keychain: keychain))
        #expect(keychain.kept.all.isEmpty, "off, so the leftover went")
        // Kept by the Keychain at launch: owed, so no sign-in sends it.
        let stuck = try withKey(keychain)
        keychain.removeFails = true
        let help = CloudHelp(store: InMemoryCloudHelpStore(), endpoint: endpoint, memory: memory(), auth: stuck)
        #expect(help.signInKeyMayStay)
        try signInToApple(stuck)
        #expect(throws: CloudModelError.oldKeyStayed) { try stuck.signIn(for: endpoint) }
    }

    /// The preview over a sign-in hop shows the session line on the
    /// message, covered like every sign-in value, and says so on the card
    /// and aloud.
    @Test func thePreviewShowsTheSessionLineCovered() throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        try signInToApple(auth)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             signIn: auth.signIn(for: endpoint))
        #expect(preview.sessionHeader == AppleCloudAuth.sessionHeader)
        let card = CloudPreviewSheet.displayedText(preview)
        let message = try #require(card.components(separatedBy: CloudWords.previewThenMessage).last)
        #expect(message.contains("\n\(AppleCloudAuth.sessionHeader): \(CloudPreviewSheet.signInMask)\n"))
        let spoken = CloudPreviewSheet.spokenLines(preview)
        let then = try #require(spoken.firstIndex(of: CloudWords.previewThenMessage))
        #expect(spoken[then + 1] == CloudWords.previewSessionFromSignIn)
        #expect(spoken.joined(separator: "\n").contains(CloudWords.spokenSignIn(AppleCloudAuth.sessionHeader)))
        #expect(CloudPolicyScreenTests.viewSource.contains(
            "Label(CloudWords.previewSessionFromSignIn, systemImage: \"key.horizontal\")"))
        // No hop, no session line.
        let plain = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor())
        #expect(plain.sessionHeader == nil)
        #expect(!CloudPreviewSheet.spokenLines(plain).contains(CloudWords.previewSessionFromSignIn))
    }

    /// With the policy this build ships with, which needs sign-in, and no
    /// way to sign in yet, a cloud chat sends nothing and says why.
    @Test func withNoSignInAChatSendsNothingAndSaysWhy() async throws {
        let maker = TransportMaker()
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: memory(), auth: AppleCloudAuth(keychain: InMemoryCloudKeychain()),
                             transport: { maker.make() })
        let review = CloudReview()
        let model = help.chatModel(local: LocalStubModel(), review: review)
        #expect((model as? CloudModel)?.policy == .current)
        let chat = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                       conversation: nil, review: review, replyBeat: .zero)
        chat.submit("Plan my week")
        // Bounded, so a preview shown and left waiting fails plainly.
        #expect(await finishes { await chat.settled() }, "the reply waited on a preview")
        review.cancelPending()
        #expect(chat.failure == CloudWords.needsSignIn)
        #expect(chat.draft == "Plan my week")
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
        #expect(!help.anythingSentThisSession)
    }
}
#endif
