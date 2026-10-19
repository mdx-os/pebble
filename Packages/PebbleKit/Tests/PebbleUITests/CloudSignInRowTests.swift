import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// The sign-in row asks whichever source the build offers, and the
/// preview shows a token ask above the sign-in, covered.
@MainActor
struct CloudSignInRowTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    private let scratch = ScratchFiles()

    func memory() -> MemoryStore {
        MemoryStore(fileURL: scratch.add(FileManager.default.temporaryDirectory
            .appendingPathComponent("row-test-\(UUID().uuidString).json")))
    }

    func help(_ auth: any CloudAuth, endpoint: URL?, on: Bool = false) -> CloudHelp {
        let settings = on ? CloudHelpSettings(isOn: true, for: self.endpoint) : .off
        return CloudHelp(store: InMemoryCloudHelpStore(settings), endpoint: endpoint, memory: memory(), auth: auth)
    }

    /// The row calls the offered source, and says what came of it. With
    /// no source, or no address, there is no row and nothing is asked.
    @Test func theSignInRowAsksTheOfferedSource() async {
        let source = FakeIdentityTokenSource()
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: source)
        let cloud = help(auth, endpoint: endpoint)
        #expect(cloud.signInKind == .apple)
        #expect(CloudSignInRow.title(.apple) == CloudWords.signInWithApple)
        await cloud.signIn()
        #expect(source.asked.count == 1)
        #expect(cloud.signInLine == CloudWords.signInReady)
        #expect(auth.holdsTokenOrNonce, "the token waits for the first preview")

        let unseen = FakeIdentityTokenSource()
        let noAddress = help(AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: unseen), endpoint: nil)
        #expect(noAddress.signInKind == nil)
        await noAddress.signIn()
        #expect(unseen.asked.isEmpty)
        let noSource = help(AppleCloudAuth(keychain: InMemoryCloudKeychain()), endpoint: endpoint)
        #expect(noSource.signInKind == nil)
        await noSource.signIn()
        #expect(noSource.signInLine == nil)
    }

    /// The staging test sign-in's row says it is for this build only, and
    /// after asking, that nothing has gone yet.
    @Test func theTestSignInSaysItIsForThisBuildOnly() async {
        let source = FakeIdentityTokenSource(kind: .staging, answer: .ask)
        let cloud = help(AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: source), endpoint: endpoint)
        #expect(cloud.signInKind == .staging)
        #expect(CloudSignInRow.title(.staging) == CloudWords.testSignIn)
        #expect(CloudWords.testSignIn.contains("for this build only"))
        await cloud.signIn()
        #expect(cloud.signInLine == CloudWords.testSignInReady)
        #expect(CloudWords.testSignInReady.contains("Nothing has gone yet"))
    }

    /// A refusal is said under the row, in the source's own words.
    @Test func theRowSaysWhyItCouldNotSignIn() async {
        let source = FakeIdentityTokenSource(answer: .refuse(CloudWords.appleSignInNotSetUp))
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: source)
        let cloud = help(auth, endpoint: endpoint)
        await cloud.signIn()
        #expect(cloud.signInLine == CloudWords.appleSignInNotSetUp)
        #expect(!auth.holdsTokenOrNonce)
    }

    /// Answering the turn on question no lets go of a sign-in started
    /// from it, and so do turning off and Forget everything.
    @Test func aSignInIsLetGoWhenTheCloudStaysOff() async throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: FakeIdentityTokenSource())
        let cloud = help(auth, endpoint: endpoint)
        await cloud.signIn()
        #expect(auth.holdsTokenOrNonce)
        cloud.turnOnDeclined()
        #expect(!auth.holdsTokenOrNonce)
        #expect(cloud.signInLine == nil)

        let asking = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: FakeIdentityTokenSource(kind: .staging, answer: .ask))
        let on = help(asking, endpoint: endpoint, on: true)
        await on.signIn()
        #expect(asking.holdsTokenOrNonce)
        on.turnOff()
        #expect(!asking.holdsTokenOrNonce)
        #expect(on.signInLine == nil)
        on.confirmTurnOn()
        await on.signIn()
        try on.forgetPrivateWords()
        #expect(!asking.holdsTokenOrNonce)
        #expect(on.signInLine == nil)
    }

    /// The preview shows the token ask first, under its own heading, then
    /// the sign-in, then the message. The ask's values, the pass among
    /// them, are covered on the card and never read aloud, and so is the
    /// sign-in's length, which the token sets. The sheet says why.
    @Test func thePreviewShowsTheTestSignInAboveTheHopWithThePassCovered() async throws {
        let source = FakeIdentityTokenSource(kind: .staging, answer: .ask)
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: source)
        #expect(await auth.askForIdentityToken() == .asksWithFirstMessage)
        var turns = Conversation.firstRun(named: "Pip", onDevice: false).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Help me plan a quiet Saturday."))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             signIn: auth.signIn(for: endpoint))
        let ask = try #require(preview.ask)
        let shown = CloudPreviewSheet.displayedText(preview)
        let askAt = try #require(shown.range(of: CloudWords.previewAskFirst))
        let hopAt = try #require(shown.range(of: CloudWords.previewThenSignIn))
        let messageAt = try #require(shown.range(of: CloudWords.previewThenMessage))
        #expect(askAt.upperBound <= hopAt.lowerBound)
        #expect(hopAt.upperBound <= messageAt.lowerBound)
        #expect(!shown.contains(CloudWords.previewSignInFirst))
        #expect(shown.contains(ask.url.absoluteString))
        #expect(shown.contains("\"pass\" : " + CloudPreviewSheet.signInMask))
        #expect(shown.contains("\"nonceSha256\" : " + CloudPreviewSheet.signInMask))
        let fields = try #require(CloudSignIn(path: "", body: ask.body).fields)
        for value in fields.values {
            #expect(!shown.contains(value))
        }
        let hopText = shown[hopAt.upperBound..<messageAt.lowerBound]
        #expect(hopText.contains("Content-Length: " + CloudPreviewSheet.signInMask))
        #expect(!shown[messageAt.upperBound...].contains("Content-Length: " + CloudPreviewSheet.signInMask))

        let spoken = CloudPreviewSheet.spokenLines(preview)
        #expect(spoken.contains(CloudWords.previewAskFirst))
        #expect(spoken.contains(CloudWords.previewTokenFromAsk))
        #expect(spoken.filter { $0.contains(CloudWords.spokenSignIn("Content-Length")) }.count == 1, "the hop's length only")
        #expect(spoken.firstIndex(of: CloudWords.previewAskFirst)! < spoken.firstIndex(of: CloudWords.previewThenSignIn)!)
        for value in fields.values {
            #expect(!spoken.joined(separator: " ").contains(value))
        }
        #expect(CloudPreviewSheet.coversLength(preview))
        #expect(CloudPreviewSheet.coversAnything(preview))
    }

    /// Without an ask, the preview reads as it did: no ask heading, and
    /// the sign-in's length shows.
    @Test func withoutAnAskThePreviewIsUnchanged() async throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: FakeIdentityTokenSource())
        #expect(await auth.askForIdentityToken() == .ready)
        var turns = Conversation.firstRun(named: "Pip", onDevice: false).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Help me plan a quiet Saturday."))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             signIn: auth.signIn(for: endpoint))
        let shown = CloudPreviewSheet.displayedText(preview)
        #expect(shown.hasPrefix(CloudWords.previewSignInFirst))
        #expect(!shown.contains(CloudWords.previewAskFirst))
        #expect(!shown.contains("Content-Length: " + CloudPreviewSheet.signInMask))
        #expect(!CloudPreviewSheet.spokenLines(preview).contains(CloudWords.previewTokenFromAsk))
    }

    /// The two new chat failures each have their own line, and count as
    /// nothing of the chat sent. Only the missing token points at the
    /// draft; signing in first is about the build, not the words.
    @Test func theNewFailuresHaveTheirLines() {
        #expect(ChatController.failureLine(for: CloudModelError.signInFirst) == CloudWords.signInFirst)
        #expect(ChatController.failureLine(for: CloudModelError.noToken) == CloudWords.noToken)
        #expect(ChatController.failureLine(for: CloudModelError.needsSignIn) == CloudWords.needsSignIn)
        #expect(ChatController.nothingWasSent(CloudModelError.signInFirst))
        #expect(ChatController.nothingWasSent(CloudModelError.noToken))
        #expect(ChatController.pointsAtTheDraft(CloudWords.noToken))
        #expect(!ChatController.pointsAtTheDraft(CloudWords.signInFirst))
    }
}
