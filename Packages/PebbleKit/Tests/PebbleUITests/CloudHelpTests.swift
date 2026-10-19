#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// Stands in for URLSession behind the real transport: records every
/// URLRequest and answers with a fixed reply. Never touches the network.
final class FakeWire: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [URLRequest] = []
    private var _cancelled = false
    /// Holds every request on the wire until it is cancelled, as a slow
    /// network would. The wait is a sleep that cancellation cuts short.
    let hangs: Bool

    init(hangs: Bool = false) { self.hangs = hangs }

    var sent: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    /// True once a request held on the wire was cancelled.
    var cancelled: Bool { lock.withLock { _cancelled } }

    private var sentWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once a request has reached the wire, with no timing involved.
    func started() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if !_sent.isEmpty { return true }
                sentWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Returns once a request held on the wire was cancelled.
    func whenCancelled() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if _cancelled { return true }
                cancelWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    @Sendable func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let started = lock.withLock {
            _sent.append(request)
            defer { sentWaiters = [] }
            return sentWaiters
        }
        for waiter in started { waiter.resume() }
        if hangs {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                let waiting = lock.withLock {
                    _cancelled = true
                    defer { cancelWaiters = [] }
                    return cancelWaiters
                }
                for waiter in waiting { waiter.resume() }
                throw URLError(.cancelled)
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (try JSONEncoder().encode(["reply": "Here's a short note."]), response)
    }

    /// Every body that went out, read as text.
    var sentText: [String] { sent.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
}

/// True when `work` finishes within `limit`. A passing test never waits on
/// the limit; it only turns a wait that would never end, as when the code
/// under test is broken, into a plain failure.
func finishes(within limit: Duration = .seconds(20), _ work: @escaping @Sendable () async -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let first = FirstAnswer(continuation)
        let worker = Task {
            await work()
            first.give(true)
        }
        // Stopped once the work is done, so no sleeper outlives the test.
        // When the limit fires first, the work is cancelled, so whatever
        // it waits on can let go of it.
        let limiter = Task {
            do {
                try await Task.sleep(for: limit)
                first.give(false)
                worker.cancel()
            } catch {}
        }
        Task {
            await worker.value
            limiter.cancel()
        }
    }
}

/// Resumes a continuation with the first answer given, and ignores the rest.
final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func give(_ answer: Bool) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: answer)
    }
}

/// Counts how often a transport is made, which only happens with the cloud on.
final class TransportMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    let wire: FakeWire

    init(hangs: Bool = false) { wire = FakeWire(hangs: hangs) }

    var made: Int {
        lock.lock(); defer { lock.unlock() }
        return _made
    }

    func make() -> any CloudTransport {
        lock.lock(); _made += 1; lock.unlock()
        return URLSessionCloudTransport(load: wire.load)
    }
}

/// A made-up sign-in header, and, when asked, a made-up sign-in hop.
/// Counts the sign-in answers it receives, and each forget.
final class CountingAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var _signIns = 0
    private let needsSignIn: Bool

    init(needsSignIn: Bool = false) { self.needsSignIn = needsSignIn }

    var signIns: Int {
        lock.lock(); defer { lock.unlock() }
        return _signIns
    }

    func headers(for url: URL) -> [String: String] { ["X-Sample-Sign-In": "made-up"] }

    func signIn(for endpoint: URL) -> CloudSignIn? {
        needsSignIn ? CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)) : nil
    }

    func signedIn(_ answer: Data) {
        lock.withLock { _signIns += 1 }
    }

    private var _forgets = 0
    /// How many times it was asked to let go of what it kept.
    var forgets: Int { lock.withLock { _forgets } }

    /// Its header stands for a session it already holds.
    func isSignedIn(to endpoint: URL) -> Bool { true }

    func forget() -> Bool {
        lock.withLock { _forgets += 1 }
        return true
    }
}

/// Scratch files a test made, removed when the test is done with them,
/// along with the copies the stores write beside one under its name: the
/// staged next copy and the off mark, which may hold the same words or say
/// something of them.
final class ScratchFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) -> URL {
        lock.withLock { urls.append(url) }
        return url
    }

    /// `url` and every copy a store writes beside it.
    static func withSiblings(_ url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        return [url] + [".next", ".off"].map { folder.appendingPathComponent("." + url.lastPathComponent + $0) }
    }

    deinit {
        for url in urls.flatMap(Self.withSiblings) { try? FileManager.default.removeItem(at: url) }
    }
}

/// Sign-in that says, each time it is told to forget, what `onForget`
/// finds then. With `needsSignIn` it asks for a made-up hop, and counts
/// the sign-in answers it receives.
final class WitnessAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [Bool] = []
    private var _onForget: (@Sendable () -> Bool)?
    private var _signIns = 0
    private let needsSignIn: Bool

    init(needsSignIn: Bool = false) { self.needsSignIn = needsSignIn }

    var onForget: (@Sendable () -> Bool)? {
        get { lock.withLock { _onForget } }
        set { lock.withLock { _onForget = newValue } }
    }

    /// What `onForget` found at each forget.
    var forgotAfterEveryEnd: [Bool] { lock.withLock { _seen } }

    var signIns: Int { lock.withLock { _signIns } }

    func headers(for url: URL) -> [String: String] { [:] }

    func signIn(for endpoint: URL) -> CloudSignIn? {
        needsSignIn ? CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)) : nil
    }

    func signedIn(_ answer: Data) {
        lock.withLock { _signIns += 1 }
    }

    /// Without `needsSignIn` it stands for a device already signed in.
    func isSignedIn(to endpoint: URL) -> Bool { !needsSignIn || signIns > 0 }

    func forget() -> Bool {
        let found = onForget?() ?? false
        lock.withLock { _seen.append(found) }
        return true
    }
}

/// Holds every send on the wire until the test lets it answer, whatever
/// is cancelled meanwhile, as a slow server's answer that lands after a
/// switch off would. Never touches the network.
final class GatedTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sends = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    var sends: Int { lock.withLock { _sends } }

    /// Returns once a send is held.
    func started() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if _sends > 0 { return true }
                startWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Lets every held send answer, and every later one go straight on.
    func answer() {
        let waiting = lock.withLock {
            open = true
            defer { held = [] }
            return held
        }
        for send in waiting { send.resume() }
    }

    func send(_ request: CloudRequest) async throws -> Data {
        await withCheckedContinuation { continuation in
            let (go, starters) = lock.withLock {
                _sends += 1
                if !open { held.append(continuation) }
                defer { startWaiters = [] }
                return (open, startWaiters)
            }
            for starter in starters { starter.resume() }
            if go { continuation.resume() }
        }
        return Data(#"{"token":"made-up","reply":"Here's a short note."}"#.utf8)
    }
}

/// Answers the sign-in hop first. Then the message fails on the wire, or
/// `afterHop` runs, as a switch off just after the hop would, and the
/// message never comes.
final class HopAnswersFirst: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private let messageFails: Bool
    private let afterHop: @Sendable () -> Void

    init(messageFails: Bool, afterHop: @escaping @Sendable () -> Void) {
        self.messageFails = messageFails
        self.afterHop = afterHop
    }

    var paths: [String] { lock.withLock { _paths } }

    func send(_ request: CloudRequest) async throws -> Data {
        let first = lock.withLock {
            _paths.append(request.url.path)
            return _paths.count == 1
        }
        if first {
            if !messageFails { afterHop() }
            return Data(#"{"token":"made-up"}"#.utf8)
        }
        throw URLError(.networkConnectionLost)
    }
}

/// Says whether a `FailingCloudStore` can't be read because it is locked
/// away, or because it is damaged.
enum LoadFailure {
    case locked, damaged
}

/// Refuses every request before sending, as the real transport does when
/// the labels aren't the ones shown.
struct RefusingTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data {
        throw CloudTransportError.headersNotShown
    }
}

/// A settings store whose saves and erases can be made to fail, as a full
/// disk or a failed rename would.
final class FailingCloudStore: CloudHelpStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: CloudHelpSettings?
    private var _savesToFail = 0
    private var _eraseFails = false

    init(_ settings: CloudHelpSettings) { self.settings = settings }

    /// How many of the next saves fail. `Int.max` for all of them.
    var savesToFail: Int {
        get { lock.withLock { _savesToFail } }
        set { lock.withLock { _savesToFail = newValue } }
    }

    var eraseFails: Bool {
        get { lock.withLock { _eraseFails } }
        set { lock.withLock { _eraseFails = newValue } }
    }

    private var _loadFails: LoadFailure?
    /// Makes `load` throw, as a locked device or a damaged file does.
    var loadFails: LoadFailure? {
        get { lock.withLock { _loadFails } }
        set { lock.withLock { _loadFails = newValue } }
    }

    private var _markFails = false
    /// Makes `markOff` fail too, as a disk with no room for anything would.
    var markFails: Bool {
        get { lock.withLock { _markFails } }
        set { lock.withLock { _markFails = newValue } }
    }

    private var _markedOff = false
    /// True while the off mark stands, as the file store's would.
    var markedOff: Bool { lock.withLock { _markedOff } }

    /// What is on disk: nil when there is no file.
    var saved: CloudHelpSettings? { lock.withLock { settings } }

    func load() throws -> CloudHelpSettings {
        try lock.withLock {
            switch _loadFails {
            case .locked?: throw MemoryStore.Unavailable()
            case .damaged?: throw MemoryStore.Unreadable()
            case nil:
                var read = settings ?? .off
                if _markedOff { read.turnOff() }
                return read
            }
        }
    }

    func save(_ next: CloudHelpSettings) throws {
        try lock.withLock {
            if _savesToFail > 0 {
                if _savesToFail != .max { _savesToFail -= 1 }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            settings = next
            _markedOff = false
        }
    }

    /// Clears `loadFails` too, as the file store's erase does in effect:
    /// once the file is gone there is nothing locked or damaged to read,
    /// and the real store reads a missing file as off.
    func erase() throws {
        try lock.withLock {
            if _eraseFails { throw CocoaError(.fileWriteNoPermission) }
            settings = nil
            _loadFails = nil
            _markedOff = false
        }
    }

    /// Works even while `load` is locked, as the file store's mark does.
    func markOff() throws {
        try lock.withLock {
            if _markFails { throw CocoaError(.fileWriteOutOfSpace) }
            _markedOff = true
        }
    }
}

@MainActor
struct CloudHelpTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!
    private let scratch = ScratchFiles()

    func help(_ settings: CloudHelpSettings = .off, endpoint: URL?, maker: TransportMaker,
              memory: MemoryStore? = nil, store: InMemoryCloudHelpStore? = nil,
              auth: any CloudAuth = NoCloudAuth(), policy: CloudPolicy = .noSignInForTests) -> CloudHelp {
        CloudHelp(store: store ?? InMemoryCloudHelpStore(settings), endpoint: endpoint, memory: memory ?? scratchMemory(),
                  auth: auth, policy: policy, transport: { maker.make() })
    }

    /// A chat on whatever model the setting picks, with its own preview
    /// gate and no reply beat.
    func chat(_ cloud: CloudHelp, conversation: Conversation? = nil) -> ChatController {
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        return ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                   conversation: conversation, review: model.runsOnDevice ? nil : review,
                                   replyBeat: .zero)
    }

    func personTurns(_ controller: ChatController) -> [String] {
        controller.conversation.turns.filter { $0.speaker == .person }.map(\.text)
    }

    // MARK: Off by default

    @Test func offByDefaultMakesNoTransportAndKeepsChatsOnDevice() async throws {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        #expect(!cloud.settings.isOn)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        #expect(model.runsOnDevice)
        #expect(cloud.runsOnDevice(local: LocalStubModel()))
        let chat = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                       conversation: nil)
        #expect(chat.conversation.onDevice)
        #expect(chat.review == nil)
        _ = try await chat.conversation.sending("Help me plan my morning.", with: model)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(review.pending == nil)
    }

    @Test func anEmptyAddressMeansDisabledEvenIfSavedOn() {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: CloudEndpoint.url(from: ""), maker: maker)
        #expect(!cloud.isAvailable)
        #expect(!cloud.usesCloudForNewChats)
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        #expect(!cloud.setOn(true))
        cloud.confirmTurnOn()
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        #expect(maker.made == 0)
    }

    // MARK: Turning it on

    @Test func turningOnAsksFirstAndOnlyYesTurnsItOn() {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        // Asking is all it does; "Not now" then changes nothing.
        #expect(cloud.setOn(true))
        #expect(!cloud.settings.isOn)
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.settings.isOn)
        #expect(cloud.usesCloudForNewChats)
        #expect(!cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        #expect(!cloud.setOn(false))
        #expect(!cloud.settings.isOn)
    }

    /// Turning the cloud on reaches nothing. A sign-in the cloud needs goes
    /// only as a hop in the first preview, on that preview's yes, through
    /// the same transport as the message.
    @Test func turningOnSendsNothingAndSignInWaitsForThePreviewsYes() async throws {
        let maker = TransportMaker()
        let auth = CountingAuth(needsSignIn: true)
        let cloud = help(endpoint: endpoint, maker: maker, auth: auth)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.usesCloudForNewChats)
        #expect(maker.made == 0)
        #expect(auth.signIns == 0)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        let declined = await review.shown()
        #expect(declined.signIn != nil)
        #expect(CloudPreviewSheet.shownText(declined).hasPrefix(CloudWords.previewSignInFirst + "\nPOST https://cloud.example.com/v1/sign-in\n"))
        review.answer(.cancel, for: declined.id)
        await controller.settled()
        #expect(maker.wire.sent.isEmpty)
        #expect(auth.signIns == 0)
        controller.draft = ""
        controller.submit("Plan my week")
        let shown = await review.shown()
        review.answer(.send, for: shown.id)
        await controller.settled()
        // The hop first, then the message, each as the person read it.
        #expect(maker.wire.sent.map(\.url) == shown.hops.map(\.url))
        #expect(maker.wire.sent.map(\.httpBody) == shown.hops.map(\.body))
        #expect(maker.wire.sent.map(\.allHTTPHeaderFields) == shown.hops.map(\.headers))
        #expect(auth.signIns == 1)
    }

    // MARK: Turning it off fails closed

    func cloud(_ store: any CloudHelpStoring, maker: TransportMaker) -> CloudHelp {
        CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), policy: .noSignInForTests,
                  transport: { maker.make() })
    }

    /// The save fails twice, so the file is erased: off now, in chats
    /// already open, on this screen, and on the next launch.
    @Test func aSwitchOffThatCantBeSavedErasesTheFileAndStaysOff() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.savesToFail = .max
        help.setOn(false)
        #expect(help.status == CloudWords.offButCleared)
        #expect(!help.settings.isOn)
        #expect(store.saved == nil)
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        #expect(controller.review?.pending == nil)
        help.refresh()
        #expect(!help.settings.isOn)
        // The next launch reads it fresh, and it is off.
        #expect(!cloud(store, maker: maker).settings.isOn)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Neither saved nor erased nor marked off: off for every chat until
    /// the app closes, the switch never flips back on, and the person is
    /// told plainly that it may read as on next time.
    @Test func aSwitchOffThatCantBeSavedOrErasedStaysOffForTheSession() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.savesToFail = .max
        store.eraseFails = true
        store.markFails = true
        help.setOn(false)
        #expect(help.status == CloudWords.offForNow)
        #expect(store.saved?.isOn == true)
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        // Coming back to the screen reads the file, which still says on.
        help.refresh()
        #expect(!help.settings.isOn)
        #expect(!help.usesCloudForNewChats)
        #expect(help.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        // Once saving works again, the switch off is saved then, and the
        // line that said it might not hold goes.
        store.savesToFail = 0
        help.refresh()
        #expect(store.saved?.isOn == false)
        #expect(help.status == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Neither saved nor erased, but marked off: a relaunch reads it as
    /// off, though the file underneath still says on. The words are kept.
    @Test func aSwitchOffThatCantBeSavedIsMarkedOffAndReadsOffAfterARelaunch() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        store.eraseFails = true
        help.setOn(false)
        #expect(help.status == CloudWords.offSavedLater)
        #expect(store.saved?.isOn == true)
        #expect(store.markedOff)
        let relaunched = cloud(store, maker: TransportMaker())
        #expect(!relaunched.usesCloudForNewChats)
        #expect(relaunched.settings.privateWords == ["lemon cake"])
        #expect(chat(relaunched).review == nil)
    }

    @Test func aSaveThatFailsOnceIsTriedAgain() {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = 1
        help.setOn(false)
        #expect(help.status == nil)
        #expect(store.saved == CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
    }

    /// Settings that are damaged when it is switched off are erased, so
    /// they can never read as on again.
    @Test func aSwitchOffWhileTheSettingsAreDamagedErasesThem() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.loadFails = .damaged
        help.setOn(false)
        #expect(help.status == CloudWords.offButCleared)
        #expect(store.saved == nil)
    }

    /// Settings only locked away, as on a locked device, are not damaged,
    /// so the private words are kept. The switch off holds for every chat,
    /// is marked off so it holds after a relaunch too, and is saved once
    /// the device is unlocked.
    @Test func aSwitchOffWhileTheDeviceIsLockedKeepsThePrivateWords() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.loadFails = .locked
        help.setOn(false)
        #expect(help.status == CloudWords.offUntilUnlocked)
        #expect(store.saved?.privateWords == ["lemon cake"])
        controller.submit("Plan my week")
        await controller.settled()
        #expect(maker.wire.sent.isEmpty)
        // Unlocked: read again, saved off, and the words are still there.
        store.loadFails = nil
        help.refresh()
        #expect(store.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(help.settings.privateWords == ["lemon cake"])
        #expect(!help.usesCloudForNewChats)
        #expect(help.status == nil)
    }

    /// Switched off while locked, and the app is closed before the device
    /// is unlocked. The next launch, for the very address that was said
    /// yes to, reads it as off: no stale yes comes back.
    @Test func aSwitchOffWhileLockedStaysOffAfterARelaunch() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.loadFails = .locked
        help.setOn(false)
        #expect(store.saved?.isOn(for: endpoint) == true, "the file itself couldn't be written")
        store.loadFails = nil
        let relaunched = cloud(store, maker: TransportMaker())
        #expect(!relaunched.usesCloudForNewChats)
        #expect(relaunched.settings.privateWords == ["lemon cake"])
        #expect(chat(relaunched).review == nil)
        #expect(relaunched.setOn(true), "only a fresh yes turns it on")
        relaunched.confirmTurnOn()
        #expect(relaunched.usesCloudForNewChats)
        #expect(!store.markedOff)
    }

    /// Switched off while locked, and even the off mark can't be written.
    /// Nothing holds past this launch, so the line says it may read as on
    /// next time, and never that the switch off will hold once unlocked.
    @Test func aSwitchOffWhileLockedThatCantBeMarkedSaysItMayReadAsOn() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.loadFails = .locked
        store.markFails = true
        help.setOn(false)
        #expect(help.status == CloudWords.offForNow)
        #expect(help.status != CloudWords.offUntilUnlocked)
        let line = try #require(help.status)
        #expect(line.contains("may be on again when you come back"))
        #expect(!line.contains("once this device is unlocked"))
        #expect(!store.markedOff)
        // Off for this launch all the same.
        controller.submit("Plan my week")
        await controller.settled()
        #expect(maker.wire.sent.isEmpty)
        // Unlocked: the switch off is saved then, and the line goes.
        store.loadFails = nil
        store.markFails = false
        help.refresh()
        #expect(store.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(help.status == nil)
    }

    /// Unlocking the device saves the switch off at once, without waiting
    /// for the setting to be opened again.
    @Test func unlockingTheDeviceSavesTheSwitchOff() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.loadFails = .locked
        help.setOn(false)
        store.loadFails = nil
        NotificationCenter.default.post(name: CloudHelp.unlocked, object: nil)
        #expect(store.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(!store.markedOff)
        #expect(help.status == nil)
    }

    /// The unlock watch's name carries neither the product's name nor its
    /// code name. On iPhone and iPad it is the system's own.
    @Test func theUnlockWatchNamesNoProduct() {
        let name = CloudHelp.unlocked.rawValue.lowercased()
        #expect(!name.contains("pebble"), "\(name)")
        #expect(!name.contains(brand.name.lowercased()), "\(name)")
    }

    /// A word added or removed while the device is locked gets a calm line
    /// about the lock, not one that says the words can't be read.
    @Test func aPrivateWordWhileLockedSaysTheDeviceIsLocked() {
        let store = FailingCloudStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.loadFails = .locked
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateLocked)
        help.removePrivateWord("lemon cake")
        #expect(help.status == CloudWords.privateLocked)
        store.loadFails = .damaged
        help.removePrivateWord("lemon cake")
        #expect(help.status == CloudWords.privateUnreadable)
    }

    /// Turning the cloud off, and Forget everything, both tell sign-in to
    /// let go of whatever it kept.
    @Test func turningOffAndForgettingTellSignInToForget() throws {
        let auth = CountingAuth()
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: scratchMemory(), auth: auth,
                             transport: { TransportMaker().make() })
        help.setOn(false)
        #expect(auth.forgets == 1)
        try help.forgetPrivateWords()
        #expect(auth.forgets == 2)
    }

    /// Turning the cloud off ends every cloud chat's session before sign-in
    /// is told to forget, so a sign-in answer still on the wire can never
    /// be handed over after the forget. A chat ended this way says the
    /// cloud is off, not that Forget everything ended it.
    @Test func turningOffEndsEveryCloudChatBeforeSignInForgets() async throws {
        let maker = TransportMaker()
        let auth = WitnessAuth()
        let help = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker, auth: auth)
        let one = chat(help), two = chat(help)
        let sessions = [one.cloudSession, two.cloudSession].compactMap { $0 }
        #expect(sessions.count == 2)
        auth.onForget = { sessions.allSatisfy(\.hasEnded) }
        help.setOn(false)
        #expect(auth.forgotAfterEveryEnd == [true])
        for session in sessions { #expect(session.hasEnded) }
        one.submit("Plan my week")
        await one.settled()
        #expect(one.failure == CloudWords.turnedOff)
        #expect(maker.wire.sent.isEmpty)
    }

    /// The sign-in hop is on the wire, held there, when the person turns
    /// the cloud off, or separately when they forget everything. Only then
    /// does its answer land. Sign-in is never handed it, it is told to
    /// forget, and every forget comes after every cloud chat has ended.
    @Test(arguments: [false, true])
    func aSignInAnswerThatLandsAfterOffOrForgetIsNeverKept(forget: Bool) async throws {
        let gate = GatedTransport()
        let auth = WitnessAuth(needsSignIn: true)
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                              endpoint: endpoint, memory: scratchMemory(), auth: auth, transport: { gate })
        let controller = chat(cloud)
        let session = try #require(controller.cloudSession)
        auth.onForget = { session.hasEnded }
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        review.answer(.send, for: await review.shown().id)
        #expect(await finishes { await gate.started() }, "the hop never reached the wire")
        if forget {
            try cloud.forgetPrivateWords()
        } else {
            cloud.setOn(false)
        }
        #expect(session.hasEnded)
        gate.answer()
        #expect(await finishes { await controller.settled() }, "the reply never ended")
        #expect(auth.signIns == 0, "the answer was handed over after \(forget ? "forget" : "off")")
        #expect(auth.forgotAfterEveryEnd.count >= 1)
        #expect(auth.forgotAfterEveryEnd.allSatisfy { $0 }, "sign-in forgot before the chat ended")
        #expect(gate.sends == 1, "only the hop went")
    }

    /// A sign-in hop that went counts as sent, so Forget everything never
    /// says "I no longer have it" after it: when the message after it fails
    /// on the wire, and when the cloud is turned off before the message.
    @Test(arguments: [true, false])
    func aSignInHopThatWentCountsAsSentWhateverHappensToTheMessage(messageFails: Bool) async throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint))
        let endpoint = endpoint
        let transport = HopAnswersFirst(messageFails: messageFails) {
            try? store.save(CloudHelpSettings(isOn: false, for: endpoint))
        }
        let auth = CountingAuth(needsSignIn: true)
        let cloud = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), auth: auth,
                              transport: { transport })
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        review.answer(.send, for: await review.shown().id)
        await controller.settled()
        #expect(transport.paths.first == "/v1/sign-in")
        #expect(transport.paths.count == (messageFails ? 2 : 1))
        #expect(cloud.anythingSentThisSession)
        #expect(auth.signIns == (messageFails ? 1 : 0), "an answer is handed over only while still on")
    }

    /// A sign-in carrying a private word, or a name from the notes, would
    /// go covered on the card, unseen. It is refused: no preview, nothing
    /// on the wire, the words back in the composer and a plain line why.
    @Test(arguments: [SampleSignIn(device: "lemon cake"), SampleSignIn(device: "Sam"),
                      SampleSignIn(device: "my lemon-cake order"), SampleSignIn(header: "Sam"),
                      SampleSignIn(device: "Lemon Cake"), SampleSignIn(device: "Sam's"),
                      // The names go too, so the same holds for them.
                      SampleSignIn(bodyKey: "Sam"), SampleSignIn(bodyKey: "lemon cake"),
                      SampleSignIn(headerName: "X-Lemon-Cake")])
    func aSignInCarryingAPrivateWordOrANoteNameSendsNothing(auth: SampleSignIn) async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), endpoint: endpoint,
                         maker: maker, memory: scratchMemory("Sam's birthday is May 14."), auth: auth)
        let controller = chat(cloud)
        controller.submit("Plan my week")
        // A preview shown here would wait forever for an answer.
        #expect(await finishes { await controller.settled() }, "a preview was shown")
        // Read before anything else touches the chat.
        let failure = controller.failure
        controller.stopReplying()
        #expect(controller.review?.pending == nil)
        #expect(failure == CloudWords.signInRefused)
        #expect(controller.draft == "Plan my week")
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
        #expect(!cloud.anythingSentThisSession)
    }

    /// The showcase's sign-in, with nothing personal in it, still shows.
    @Test func theShowcaseSignInStillShows() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), endpoint: endpoint,
                         maker: maker, memory: scratchMemory("Sam's birthday is May 14."), auth: SampleSignIn())
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        let shown = await review.shown()
        #expect(shown.signIn != nil)
        review.answer(.cancel, for: shown.id)
        await controller.settled()
        #expect(maker.wire.sent.isEmpty)
    }

    /// A private word saved later keeps the switch off, too.
    @Test func laterChangesKeepTheSwitchOff() {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        store.eraseFails = true
        help.setOn(false)
        store.savesToFail = 0
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(store.saved == CloudHelpSettings(isOn: false, privateWords: ["Sam"]))
    }

    @Test func aYesThatCantBeSavedLeavesItOffAndSaysSo() async {
        let auth = CountingAuth()
        let store = FailingCloudStore(.off)
        let help = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), auth: auth,
                             transport: { TransportMaker().make() })
        store.savesToFail = .max
        help.setOn(true)
        help.confirmTurnOn()
        #expect(help.status == CloudWords.onNotSaved)
        #expect(!help.settings.isOn)
        #expect(auth.signIns == 0)
        // Trying again once it can be saved turns it on.
        store.savesToFail = 0
        help.setOn(true)
        help.confirmTurnOn()
        #expect(help.status == nil)
        #expect(help.settings.isOn)
    }

    @Test func aPrivateWordThatCantBeSavedSaysSo() {
        let store = FailingCloudStore(.off)
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateNotSaved)
        #expect(help.newPrivateWord == "Sam")
    }

    /// A word that isn't added says why, and is spoken like every other
    /// status line, so VoiceOver never hears silence after the tap.
    @Test func aRefusedPrivateWordSaysWhy() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["Zoë"]))
        let help = cloud(store, maker: TransportMaker())
        let tooLong = String(repeating: "a", count: CloudHelpSettings.maxPrivateWordLength + 1)
        help.newPrivateWord = tooLong
        var count = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateTooLong)
        #expect(help.statusCount == count + 1)
        #expect(help.newPrivateWord == tooLong)

        help.newPrivateWord = "  zoë "
        count = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateAlreadyThere)
        #expect(help.statusCount == count + 1)
        #expect(help.newPrivateWord.isEmpty)

        let full = (0..<CloudHelpSettings.maxPrivateWords).map { "word\($0)" }
        try store.save(CloudHelpSettings(privateWords: full))
        help.newPrivateWord = "one more"
        count = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateFull)
        #expect(help.statusCount == count + 1)
        #expect(help.newPrivateWord == "one more")
        #expect(try store.load().privateWords == full)

        // A good word afterwards clears the line.
        try store.save(.off)
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(help.status == nil)
        #expect(help.settings.privateWords == ["Sam"])
    }

    /// A word of only hyphens or punctuation is refused with a line saying
    /// why, the field keeps it, and nothing is saved.
    @Test func aPrivateWordOfOnlyPunctuationSaysWhy() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        help.newPrivateWord = "--"
        let count = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateOnlyPunctuation)
        #expect(help.statusCount == count + 1)
        #expect(help.newPrivateWord == "--")
        #expect(try store.load().privateWords == ["lemon cake"])
        #expect(help.settings.privateWords == ["lemon cake"])
    }

    @Test func eachRefusalHasItsOwnLine() {
        #expect(CloudWords.privateRefused(.blank) == nil)
        let lines = [CloudHelpSettings.Refusal.onlyPunctuation, .tooLong, .full, .alreadyThere]
            .compactMap(CloudWords.privateRefused)
        #expect(Set(lines).count == 4)
        #expect(CloudWords.privateTooLong.contains("\(CloudHelpSettings.maxPrivateWordLength)"))
        #expect(CloudWords.privateFull.contains("\(CloudHelpSettings.maxPrivateWords)"))
    }

    /// VoiceOver speaks the same failure again when it happens again.
    @Test func theSameFailureTwiceIsCountedTwice() {
        let store = FailingCloudStore(.off)
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        let first = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateNotSaved)
        #expect(help.statusCount == first + 1)
    }

    @Test func theQuestionSaysWhatChangesWithoutOverclaiming() {
        let words = CloudWords.askPoints.joined(separator: " ")
        for promise in ["not on this device", "exactly what goes", "names", "emails", "phone numbers",
                        "addresses", "card numbers", "private words", "never leave this device",
                        "send nothing", "turn this off anytime", "The name you gave me goes too",
                        "internet address"] {
            #expect(words.contains(promise), "missing: \(promise)")
        }
        // Taking things out is a best effort; the preview is the safeguard.
        #expect(CloudWords.askPoints[2].hasPrefix("I try to take out"))
        // The preview doesn't claim nothing else goes: the server sees the
        // device's internet address.
        #expect(!CloudWords.previewDetail.contains("Nothing else"))
        #expect(CloudWords.previewDetail.contains("internet address"))
    }

    /// Every request carries the whole chat again, so neither the question
    /// nor the preview says the words go only once.
    @Test func theWordsSayEarlierMessagesGoAgain() {
        #expect(!CloudWords.previewDetail.contains("only once"))
        #expect(CloudWords.previewDetail.contains("Earlier messages in this chat go again with each new one"))
        #expect(CloudWords.askPoints.contains { $0.contains("Earlier messages in a chat go again with each new one") })
        #expect(CloudWords.all.allSatisfy { !$0.contains("only once") })
    }

    /// The question says sign-in is shown in the same preview, which is
    /// what the code does (`turningOnSendsNothingAndSignInWaitsForThePreviewsYes`).
    @Test func theQuestionSaysSignInIsInThePreview() throws {
        let signIn = try #require(CloudWords.askPoints.first { $0.contains("sign in") })
        #expect(signIn.contains("in the same preview"))
        // Its values are covered on screen, so it promises the labels only.
        #expect(signIn.contains("where it goes and which labels it carries"))
        #expect(!signIn.contains("what it carries"))
        #expect(!signIn.contains("right after your yes"))
        #expect(CloudWords.askPoints[1].hasPrefix("Before anything from a chat leaves"))
    }

    /// The values the person can't read carry nothing of theirs, and the
    /// question says so (`aSignInCarryingAPrivateWordOrANoteNameSendsNothing`
    /// holds the code to it).
    @Test func theQuestionPromisesSignInCarriesNothingPrivate() {
        #expect(CloudWords.askPoints.contains("Signing in never carries your chats, notes or private words."))
    }

    // MARK: The preview

    @Test func theSheetShowsExactlyTheRequestThatIsSent() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), endpoint: endpoint,
                         maker: maker, memory: scratchMemory("Sam's birthday is May 14."), auth: CountingAuth())
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        let chat = Conversation.firstRun(named: "Pip", onDevice: false)
        let reply = Task { try await chat.sending("Ask Sam to bring the lemon cake to 42 Maple Street.", with: model) }
        let preview = await review.shown()
        let shown = CloudPreviewSheet.shownText(preview)
        #expect(shown.hasPrefix("POST https://cloud.example.com/v1/reply\n"))
        #expect(shown.contains("X-Sample-Sign-In: made-up"))
        #expect(shown.contains("User-Agent: agent"))
        #expect(shown.contains("\nHost: cloud.example.com\n"))
        #expect(shown.contains("\nContent-Length: \(preview.request.body.count)\n"))
        #expect(shown.contains("Ask [name] to bring the [private] to [address]."))
        #expect(CloudPreviewSheet.hiddenLine(preview) == "Taken out of this chat: 1 private word, 1 address, 1 name.")
        #expect(maker.wire.sent.isEmpty)
        review.answer(.send, for: preview.id)
        let next = try await reply.value
        #expect(next.turns.last?.text == "Here's a short note.")
        let sent = try #require(maker.wire.sent.first)
        #expect(maker.wire.sent.count == 1)
        // What URLSession was handed, laid out the same way, is what the person read.
        let wire = CloudRequest.shownText(method: try #require(sent.httpMethod), url: try #require(sent.url),
                                          headers: sent.allHTTPHeaderFields ?? [:], body: sent.httpBody ?? Data())
        #expect(wire == shown)
        #expect(sent.allHTTPHeaderFields == preview.request.headers)
        #expect(review.pending == nil)
    }

    /// The count covers the whole chat, which goes again each time, and the
    /// line says so rather than reading as new for this message.
    @Test func theHiddenCountSaysItIsForTheWholeChat() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Call 416-555-0199")
        let first = await review.shown()
        #expect(CloudPreviewSheet.hiddenLine(first) == "Taken out of this chat: 1 phone number.")
        review.answer(.send, for: first.id)
        await controller.settled()
        controller.submit("Thanks")
        let second = await review.shown()
        // Nothing new was hidden; the one number is still the one number.
        #expect(CloudPreviewSheet.hiddenLine(second) == "Taken out of this chat: 1 phone number.")
        review.answer(.cancel, for: second.id)
        await controller.settled()
    }

    /// A request the transport refuses for its labels never left, so the
    /// turn is taken back and a resend doesn't carry it twice.
    @Test func aRequestRefusedForItsLabelsTakesTheTurnBack() async throws {
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: scratchMemory(), policy: .noSignInForTests, transport: { RefusingTransport() })
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        review.answer(.send, for: await review.shown().id)
        await controller.settled()
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Plan my week")
        controller.draft = ""
        controller.submit("Plan my week")
        let again = await review.shown()
        let payload = try JSONDecoder().decode(CloudPayload.self, from: again.request.body)
        #expect(payload.messages.filter { $0.role == "person" }.map(\.text) == ["Plan my week"])
        review.answer(.cancel, for: again.id)
        await controller.settled()
    }

    @Test func notSendingTakesTheTurnBackAndTheWordsNeverGoLater() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Write a note about my diagnosis")
        let declined = await review.shown()
        review.answer(.cancel, for: declined.id)
        await controller.settled()
        #expect(!controller.isReplying)
        #expect(controller.failure == CloudWords.notSent)
        #expect(controller.draft == "Write a note about my diagnosis")
        // The declined words are out of the chat, not just back in the composer.
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
        // The next line is sent without them.
        controller.draft = ""
        controller.submit("Plan my week")
        let next = await review.shown()
        #expect(!next.request.text.contains("diagnosis"))
        review.answer(.send, for: next.id)
        await controller.settled()
        #expect(maker.wire.sent.count == 1)
        #expect(maker.wire.sentText.allSatisfy { !$0.contains("diagnosis") })
        #expect(personTurns(controller) == ["Plan my week"])
    }

    @Test func turningOffWhileThePreviewShowsSendsNothingAndTakesTheTurnBack() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        cloud.setOn(false)
        await controller.settled()
        #expect(controller.failure == CloudWords.notSent)
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
        // A later line in the same chat is not sent either, and is taken back too.
        controller.draft = ""
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Plan my week")
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func stoppingAReplyClosesThePreviewAndSendsNothing() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        let reply = Task { try await Conversation.firstRun(named: "Pip").sending("Plan my week", with: model) }
        _ = await review.shown()
        reply.cancel()
        await #expect(throws: (any Error).self) { try await reply.value }
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// The race: a new question replaces the one on screen. A Send meant
    /// for the old one must not send the new one, which was never seen.
    @Test func aTapOnOnePreviewNeverSendsAnother() async throws {
        let review = CloudReview()
        let request = CloudRequest(url: CloudModel.url(for: endpoint), headers: CloudHeaders.fixed, body: Data("{}".utf8))
        let first = CloudPreview(request: request, hidden: [:])
        let second = CloudPreview(request: request, hidden: [:])
        let firstAnswer = Task { await review.review(first) }
        #expect(await review.shown() == first)
        let secondAnswer = Task { await review.review(second) }
        // Asking the second question withdraws the first.
        #expect(await firstAnswer.value == .cancel)
        #expect(review.pending == second)
        // A late tap on the first sheet does nothing to the second.
        review.answer(.send, for: first.id)
        review.answer(.cancel, for: first.id)
        #expect(review.pending == second)
        review.answer(.send, for: second.id)
        #expect(await secondAnswer.value == .send)
        #expect(review.pending == nil)
    }

    @Test func aScreenshotPreviewCanBeDismissed() {
        let review = CloudReview()
        let preview = CloudPreview(request: CloudRequest(url: endpoint, headers: [:], body: Data()), hidden: [:])
        review.show(preview)
        review.answer(.cancel, for: preview.id)
        #expect(review.pending == nil)
    }

    /// Going back to Today, or to another place in the sidebar, while a
    /// preview waits means it is not sent, and the reply never hangs.
    @Test func aPreviewIsNotSentWhenTheChatScreenGoesAway() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        controller.screenWentAway()
        await controller.settled()
        #expect(!controller.isReplying)
        #expect(review.pending == nil)
        #expect(controller.failure == CloudWords.notSent)
        #expect(controller.draft == "Plan my week")
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Each chat, and so each window, has its own preview. One chat's
    /// question never shows over another's.
    @Test func eachChatShowsOnlyItsOwnPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let one = chat(cloud), two = chat(cloud)
        let oneReview = try #require(one.review), twoReview = try #require(two.review)
        #expect(oneReview !== twoReview)
        one.submit("Plan my week")
        _ = await oneReview.shown()
        #expect(twoReview.pending == nil)
        two.submit("Plan my weekend")
        _ = await twoReview.shown()
        // Turning the cloud off withdraws both.
        cloud.setOn(false)
        await one.settled()
        await two.settled()
        #expect(oneReview.pending == nil && twoReview.pending == nil)
        #expect(one.failure == CloudWords.notSent && two.failure == CloudWords.notSent)
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: Notes the redactor can't read

    @Test func unreadableNotesSendNothingAndSaySo() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory()
        try Data("not notes".utf8).write(to: memory.fileURL)
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker, memory: memory)
        let controller = chat(cloud)
        controller.submit("Write to Sam")
        await controller.settled()
        #expect(controller.failure == CloudWords.notesUnreadable)
        #expect(controller.review?.pending == nil)
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Write to Sam")
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func unreadablePrivateWordsSendNothing() async throws {
        let maker = TransportMaker()
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let cloud = help(endpoint: endpoint, maker: maker, store: store)
        let controller = chat(cloud)
        store.makeUnreadable()
        controller.submit("Bring the lemon cake")
        await controller.settled()
        // Settings that can't be read are not the same as off: the chat
        // says it couldn't read them, and the setting still shows on.
        #expect(controller.failure == CloudWords.notesUnreadable)
        #expect(controller.failure != CloudWords.turnedOff)
        #expect(cloud.settings.isOn)
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
        // And nothing is saved over them while they can't be read.
        cloud.newPrivateWord = "Sam"
        cloud.addPrivateWord()
        // This store's unreadable stands for a locked device.
        #expect(cloud.status == CloudWords.privateLocked)
        store.makeUnreadable(false)
        #expect(try store.load().privateWords == ["lemon cake"])
    }

    /// The memory screen and the redactor share one store, so a note just
    /// saved counts in the very next request.
    @Test func aNoteJustSavedIsHiddenInTheNextRequest() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker, memory: memory)
        #expect(cloud.memory === memory)
        let notes = MemoryModel(store: memory, place: .onDevice)
        notes.newNote = "Priya is my sister."
        notes.add()
        let controller = chat(cloud)
        controller.submit("Plan a dinner for Priya")
        let preview = try await #require(controller.review).shown()
        #expect(preview.request.text.contains("Plan a dinner for [name]"))
        controller.screenWentAway()
        await controller.settled()
    }

    // MARK: Private words

    @Test func forgetEverythingErasesThePrivateWordsToo() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try cloud.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(memory.notes().isEmpty)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(try store.load() == CloudHelpSettings(isOn: true, for: endpoint, privateWords: []))
    }

    /// Forget everything as the app wires it: the notes, the private words
    /// and the tasks all go, from one tap.
    @Test func forgetEverythingErasesNotesWordsAndTasks() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                             place: .mayLeaveDevice)
        let model = MemoryModel(store: memory, place: .mayLeaveDevice, alsoForget: { try cloud.forgetPrivateWords() },
                                onForgetEverything: { feed.forgetTasks() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(memory.notes().isEmpty)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(engine.tasks.isEmpty)
    }

    /// The notes couldn't be erased, but the tasks and the private words
    /// went, and the line says exactly that.
    @Test func forgetEverythingSaysTheTasksAndWordsWentWhenTheNotesStayed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                             place: .onDevice)
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() },
                                onForgetEverything: { feed.forgetTasks() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotTasksAndWordsNotNotes)
        #expect(engine.tasks.isEmpty)
        #expect(try store.load().privateWords.isEmpty)
        #expect(memory.notes().count == 1)
    }

    /// The private words couldn't be erased, but the notes and tasks went.
    @Test func forgetEverythingSaysTheNotesAndTasksWentWhenTheWordsStayed() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        store.eraseFails = true
        let help = cloud(store, maker: TransportMaker())
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                             place: .onDevice)
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() },
                                onForgetEverything: { feed.forgetTasks() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotNotesAndTasksNotWords)
        #expect(memory.notes().isEmpty)
        #expect(engine.tasks.isEmpty)
    }

    /// Every way the three parts can land has its own honest line. Tasks
    /// can't fail to go, so they are named only when something stayed.
    @Test func everyForgetOutcomeHasItsOwnLine() {
        let line: (Bool, CloudHelp.Forgot??, Bool) -> String = {
            MemoryModel.forgotLine(notesGone: $0, rest: $1, tasksGone: $2)
        }
        #expect(line(true, nil, true) == MemoryWords.forgotten)
        #expect(line(true, .privateWords, true) == MemoryWords.forgotten)
        #expect(line(true, .privateWordsAndCloud, true) == CloudWords.forgotAndCloudOff)
        #expect(line(true, .some(nil), false) == CloudWords.forgotNotesNotWords)
        #expect(line(true, .some(nil), true) == CloudWords.forgotNotesAndTasksNotWords)
        #expect(line(false, .privateWords, false) == CloudWords.forgotWordsNotNotes)
        #expect(line(false, .privateWords, true) == CloudWords.forgotTasksAndWordsNotNotes)
        #expect(line(false, .privateWordsAndCloud, false) == CloudWords.forgotWordsAndCloudNotNotes)
        #expect(line(false, .privateWordsAndCloud, true) == CloudWords.forgotTasksAndWordsAndCloudNotNotes)
        #expect(line(false, .some(nil), false) == MemoryWords.couldNotForget)
        #expect(line(false, .some(nil), true) == CloudWords.forgotTasksNotNotesOrWords)
        #expect(line(false, nil, false) == MemoryWords.couldNotForget)
        #expect(line(false, nil, true) == MemoryWords.couldNotForgetNotes)
        // The three lines where tasks went speak in one voice.
        for went in [CloudWords.forgotNotesAndTasksNotWords, CloudWords.forgotTasksAndWordsNotNotes,
                     CloudWords.forgotTasksNotNotesOrWords] {
            #expect(went.hasPrefix("Your "), "\(went)")
            #expect(went.contains("tasks") && went.contains(" are gone, but I couldn't erase your "), "\(went)")
            #expect(!went.contains("I forgot"), "\(went)")
        }
        #expect(CloudWords.forgotTasksNotNotesOrWords.hasPrefix("Your tasks are gone, but"))
        // The cloud's question says tasks go and stop, like the plain one.
        #expect(CloudWords.forgetEverythingDetail.contains("every task"))
        #expect(CloudWords.forgetEverythingDetail.contains("stops any task still going"))
    }

    /// Once anything was handed to the cloud this session, no outcome says
    /// "I no longer have it", and every one ends by saying what went there
    /// can't be erased from here.
    @Test func afterSendingNoForgetLineSaysGone() {
        let outcomes: [(Bool, CloudHelp.Forgot??, Bool)] = [
            (true, nil, true), (true, .privateWords, false), (true, .privateWordsAndCloud, true),
            (true, .some(nil), false), (false, .privateWords, true), (false, .privateWordsAndCloud, false),
            (false, .some(nil), true), (false, nil, false),
        ]
        for (notes, rest, tasks) in outcomes {
            let line = MemoryModel.forgotLine(notesGone: notes, rest: rest, tasksGone: tasks, sent: true)
            #expect(!line.contains("I no longer have it"), "\(line)")
            #expect(line.hasSuffix(" " + CloudWords.sentCantBeErased), "\(line)")
            #expect(MemoryModel.forgotLine(notesGone: notes, rest: rest, tasksGone: tasks, sent: false)
                    == MemoryModel.forgotLine(notesGone: notes, rest: rest, tasksGone: tasks))
        }
        #expect(MemoryModel.forgotLine(notesGone: true, rest: .privateWords, tasksGone: true, sent: true)
                == CloudWords.forgotAfterSending + " " + CloudWords.sentCantBeErased)
        #expect(MemoryModel.forgotLine(notesGone: true, rest: .privateWordsAndCloud, tasksGone: true, sent: true)
                == CloudWords.forgotAndCloudOffAfterSending + " " + CloudWords.sentCantBeErased)
    }

    /// Each half is erased whatever happens to the other, and the line says
    /// what actually went.
    @Test func forgetEverythingErasesTheWordsEvenWhenTheNotesCantBeErased() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        // A folder that can't be changed, so the notes can't be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotWordsNotNotes)
        #expect(try store.load().privateWords.isEmpty)
        #expect(memory.notes().count == 1)
    }

    @Test func forgetEverythingErasesTheNotesEvenWhenTheWordsCantBeErased() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        store.eraseFails = true
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotNotesNotWords)
        #expect(memory.notes().isEmpty)
    }

    /// Words that can't be saved without them are erased with the file,
    /// which also turns the cloud off, and the line says so.
    @Test func privateWordsThatCantBeSavedAwayAreErasedWithTheFile() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotAndCloudOff)
        #expect(CloudWords.forgotAndCloudOff.contains("help from the cloud is off"))
        #expect(store.saved == nil)
        #expect(help.settings == .off)
    }

    /// Words that can't even be read are erased with the file too. Unread,
    /// the setting may have said on, so the line says it is off now.
    @Test func unreadableWordsAreErasedWithTheFileAndTheLineSaysTheCloudIsOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        store.makeUnreadable()
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotWordsAndCloudNotNotes)
        #expect(try store.load() == .off)
    }

    /// When the setting was already off, clearing it turns nothing off, so
    /// the plain line is the true one.
    @Test func clearingASettingThatWasOffSaysOnlyGone() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: scratchMemory("Sam's birthday is May 14."),
                                place: .onDevice, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(store.saved == nil)
    }

    /// The cloud going off this way closes any preview waiting in an open
    /// chat, and that chat sends nothing more.
    @Test func clearingTheSettingClosesAWaitingPreview() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        store.savesToFail = .max
        #expect(try help.forgetPrivateWords() == .privateWordsAndCloud)
        await controller.settled()
        #expect(review.pending == nil)
        #expect(controller.failure == CloudWords.notSent)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A word half typed into the field goes with Forget everything too.
    @Test func forgetEverythingClearsAHalfTypedWord() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), store: store)
        help.newPrivateWord = "Riverside Cli"
        MemoryModel(store: scratchMemory(), place: .onDevice, alsoForget: { try help.forgetPrivateWords() }).forgetEverything()
        #expect(help.newPrivateWord.isEmpty)
        // Even when nothing could be erased.
        let failing = FailingCloudStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        failing.savesToFail = .max
        failing.eraseFails = true
        let stuck = cloud(failing, maker: TransportMaker())
        stuck.newPrivateWord = "Riverside Cli"
        #expect(throws: (any Error).self) { try stuck.forgetPrivateWords() }
        #expect(stuck.newPrivateWord.isEmpty)
    }

    /// Forget everything in the middle of a cloud chat ends that chat: it
    /// lets go of its turns and of what it hid, and sends nothing more, so
    /// no chat keeps the words that were erased, and none can go back out
    /// in the clear.
    @Test func forgettingEndsAnOpenCloudChat() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: maker, memory: memory, store: store)
        let controller = chat(help)
        let review = try #require(controller.review)
        controller.submit("Ask Sam about the lemon cake")
        review.answer(.send, for: await review.shown().id)
        await controller.settled()
        MemoryModel(store: memory, place: .onDevice, alsoForget: { try help.forgetPrivateWords() }).forgetEverything()
        #expect(memory.notes().isEmpty && help.settings.privateWords.isEmpty)
        controller.submit("Thanks")
        // A preview shown here would wait forever for an answer.
        #expect(await finishes { await controller.settled() }, "the ended chat showed a preview")
        controller.stopReplying()
        #expect(controller.failure == CloudWords.chatEnded)
        #expect(review.pending == nil)
        #expect(maker.wire.sent.count == 1)
    }

    @Test func addingAPrivateWordKeepsWordsSavedElsewhere() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), store: store)
        // Saved by another window since this one loaded.
        try store.save(CloudHelpSettings(privateWords: ["lemon cake", "Riverside Clinic"]))
        cloud.newPrivateWord = "Sam"
        cloud.addPrivateWord()
        #expect(try store.load().privateWords == ["lemon cake", "Riverside Clinic", "Sam"])
        #expect(cloud.newPrivateWord.isEmpty)
    }

    // MARK: The on-device promise and care

    @Test func anOnDeviceConversationIsNeverHandedToTheCloud() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        // A chat that promised on-device is not reused with the cloud model.
        let promised = Conversation.firstRun(named: "Pip", onDevice: true)
        let controller = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: promised)
        #expect(!controller.conversation.onDevice)
        #expect(controller.conversation.turns.first?.text.contains("stays") == false)
        #expect(controller.privacyPlace == .mayLeaveDevice)
        #expect(FirstConversation.presence(controller.privacyPlace) == "Here with you.")
        // And sent directly, it is refused before any preview.
        await #expect(throws: ConversationError.leavesDevice) {
            try await promised.sending("Write to Sam", with: model)
        }
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func careIsAnsweredHereWithNoPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        controller.submit("I want to kill myself")
        await controller.settled()
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A chat that holds words that must stay here can never be sent
    /// again. It says so warmly and points to a new chat, rather than
    /// asking the person to send again forever.
    @Test func aChatThatMustStayHereSaysSoAndPointsToANewChat() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, maker: maker)
        var turns = Conversation.firstRun(named: "Pip", onDevice: false).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "What does a crisis line do?"))
        turns.append(ChatTurn(id: UUID(), speaker: .agent, text: "It's there for anyone thinking about suicide, any time."))
        let controller = chat(cloud, conversation: Conversation(turns: turns, onDevice: false))
        controller.submit("Thanks")
        await controller.settled()
        #expect(controller.failure == CloudWords.staysHere)
        #expect(controller.failure != FirstConversation.couldNotAnswer)
        #expect(CloudWords.staysHere.contains("new chat"))
        #expect(controller.conversation.turns.count == turns.count)
        #expect(controller.draft == "Thanks")
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func theOnDeviceHeaderStaysForOnDeviceChats() {
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        #expect(controller.privacyPlace == .onDevice)
        #expect(FirstConversation.presence(controller.privacyPlace) == "Here with you, on this device.")
    }

    @Test func eachFailureHasItsOwnLine() {
        #expect(ChatController.failureLine(for: CloudModelError.notSent) == CloudWords.notSent)
        #expect(ChatController.failureLine(for: CloudModelError.off) == CloudWords.turnedOff)
        #expect(ChatController.failureLine(for: CloudModelError.staysHere) == CloudWords.staysHere)
        #expect(ChatController.failureLine(for: CloudModelError.notesUnreadable) == CloudWords.notesUnreadable)
        #expect(ChatController.failureLine(for: CloudModelError.unreadableReply) == FirstConversation.couldNotAnswer)
        #expect(ChatController.failureLine(for: CloudModelError.ended) == CloudWords.chatEnded)
        #expect(ChatController.failureLine(for: CloudTransportError.signInBodyRefused) == CloudWords.signInRefused)
        #expect(ChatController.failureLine(for: CloudTransportError.signInCarriesPersonalDetails)
                == CloudWords.signInRefused)
        #expect(ChatController.failureLine(for: CloudTransportError.signInHeaderRefused("X Token"))
                == CloudWords.signInRefused)
        #expect(ChatController.nothingWasSent(CloudTransportError.signInHeaderRefused("X Token")))
        #expect(ChatController.nothingWasSent(CloudTransportError.notSecure))
        // Only a reply that went out keeps the person's turn.
        #expect(!ChatController.nothingWasSent(CloudModelError.unreadableReply))
        #expect(!ChatController.nothingWasSent(URLError(.timedOut)))
        #expect(ChatController.nothingWasSent(CloudModelError.ended))
        // Refused before sending, for labels that weren't shown or are reserved.
        #expect(ChatController.nothingWasSent(CloudTransportError.headersNotShown))
        #expect(ChatController.nothingWasSent(CloudTransportError.reservedHeader("Authorization")))
        // No sign-in, no session after one, or an old key kept: the
        // message never went, so the words go back to the composer.
        #expect(ChatController.failureLine(for: CloudModelError.needsSignIn) == CloudWords.needsSignIn)
        #expect(ChatController.failureLine(for: CloudModelError.noSession) == CloudWords.noSession)
        #expect(ChatController.failureLine(for: CloudModelError.oldKeyStayed) == CloudWords.oldKeyStayed)
        for error in [CloudModelError.needsSignIn, .noSession, .oldKeyStayed] {
            #expect(ChatController.nothingWasSent(error), "\(error)")
        }
        #expect(CloudWords.needsSignIn.contains("sign in with Apple"))
        #expect(CloudWords.needsSignIn.contains("can't do that yet"))
    }

    // MARK: VoiceOver, privacy and size

    @Test func voiceOverReadsEachMessageWithMasksInWords() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam at 416-555-0199"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let lines = CloudPreviewSheet.spokenLines(preview)
        #expect(lines.first == "Going to https://cloud.example.com/v1/reply.")
        #expect(lines.contains { $0.hasPrefix("Sent with these labels: Accept, application/json.") })
        #expect(lines.last == "You said: Call hidden name at hidden phone number")
        #expect(lines.contains("I said: \(FirstConversation.opening(named: "Pip"))"))
        #expect(!lines.joined().contains("{"))
        #expect(!lines.joined().contains("["))
    }

    /// A sign-in value goes as shown, but is covered on the card and never
    /// spoken: VoiceOver says only its name and that it is hidden, not even
    /// how long it is.
    @Test func voiceOverNeverReadsASignInValue() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: ["X-Sample-Sign-In": "made-up"])
        #expect(CloudPreviewSheet.shownText(preview).contains("X-Sample-Sign-In: made-up"))
        let spoken = CloudPreviewSheet.spokenLines(preview).joined(separator: " ")
        #expect(spoken.contains("X-Sample-Sign-In, sign-in value, hidden"))
        #expect(!spoken.contains("made-up"))
        #expect(!spoken.contains("characters"))
        // The fixed labels and the ones the system adds say nothing secret,
        // so they are read in full.
        #expect(spoken.contains("User-Agent, agent"))
        #expect(spoken.contains("Host, cloud.example.com"))
        #expect(spoken.contains("Content-Length, \(preview.request.body.count)"))
        // On the card the value is covered, and everything else is as sent.
        let drawn = CloudPreviewSheet.displayedText(preview)
        #expect(!drawn.contains("made-up"))
        #expect(drawn.contains("X-Sample-Sign-In: " + CloudPreviewSheet.signInMask))
        #expect(drawn == CloudPreviewSheet.shownText(preview)
            .replacingOccurrences(of: "X-Sample-Sign-In: made-up", with: "X-Sample-Sign-In: " + CloudPreviewSheet.signInMask))
    }

    /// The sign-in hop's body is never skipped aloud: with the showcase's
    /// sign-in, VoiceOver hears that a body goes with the sign-in and the
    /// name of each part, its value hidden, as the card covers it.
    @Test func voiceOverHearsTheSignInHopsBody() throws {
        let auth = SampleSignIn()
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: auth.headers(for: CloudModel.url(for: endpoint)),
                                             signIn: auth.signIn(for: endpoint))
        let hop = try #require(preview.signIn)
        #expect(!hop.body.isEmpty)
        let spoken = CloudPreviewSheet.spokenLines(preview)
        let first = try #require(spoken.firstIndex(of: CloudWords.previewSignInFirst))
        let then = try #require(spoken.firstIndex(of: CloudWords.previewThenMessage))
        #expect(spoken[first + 1] == CloudWords.previewSignInCovered)
        #expect(spoken[first..<then].contains(CloudWords.spokenSignInBody(["device"])))
        #expect(!spoken.joined(separator: " ").contains("made-up-sample-device"))
    }

    /// What is covered, pinned in both places: in the hop and the message,
    /// every sign-in label's value; in the hop, its whole body but the
    /// names of its parts; in the message, nothing of the body. Method,
    /// address, fixed labels, Host and Content-Length show in full.
    @Test func whatThePreviewCoversIsPinnedOnTheCardAndAloud() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let mask = CloudPreviewSheet.signInMask
        let preview = try CloudModel.preview(
            for: turns, endpoint: endpoint, redactor: Redactor(), headers: ["X-Sample-Sign-In": "made-up-header"],
            signIn: CloudSignIn(path: "v1/sign-in", headers: ["X-Sample-Device": "made-up-device"],
                                body: Data(#"{"device":"made-up-id","code":"made-up-code"}"#.utf8)))
        let hop = try #require(preview.signIn)
        let drawn = CloudPreviewSheet.displayedText(preview)
        #expect(drawn == CloudWords.previewSignInFirst + "\n"
            + "POST https://cloud.example.com/v1/sign-in\n"
            + "Accept: application/json\nAccept-Encoding: identity\nAccept-Language: en\n"
            + "Cache-Control: no-cache\nConnection: keep-alive\n"
            + "Content-Length: \(hop.body.count)\nContent-Type: application/json\nHost: cloud.example.com\n"
            + "User-Agent: agent\nX-Sample-Device: \(mask)\n\n"
            + "{\n  \"code\" : \(mask),\n  \"device\" : \(mask)\n}\n\n"
            + CloudWords.previewThenMessage + "\n"
            + preview.request.shownText.replacingOccurrences(of: "made-up-header", with: mask))
        let spoken = CloudPreviewSheet.spokenLines(preview).joined(separator: "\n")
        for secret in ["made-up-header", "made-up-device", "made-up-id", "made-up-code"] {
            #expect(!drawn.contains(secret), "\(secret) drawn")
            #expect(!spoken.contains(secret), "\(secret) spoken")
        }
        #expect(spoken.contains(CloudWords.spokenSignIn("X-Sample-Device")))
        #expect(spoken.contains(CloudWords.spokenSignIn("X-Sample-Sign-In")))
        #expect(spoken.contains(CloudWords.spokenSignInBody(["code", "device"])))
        #expect(spoken.contains("Host, cloud.example.com"))
        #expect(spoken.contains("Content-Length, \(hop.body.count)"))
        #expect(spoken.contains(CloudWords.spokenMessage(role: "person", text: "Plan my week")))
        // A body that isn't a JSON object is covered whole; an empty one
        // has nothing to cover.
        #expect(CloudPreviewSheet.maskedSignInBody(Data("token=made-up".utf8)) == mask)
        #expect(CloudPreviewSheet.maskedSignInBody(Data()) == "")
        // A name that could draw a line of its own, such as a fake one
        // with a value in the clear, is never drawn: the body is covered
        // whole. `CloudModel.preview` refuses such a body before this.
        let spoofing = Data(#"{"token\" : \"in the clear\",\n  \"x":"made-up"}"#.utf8)
        #expect(CloudPreviewSheet.maskedSignInBody(spoofing) == mask)
        #expect(CloudPreviewSheet.signInBodyNames(spoofing) == nil)
    }

    /// The sheet says values are covered whenever the card covers one: a
    /// sign-in hop, or a sign-in label on the message alone. With nothing
    /// covered it says nothing of the kind.
    @Test func theSheetSaysValuesAreCoveredWheneverOneIs() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let plain = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor())
        let labelled = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                              headers: ["X-Sample-Sign-In": "made-up"])
        let hop = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                         signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)))
        #expect(!CloudPreviewSheet.coversAnything(plain))
        #expect(CloudPreviewSheet.coversAnything(labelled))
        #expect(CloudPreviewSheet.coversAnything(hop))
        // Aloud too, in both cases, and never with nothing covered.
        let spoken = { CloudPreviewSheet.spokenLines($0).filter { $0 == CloudWords.previewSignInCovered }.count }
        #expect(spoken(plain) == 0)
        #expect(spoken(labelled) == 1)
        #expect(spoken(hop) == 1)
        #expect(CloudPreviewSheet.spokenLines(labelled).first == CloudWords.previewSignInCovered)
        // The line is true with a hop, a covered label on the message, or
        // both: it says the values go when the person sends, not with what.
        #expect(CloudWords.previewSignInCovered.hasSuffix("They still go when you send this."))
        #expect(!CloudWords.previewSignInCovered.contains("with the sign-in"))
        // The title and detail claim nothing the covered card can't show.
        #expect(CloudWords.previewTitle == "Here is what leaves your device")
        for line in [CloudWords.previewTitle, CloudWords.previewDetail] {
            #expect(!line.contains("exactly"), "\(line)")
            #expect(!line.contains("whole request"), "\(line)")
        }
        #expect(CloudWords.previewSignInCovered.hasPrefix("Sign-in values are covered"))
    }

    /// The card's text can't be selected, so a long press never puts a
    /// sign-in value on the clipboard.
    @Test func thePayloadCantBeSelectedOrCopied() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains(".textSelection(.enabled)"))
        #expect(text.contains(".textSelection(.disabled)"))
    }

    /// Marked private, the payload and the word list vanish when the system
    /// hides private things; the rest of the screen stays.
    @Test func thePayloadAndPrivateWordsArePrivacySensitive() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let size = CGSize(width: 390, height: 600)
        // Rendered as an app in use; a still render otherwise counts as in
        // the background.
        let payload = AnyView(CloudPayloadCard(preview: preview).environment(\.scenePhase, .active))
        #expect(try pixels(payload, size: size) != pixels(payload.redacted(reason: .privacy), size: size))
        let words = AnyView(PrivateWordList(words: ["lemon cake"], onRemove: { _ in }).environment(\.scenePhase, .active))
        #expect(try pixels(words, size: size) != pixels(words.redacted(reason: .privacy), size: size))
        // A plain view is not hidden, so the difference is the marking.
        let plain = AnyView(Text("lemon cake").padding())
        #expect(try pixels(plain, size: size) == pixels(plain.redacted(reason: .privacy), size: size))
        // Leaving the app hides them on its own, for the app switcher.
        let leaving = AnyView(CloudPayloadCard(preview: preview).environment(\.scenePhase, .inactive))
        #expect(try pixels(leaving, size: size) == pixels(payload.redacted(reason: .privacy), size: size))
    }

    /// A word half typed into the field is as private as the list. A still
    /// render can't draw a text field, so this reads the field's own code:
    /// the one place the screen types a private word is marked private and
    /// hides when the app is not in use.
    @Test func theHalfTypedWordIsPrivacySensitive() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "struct PrivateWordField: View {"))
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let field = text[start.lowerBound..<end.upperBound]
        #expect(field.contains("TextField(CloudWords.privatePlaceholder, text: $word)"))
        #expect(field.contains(".privacySensitive()"))
        #expect(field.contains(".redacted(reason: privateRedaction(scenePhase))"))
        #expect(field.contains(".autocorrectionDisabled()"))
        // And it is the field the screen uses, the only one there.
        #expect(text.components(separatedBy: "TextField(").count == 2)
        #expect(text.contains("PrivateWordField(word: $help.newPrivateWord)"))
    }

    @Test func privateThingsHideWheneverTheAppIsNotInUse() {
        #expect(privateRedaction(.active).isEmpty)
        #expect(privateRedaction(.inactive) == .privacy)
        #expect(privateRedaction(.background) == .privacy)
    }

    @Test func theAddButtonIsBigEnoughToTap() {
        #expect(CloudHelpView.addButtonSize >= 44)
    }

    @Test func theGoMenuNumbersOnlyTheFirstNinePlaces() {
        #expect(HomeCommands.goShortcut(for: 0)?.key.character == "1")
        #expect(HomeCommands.goShortcut(for: 8)?.key.character == "9")
        #expect(HomeCommands.goShortcut(for: 9) == nil)
        #expect(HomeCommands.goShortcut(for: -1) == nil)
    }

    // MARK: Screens render

    @Test(arguments: [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)])
    func screensRender(size: CGSize) throws {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam at 416-555-0199"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let screens: [AnyView] = [
            AnyView(CloudHelpView(help: cloud)),
            AnyView(CloudTurnOnSheet(onYes: {}, onNo: {})),
            AnyView(CloudPreviewSheet(preview: preview, onSend: {}, onCancel: {})),
        ]
        for screen in screens {
            let renderer = ImageRenderer(content: screen.frame(width: size.width, height: size.height))
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(size.width * renderer.scale))
        }
        #expect(maker.made == 0)
    }

    private func pixels(_ view: some View, size: CGSize) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data) as Data
    }

    private func scratchMemory(_ notes: String...) -> MemoryStore {
        let url = scratch.add(FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-test-\(UUID().uuidString).json"))
        let store = MemoryStore(fileURL: url)
        for note in notes { _ = try? store.remember(note, source: .toldMe) }
        return store
    }
}
#endif
