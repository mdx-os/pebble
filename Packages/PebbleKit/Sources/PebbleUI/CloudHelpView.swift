import Foundation
import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The person's cloud setting, and the model each new chat gets from it.
///
/// Off by default. While it is off, or while there is no address to reach,
/// every chat gets the on-device model and no cloud code runs: the
/// transport is only made when a chat is started with the setting on.
@MainActor
public final class CloudHelp: ObservableObject {
    @Published public private(set) var settings: CloudHelpSettings
    @Published var newPrivateWord = ""
    /// What to say about the last change that couldn't be made. Every new
    /// line, even one the same as before, bumps statusCount so it is spoken
    /// again, in the window that asked for the change (`statusWindow`).
    @Published private(set) var state: Status? {
        didSet {
            fromLaunch = false
            if state != nil {
                statusWindow = speaker
                statusCount += 1
            }
        }
    }
    /// The words of `state`.
    var status: String? { state?.line }
    /// True while `state` is still the one set at launch. Cleared by every
    /// later change.
    private var fromLaunch = false
    @Published private(set) var statusCount = 0

    /// A status line, and whether it says a switch off is still to be
    /// saved, decided where it is set rather than by its words.
    enum Status: Equatable {
        /// Each says a switch off waits to be saved, so it goes once that
        /// save is made (`refresh`).
        case offForNow, offUntilUnlocked, offSavedLater, offAtLaunchNotSaved
        /// Any other line.
        case said(String)

        var line: String {
            switch self {
            case .offForNow: CloudWords.offForNow
            case .offUntilUnlocked: CloudWords.offUntilUnlocked
            case .offSavedLater: CloudWords.offSavedLater
            case .offAtLaunchNotSaved: CloudWords.offAtLaunchNotSaved
            case .said(let line): line
            }
        }

        var waitsForASave: Bool {
            if case .said = self { false } else { true }
        }
    }

    /// The line for the home screen when launch couldn't save a stale yes
    /// off, nor mark it off. The person asked for nothing, so they would
    /// never open the setting to hear it. Gone once the save is made or
    /// anything else is said.
    var launchNotice: String? {
        fromLaunch && state == .offAtLaunchNotSaved ? state?.line : nil
    }
    /// True once the launch line has been announced.
    private var launchAnnounced = false

    /// True the first time it is asked while there is a launch line, so
    /// the home screen announces it once per launch, however often it
    /// comes back to the front.
    func claimLaunchAnnouncement() -> Bool {
        guard launchNotice != nil, !launchAnnounced else { return false }
        launchAnnounced = true
        return true
    }
    /// The window whose action the status answers. One setting serves every
    /// window, so only that one speaks it. Nil when no window acted, as for
    /// a line from launch or from the memory screen: then every window
    /// showing the setting speaks it. See `CloudHelpView.speaks`.
    private(set) var statusWindow: UUID?
    /// The window acting now, set only for the length of `act`.
    private(set) var speaker: UUID?
    /// True while private words may be kept that `settings` doesn't show:
    /// the file couldn't be read, or couldn't be opened at launch but can
    /// still be erased. Forget everything names them then too.
    @Published private(set) var mayKeepUnseenWords: Bool
    // No window's place lives here: one setting serves every window, each
    // with its own open chat. Each `CloudHelpView` is given its window's
    // flag instead, so one window never speaks for another.

    public let endpoint: URL?
    /// False when the file that keeps the setting and the private words
    /// couldn't be opened at launch. Nothing typed here could be kept, so
    /// the setting stays off and says so.
    public let storeOpened: Bool
    /// The same store the memory screen uses, so the redactor always reads
    /// the notes as they are now. The app reads its notes store from here,
    /// so the two can never be different stores.
    public let memory: MemoryStore?
    private let store: any CloudHelpStoring
    private let auth: any CloudAuth
    private let makeTransport: @Sendable () -> any CloudTransport
    /// The file a setting that couldn't be opened would have read.
    private let unopenedFile: (@Sendable () throws -> any CloudHelpStoring)?
    /// Every chat's preview gate, so turning the cloud off closes them all.
    private let reviews = NSHashTable<CloudReview>.weakObjects()
    /// Every cloud chat's session and every cloud chat on screen, so Forget
    /// everything can end them all (`endOpenCloudChats`).
    private let sessions = NSHashTable<CloudChatSession>.weakObjects()
    private let openChats = NSHashTable<ChatController>.weakObjects()
    /// How many chats have asked for a model, so tests can see that a
    /// rebuilt home screen asks for none.
    private(set) var chatModelsAsked = 0
    /// Set when the person turns the cloud off, and cleared only by their
    /// yes to turning it on again. While set, nothing is sent from any
    /// chat whatever the saved file says, so a save that fails can never
    /// leave it on. Also set at launch when a stale on could be neither
    /// saved off nor erased.
    private let switchedOff = SessionFlag()
    /// Set once anything has been handed to the cloud this session, so
    /// Forget everything never claims a copy that already left is gone.
    private let sent = SessionFlag()
    /// Reads the settings again once a locked device is unlocked, so a
    /// switch off that couldn't be saved is saved then.
    private var unlockWatch: AnyCancellable?

    /// True once anything has been handed to the cloud since launch.
    public var anythingSentThisSession: Bool { sent.value }

    public convenience init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        auth: any CloudAuth = NoCloudAuth(),
        transport: @escaping @Sendable () -> any CloudTransport = { URLSessionCloudTransport() }
    ) {
        self.init(store: store, endpoint: endpoint, memory: memory, auth: auth, transport: transport,
                  storeOpened: true, unopenedFile: nil)
    }

    private init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        auth: any CloudAuth,
        transport: @escaping @Sendable () -> any CloudTransport,
        storeOpened: Bool,
        unopenedFile: (@Sendable () throws -> any CloudHelpStoring)?
    ) {
        self.store = store
        self.endpoint = endpoint
        self.storeOpened = storeOpened
        self.memory = memory
        self.auth = auth
        self.makeTransport = transport
        self.unopenedFile = unopenedFile
        var read = storeOpened ? try? store.load() : nil
        // A saved on counts only for the address it was said yes to. With
        // no address in this build, another one, or none saved with it, it
        // is off, and saved off, so no build turns it back on without a
        // fresh yes. If that can't be saved, the private words are kept
        // (nothing is erased behind the person's back), every send is held
        // off until the app closes, the file is marked off if it can be,
        // and the person is told; `refresh` tries the save again.
        var holdsOff = false
        var launchStatus: Status?
        if var stale = read, stale.isOn, !stale.isOn(for: endpoint) {
            stale.turnOff()
            read = stale
            if (try? store.save(stale)) == nil {
                holdsOff = true
                launchStatus = (try? store.markOff()) != nil ? .offSavedLater : .offAtLaunchNotSaved
            }
        }
        settings = read ?? .off
        mayKeepUnseenWords = storeOpened ? read == nil : unopenedFile != nil
        if holdsOff { switchedOff.value = true }
        // Set once every stored property is in place, so `didSet` runs and
        // the line is counted like any other. Marked as launch's after, as
        // `didSet` clears that.
        state = launchStatus
        fromLaunch = launchStatus != nil
        // The system posts it on the main thread; anything else hops there.
        unlockWatch = NotificationCenter.default.publisher(for: Self.unlocked).sink { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Posted when a locked device is unlocked and its protected files can
    /// be read again.
    static var unlocked: Notification.Name {
        #if os(iOS)
        UIApplication.protectedDataDidBecomeAvailableNotification
        #else
        // Nothing posts this on a Mac, which keeps no file locked away
        // while the app runs, so there the watch never fires; only tests
        // post it, to stand in for the iPhone's. A plain name, with no
        // product or code name in it.
        Notification.Name("CloudHelp.unlocked")
        #endif
    }

    /// The one setting the app holds, made the way the app makes it: kept
    /// next to the notes when both open, or else the setting that couldn't
    /// be opened, which can still erase words kept from an earlier launch.
    /// `memory` is carried either way, with or without an address, so the
    /// memory screen always reads the same notes store the redactor does.
    /// `auth` is carried either way too, so Forget everything tells sign-in
    /// to forget even when the setting couldn't be opened.
    public static func forApp(memory: MemoryStore?, endpoint: URL?, auth: any CloudAuth = NoCloudAuth(),
                              openStore: @escaping @Sendable () throws -> any CloudHelpStoring) -> CloudHelp {
        if memory != nil, let store = try? openStore() {
            return CloudHelp(store: store, endpoint: endpoint, memory: memory, auth: auth)
        }
        return couldNotOpen(endpoint: endpoint, memory: memory, auth: auth, file: openStore)
    }

    /// The setting when its file couldn't be opened at launch. It reads as
    /// off and can't be turned on, so no private word is ever typed into
    /// something that would quietly forget it, and no chat uses the cloud.
    ///
    /// `file` reaches the file it would have read, so private words kept
    /// there from an earlier launch can still be erased. See
    /// `forgetPrivateWords`. `auth` is never asked to sign in from here,
    /// since no chat uses the cloud, but it is told to forget, in case it
    /// kept something from an earlier launch.
    public static func couldNotOpen(endpoint: URL?, memory: MemoryStore?, auth: any CloudAuth = NoCloudAuth(),
                                    file: (@Sendable () throws -> any CloudHelpStoring)? = nil) -> CloudHelp {
        CloudHelp(store: InMemoryCloudHelpStore(), endpoint: endpoint, memory: memory, auth: auth,
                  transport: { URLSessionCloudTransport() }, storeOpened: false, unopenedFile: file)
    }

    /// What erasing the private words did, for the memory screen shown
    /// when the notes won't open.
    enum WordsErased: Equatable {
        case erased
        /// Erased with the whole setting, so the cloud is off now.
        case erasedWithCloud
        /// They couldn't be erased, so they are still kept.
        case stayed
    }

    /// Erases the private words when the notes won't open, as the memory
    /// screen in their place does along with the tasks, the same way
    /// Forget everything does.
    func eraseWordsWithoutNotes() -> WordsErased {
        switch try? forgetPrivateWords() {
        case .privateWords?: .erased
        case .privateWordsAndCloud?: .erasedWithCloud
        case nil: .stayed
        }
    }

    /// True when Forget everything may erase private words: some are
    /// shown, or some may be kept that couldn't be read.
    var mayHavePrivateWords: Bool {
        !settings.privateWords.isEmpty || mayKeepUnseenWords
    }

    /// False when no address is set up, or the setting's file couldn't be
    /// opened. The setting then stays off.
    public var isAvailable: Bool { endpoint != nil && storeOpened }

    /// The address, only while the setting can be used. Every choice of
    /// model goes through this, so an unopened file means no cloud.
    private var usableEndpoint: URL? { storeOpened ? endpoint : nil }

    /// True when a new chat would use the cloud model.
    public var usesCloudForNewChats: Bool {
        ModelChoice.usesCloud(settings: settings, endpoint: usableEndpoint)
    }

    /// Whether a new chat's model runs on this device, without making it.
    public func runsOnDevice(local: any ModelClient) -> Bool {
        privacyPlace(local: local).staysOnDevice
    }

    /// The `privacyPlace` of the model a new chat would get, without making
    /// it. See `PrivacyPlace` for how this joins the open chat's.
    public func privacyPlace(local: any ModelClient) -> PrivacyPlace {
        privacyPlace(local: local, settings: settings)
    }

    /// The same, for `settings` about to be set, as `$settings` sends them.
    func privacyPlace(local: any ModelClient, settings: CloudHelpSettings) -> PrivacyPlace {
        ModelChoice.privacyPlace(settings: settings, endpoint: usableEndpoint, local: local)
    }

    /// The model for a new chat: `local` unless the cloud is on. A cloud
    /// chat asks the person through `review`, which belongs to that chat
    /// alone, so one window's preview never shows in another.
    public func chatModel(local: any ModelClient, review: CloudReview) -> any ModelClient {
        chatModelsAsked += 1
        return ModelChoice.model(settings: settings, endpoint: usableEndpoint, local: local) { url in
            reviews.add(review)
            let store = self.store
            let memory = self.memory
            let switchedOff = self.switchedOff
            let sent = self.sent
            let session = CloudChatSession(handingOver: { sent.value = true })
            sessions.add(session)
            return CloudModel(
                endpoint: url, transport: makeTransport(), reviewer: review, auth: auth,
                // Read fresh for each reply, on this device, so new notes
                // and private words count right away. Notes or words that
                // can't be read mean nothing is sent.
                redactor: {
                    guard let memory else { throw MemoryStore.Unavailable() }
                    switch memory.contents() {
                    case .notes(let notes): return Redactor(memory: notes, privateWords: try store.load().privateWords)
                    case .unreadable: throw MemoryStore.Unreadable()
                    case .unavailable: throw MemoryStore.Unavailable()
                    }
                },
                // On only when the file says so for this very address and
                // the person hasn't switched it off since. A file that
                // can't be read throws, so the chat says so rather than
                // that it was turned off.
                isOn: { try !switchedOff.value && store.load().isOn(for: url) },
                session: session
            )
        }
    }

    /// A cloud chat now on screen, so Forget everything can end it too.
    func opened(_ chat: ChatController) {
        openChats.add(chat)
    }

    /// What Forget everything does first, before anything is erased: every
    /// open cloud chat ends. A reply under way and any send still on the
    /// wire are cancelled, waiting previews close unsent, and each chat
    /// drops its turns and everything it hid so far, so none of the words
    /// being erased are left in a chat. The home screen then starts a
    /// fresh chat in its place.
    ///
    /// True when something was handed to the cloud this session, a send
    /// cancelled here included: that copy may already have left, and
    /// nothing here can erase it, so Forget everything must say so.
    ///
    /// A chat that holds nothing yet, such as the fresh one started in an
    /// ended chat's place, has nothing to let go of and is left open.
    @discardableResult
    func endOpenCloudChats() -> Bool {
        for chat in openChats.allObjects where chat.holdsAnything { chat.end() }
        for session in sessions.allObjects where session.holdsAnything { session.end() }
        withdrawPreviews()
        return sent.value
    }

    /// True while every send is held off for this session, as after a
    /// switch off, or a stale yes that could be neither saved off nor
    /// erased at launch.
    var holdsSendsOff: Bool { switchedOff.value }

    /// Reads the settings again, as after the device was locked at launch,
    /// or once it is unlocked (`unlocked`). A switch off that couldn't be
    /// saved before is saved now, if it can be, and the line that said it
    /// would be goes.
    func refresh() {
        guard storeOpened, var fresh = try? store.load() else { return }
        let waiting = state?.waitsForASave ?? false
        // A marked off reads as off, so the line says whether it waits.
        if switchedOff.value, fresh.isOn || waiting {
            fresh.turnOff()
            if (try? store.save(fresh)) != nil, waiting { state = nil }
        }
        settings = fresh
        mayKeepUnseenWords = false
    }

    /// Does `action` on the shared setting as `window`, so a line it sets
    /// is spoken there. The speaker is cleared after, so a line set any
    /// other way is never pinned to the last window that acted.
    func act(as window: UUID, _ action: (CloudHelp) -> Void) {
        speaker = window
        defer { speaker = nil }
        action(self)
    }

    /// The toggle. Turning on asks first; turning off never does. True
    /// when the question should show, in the window whose toggle it was
    /// only, so it never opens in every window with the setting open.
    @discardableResult
    func setOn(_ on: Bool) -> Bool {
        if on { return isAvailable && !usesCloudForNewChats }
        turnOff()
        return false
    }

    /// The yes to the turn on question, for this build's address only.
    /// Nothing reaches the network here: a sign-in, if the cloud needs one,
    /// is a hop in the first preview, sent only by that preview's yes.
    func confirmTurnOn() {
        guard isAvailable, let endpoint else { return }
        let wasSwitchedOff = switchedOff.value
        switchedOff.value = false
        guard update({ $0.turnOn(for: endpoint) }).isDone else {
            // Still off, and still off for chats already open.
            switchedOff.value = wasSwitchedOff
            settings.turnOff()
            state = .said(CloudWords.onNotSaved)
            return
        }
        state = nil
    }

    /// Off at once for every chat, before anything is saved: every cloud
    /// chat's session ends (`CloudChatSession.end(because: .off)`), which
    /// cancels any send on the wire and refuses a sign-in answer that lands
    /// later, and only then does sign-in let go of whatever it kept, so no
    /// late answer is kept after it. Then it is saved, tried twice. If the
    /// device is only locked the words are kept, and the file is marked off
    /// (`CloudHelpStoring.markOff`), so it reads as off even after a
    /// relaunch; `refresh` saves the rest once the file opens again. If the
    /// save fails because the file is damaged, or the disk, it is erased,
    /// since no file reads as off on the next launch; if that fails too it
    /// is marked off. Only when nothing holds could it read as on next
    /// time, and the person is told so, locked or not.
    func turnOff() {
        switchedOff.value = true
        settings.turnOff()
        for session in sessions.allObjects { session.end(because: .off) }
        withdrawPreviews()
        auth.forget()
        let first = update { $0.turnOff() }
        if first.isDone || update({ $0.turnOff() }).isDone {
            state = nil
        } else if first == .locked {
            state = (try? store.markOff()) != nil ? .offUntilUnlocked : .offForNow
        } else if (try? store.erase()) != nil {
            settings = .off
            state = .said(CloudWords.offButCleared)
        } else {
            state = (try? store.markOff()) != nil ? .offSavedLater : .offForNow
        }
    }

    /// A preview waiting for a yes was redacted with the private words as
    /// they were. Once they change it is no longer what would be hidden, so
    /// it is withdrawn and nothing goes; the next send shows a fresh one.
    private func withdrawPreviews() {
        for review in reviews.allObjects { review.cancelPending() }
    }

    /// Refused when the setting couldn't be opened: its store is only in
    /// memory, and would forget the word.
    func addPrivateWord() {
        guard storeOpened else { return }
        let word = newPrivateWord
        var refusal: CloudHelpSettings.Refusal?
        let outcome = update { refusal = $0.refusal(for: word); _ = $0.addPrivateWord(word) }
        if outcome.isDone, let refusal {
            // Said out loud, so a refused word is never met with silence.
            // One already hidden needs nothing more, so the field clears.
            if refusal == .alreadyThere { newPrivateWord = "" }
            state = CloudWords.privateRefused(refusal).map(Status.said)
            return
        }
        switch outcome {
        case .saved: newPrivateWord = ""; state = nil; withdrawPreviews()
        case .unchanged: break
        case .unreadable: state = .said(CloudWords.privateUnreadable)
        case .locked: state = .said(CloudWords.privateLocked)
        case .notSaved: state = .said(CloudWords.privateNotSaved)
        }
    }

    func removePrivateWord(_ word: String) {
        switch update({ $0.removePrivateWord(word) }) {
        case .saved: state = nil; withdrawPreviews()
        case .unchanged: break
        case .unreadable: state = .said(CloudWords.privateUnreadable)
        case .locked: state = .said(CloudWords.privateLocked)
        case .notSaved: state = .said(CloudWords.privateNotSaved)
        }
    }

    /// What Forget everything erased of the cloud setting.
    enum Forgot: Equatable {
        /// The private words, with the setting left as it was.
        case privateWords
        /// The whole setting, to be sure the words went, so the cloud is
        /// off now when it was on, or might have been.
        case privateWordsAndCloud
    }

    /// Erases the private words, as Forget everything does, and any word
    /// half typed into the field. The setting itself stays as it was,
    /// unless the words can't be read or saved without them: then the
    /// whole file is erased, which also turns the cloud off, and the answer
    /// says so. Throws only when even that fails.
    ///
    /// A setting that couldn't be opened at launch keeps nothing itself, so
    /// it erases the whole file it would have read, the only place words
    /// from an earlier launch can be. It throws if that can't be reached or
    /// erased, so Forget everything never says they went when they didn't.
    @discardableResult
    func forgetPrivateWords() throws -> Forgot {
        // First, whatever happens to the file: no open chat keeps a copy,
        // and sign-in keeps nothing it learned.
        endOpenCloudChats()
        auth.forget()
        newPrivateWord = ""
        guard storeOpened else { return try eraseUnopenedFile() }
        let current = try? store.load()
        if var current {
            current.privateWords = []
            if switchedOff.value { current.turnOff() }
            if (try? store.save(current)) != nil {
                let hadWords = !settings.privateWords.isEmpty
                settings = current
                mayKeepUnseenWords = false
                // What waits was hidden with words that are gone now.
                if hadWords { withdrawPreviews() }
                return .privateWords
            }
        }
        // Unread, it may have said on.
        let mightHaveBeenOn = current?.isOn ?? true
        try store.erase()
        settings = .off
        mayKeepUnseenWords = false
        guard mightHaveBeenOn, !switchedOff.value else {
            withdrawPreviews()
            return .privateWords
        }
        // Off for chats already open, as a switch off is.
        switchedOff.value = true
        withdrawPreviews()
        return .privateWordsAndCloud
    }

    /// `forgetPrivateWords` for a setting that couldn't be opened. The
    /// setting already reads as off here; if the file said on, or can't be
    /// read, it reads as off next launch too, and the answer says so.
    private func eraseUnopenedFile() throws -> Forgot {
        // Nothing to reach means nothing was ever kept, as in tests.
        guard let unopenedFile else { return .privateWords }
        let file = try unopenedFile()
        let mightHaveBeenOn = (try? file.load())?.isOn ?? true
        try file.erase()
        // Nothing should be held here, but if anything was, it goes too,
        // so the list on screen is as empty as the file.
        try? store.erase()
        settings = .off
        mayKeepUnseenWords = false
        return mightHaveBeenOn ? .privateWordsAndCloud : .privateWords
    }

    enum Outcome {
        /// `unreadable` is damaged. `locked` can't be opened now, as on a
        /// locked device, and may open later.
        case saved, unchanged, unreadable, locked, notSaved
        /// The file now says what was asked.
        var isDone: Bool { self == .saved || self == .unchanged }
    }

    /// Changes the saved settings, read fresh so words saved elsewhere or
    /// unreadable at launch are never written over. A switch off made in
    /// this session is kept in whatever is saved.
    private func update(_ change: (inout CloudHelpSettings) -> Void) -> Outcome {
        let before: CloudHelpSettings
        do {
            before = try store.load()
        } catch is MemoryStore.Unavailable {
            return .locked
        } catch {
            return .unreadable
        }
        mayKeepUnseenWords = false
        var next = before
        if switchedOff.value { next.turnOff() }
        change(&next)
        guard next != before else {
            settings = next
            return .unchanged
        }
        do {
            try store.save(next)
        } catch {
            return .notSaved
        }
        settings = next
        return .saved
    }
}

/// A flag for this launch, read by every chat off the main actor.
final class SessionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Holds a chat's preview on screen until the person sends it or not.
///
/// `CloudModel` waits here before every request. The sheet reads `pending`,
/// shows its exact bytes, and answers for that preview by its id. Going
/// away without an answer, the chat screen leaving, or the reply being
/// stopped all count as not sending.
@MainActor
public final class CloudReview: ObservableObject, CloudReviewing {
    @Published public private(set) var pending: CloudPreview?
    private var waiting: CheckedContinuation<CloudConsent, Never>?
    private var watchers: [CheckedContinuation<CloudPreview, Never>] = []

    public init() {}

    public func review(_ preview: CloudPreview) async -> CloudConsent {
        if Task.isCancelled { return .cancel }
        // Only one question at a time; an older one is not sent.
        cancelPending()
        let id = preview.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                pending = preview
                let watchers = self.watchers
                self.watchers = []
                for watcher in watchers { watcher.resume(returning: preview) }
            }
        } onCancel: {
            Task { @MainActor in self.answer(.cancel, for: id) }
        }
    }

    /// The person's answer to the preview with `id`, the one they saw. An
    /// answer meant for any other preview is ignored, so a tap can never
    /// send something that wasn't on screen.
    public func answer(_ consent: CloudConsent, for id: UUID) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        let waiting = self.waiting
        self.waiting = nil
        waiting?.resume(returning: consent)
    }

    /// Sends nothing for whatever is waiting.
    public func cancelPending() {
        if let id = pending?.id { answer(.cancel, for: id) }
    }

    /// Waits until a preview is on screen, with no timing involved. For tests.
    package func shown() async -> CloudPreview {
        if let pending { return pending }
        return await withCheckedContinuation { watchers.append($0) }
    }

    /// Puts a preview on screen with nothing waiting on it, for screenshots.
    package func show(_ preview: CloudPreview) {
        assert(self !== Self.none, "the gate with no cloud chat never shows anything")
        pending = preview
    }

    /// The gate a screen with no cloud chat watches. No model asks through
    /// it, so it never has anything to show.
    static let none = CloudReview()
}

/// The cloud setting: off by default, with the words always hidden.
public struct CloudHelpView: View {
    @ObservedObject var help: CloudHelp
    /// This window's flag, from its own open chat and next one (see
    /// `HomeView.surfacePlace`). Without one it makes no promise.
    let place: PrivacyPlace
    /// The turn on question, for this window only.
    @State private var asksToTurnOn: Bool
    /// This window, so a status line is spoken only where it was asked for.
    @State private var window = UUID()
    @Environment(\.colorScheme) private var scheme

    public init(help: CloudHelp, place: PrivacyPlace = .mayLeaveDevice) {
        self.init(help: help, place: place, asking: false)
    }

    /// `asking` opens on the turn on question, for screenshots.
    init(help: CloudHelp, place: PrivacyPlace, asking: Bool) {
        self.help = help
        self.place = place
        _asksToTurnOn = State(initialValue: asking)
    }

    /// The add button, at least the size a finger needs.
    static let addButtonSize: CGFloat = 44

    public var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(CloudWords.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    switchCard
                    policyCard
                    privateWordsCard
                    if let status = help.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { help.refresh() }
        // Counted, so the same line twice in a row is spoken twice. Only in
        // the window that acted, so a Mac or iPad with the setting open in
        // two windows hears it once.
        .onChange(of: help.statusCount) {
            if let status = help.status, Self.speaks(help.statusWindow, in: window) {
                AccessibilityNotification.Announcement(status).post()
            }
        }
        .sheet(isPresented: $asksToTurnOn) {
            CloudTurnOnSheet(onYes: { asksToTurnOn = false; act { $0.confirmTurnOn() } },
                             onNo: { asksToTurnOn = false })
        }
    }

    /// Whether the window `window` speaks a status line that answers
    /// `origin`'s action. With no origin, no window acted, so every window
    /// showing the setting speaks it rather than none.
    static func speaks(_ origin: UUID?, in window: UUID) -> Bool { origin == nil || origin == window }

    /// Does `action` on the shared setting as this window.
    private func act(_ action: (CloudHelp) -> Void) {
        help.act(as: window, action)
    }

    /// What the setting says under its switch, in the window whose flag
    /// is `place`.
    static func detail(for help: CloudHelp, place: PrivacyPlace) -> String {
        if !help.storeOpened { return CloudWords.couldNotOpen }
        if !help.isAvailable { return CloudWords.unavailable }
        return help.usesCloudForNewChats ? CloudWords.onDetail : CloudWords.offDetail(place)
    }

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What new chats get, so a saved on with nowhere to go never
            // reads as on.
            Toggle(isOn: Binding(get: { help.usesCloudForNewChats }, set: { on in act { asksToTurnOn = $0.setOn(on) } })) {
                Label(CloudWords.toggleTitle, systemImage: help.usesCloudForNewChats ? "cloud.fill" : "lock.fill")
                    .font(.body.weight(.semibold))
            }
            .toggleStyle(.switch)
            .tint(Theme.accentText)
            .disabled(!help.isAvailable)
            .accessibilityIdentifier("cloudToggle")
            Text(Self.detail(for: help, place: place))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(scheme)
    }

    /// Who runs the server, what it keeps and what signing in sends, in the
    /// words of `CloudPolicy`, the policy a build that ships was checked
    /// against.
    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CloudWords.policyTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(Self.policyLines.enumerated()), id: \.offset) { index, line in
                Label {
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.policySymbols[index % Self.policySymbols.count])
                        .foregroundStyle(Theme.accentSymbol)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(scheme)
        .accessibilityIdentifier("cloudPolicy")
    }

    /// The lines the policy card shows, from `CloudPolicy` alone.
    static var policyLines: [String] { CloudWords.policyLines }
    private static let policySymbols = ["building.2", "chart.bar", "person.badge.key", "arrow.uturn.backward"]

    private var privateWordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CloudWords.privateTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(CloudWords.privateDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                PrivateWordField(word: $help.newPrivateWord) { act { $0.addPrivateWord() } }
                AddPrivateWordButton(size: Self.addButtonSize) { act { $0.addPrivateWord() } }
                    .disabled(!Self.canAdd(help.newPrivateWord))
            }
            // Nothing typed here could be kept when the file didn't open.
            .disabled(!help.storeOpened)
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(Theme.fieldTint), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
            PrivateWordList(words: help.settings.privateWords) { word in act { $0.removePrivateWord(word) } }
        }
        .padding(16)
        .card(scheme)
    }

    /// Only words can be added, not blank space.
    static func canAdd(_ word: String) -> Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The launch line (`CloudHelp.launchNotice`) at the top of Today, so a
/// person who never opens the setting still hears it. Announced the first
/// time it appears in this launch, and gone once the save is made.
struct CloudLaunchNotice: View {
    @ObservedObject var help: CloudHelp

    var body: some View {
        if let line = help.launchNotice {
            GentleNotice(text: line)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
                // One element that reads the line, nothing else.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line)
                .accessibilityIdentifier("cloudLaunchNotice")
                // Today comes back to the front often; the line is said
                // the first time only.
                .onAppear { if help.claimLaunchAnnouncement() { AccessibilityNotification.Announcement(line).post() } }
        }
    }
}

/// The round add button beside the private word field. With nothing typed
/// it can't be pressed, and it looks it: a quiet gray outline on the field
/// itself, rather than the accent it has when ready. A gray fill stacked on
/// the field would sink the gray below 4.5 to 1 in dark.
struct AddPrivateWordButton: View {
    let size: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.headline)
                .foregroundStyle(Self.symbolStyle(enabled: isEnabled))
                .frame(width: size, height: size)
                .background(Self.fill(enabled: isEnabled), in: Circle())
                .overlay(Circle().stroke(isEnabled ? Color.clear : Theme.hairline(scheme)))
                .pointerHover(in: Circle())
        }
        .buttonStyle(.plain)
        .help(CloudWords.privateAdd)
        .accessibilityLabel(CloudWords.privateAdd)
    }

    static func symbolStyle(enabled: Bool) -> AnyShapeStyle {
        enabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText)
    }

    static func fill(enabled: Bool) -> AnyShapeStyle {
        // Disabled, it shows the field it sits in: secondaryText on "field
        // on the card", a pair `Theme.textPairs` already checks.
        enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear)
    }
}

/// What the system hides on screens marked private: nothing while the app
/// is in use, and everything marked private once it isn't, so the app
/// switcher's picture never shows private words or a payload.
func privateRedaction(_ phase: ScenePhase) -> RedactionReasons {
    phase == .active ? [] : .privacy
}

/// Where a new private word is typed. What is half typed is as private as
/// the list, so it hides the same way.
struct PrivateWordField: View {
    @Binding var word: String
    let onSubmit: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextField(CloudWords.privatePlaceholder, text: $word)
            .textFieldStyle(.plain)
            // The keyboard never learns or suggests private words.
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(onSubmit)
            // Hidden wherever the system hides private things, and in the
            // app switcher.
            .privacySensitive()
            .redacted(reason: privateRedaction(scenePhase))
    }
}

/// The words always hidden, each with a way to stop hiding it.
struct PrivateWordList: View {
    let words: [String]
    let onRemove: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(words, id: \.self) { word in
                HStack {
                    Label(word, systemImage: "eye.slash")
                        .font(.body)
                    Spacer(minLength: 8)
                    Button { onRemove(word) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .help(CloudWords.privateRemove(word))
                    .accessibilityLabel(CloudWords.privateRemove(word))
                }
            }
        }
        // Hidden wherever the system hides private things, and in the app
        // switcher.
        .privacySensitive()
        .redacted(reason: privateRedaction(scenePhase))
    }
}

/// The row on the memory screen that opens the cloud setting. It is the only
/// way in; see `HomeView.memoryScreen` for when memory can't open.
struct CloudHelpRow: View {
    @ObservedObject var help: CloudHelp
    /// This window's flag, passed on to the setting.
    let place: PrivacyPlace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink {
            CloudHelpView(help: help, place: place)
        } label: {
            HStack(spacing: 12) {
                // What new chats get, as the toggle reads.
                Image(systemName: help.usesCloudForNewChats ? "cloud.fill" : "lock.fill")
                    .foregroundStyle(Theme.accentSymbol)
                    .frame(width: 24)
                    // Decoration: "On" or "Off" beside it says the same.
                    .accessibilityHidden(true)
                Text(CloudWords.rowTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(help.usesCloudForNewChats ? CloudWords.rowOn : CloudWords.rowOff)
                    .foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .card(scheme)
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerHover(in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityIdentifier("cloudRow")
    }
}

/// The question before the cloud is turned on, saying in plain words what
/// changes.
struct CloudTurnOnSheet: View {
    let onYes: () -> Void
    let onNo: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent, in: Circle())
                    .accessibilityHidden(true)
                Text(CloudWords.askQuestion)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(CloudWords.askPoints.enumerated()), id: \.offset) { index, point in
                        Label {
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Self.symbols[index % Self.symbols.count])
                                .foregroundStyle(Theme.accentSymbol)
                        }
                        .font(.body)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(scheme)
                VStack(spacing: 6) {
                    Button(CloudWords.askYes, action: onYes)
                        .buttonStyle(PrimaryButtonStyle())
                    Button(CloudWords.askNo, action: onNo)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private static let symbols = ["cloud", "eye", "eye.slash", "arrow.triangle.2.circlepath", "person.crop.circle",
                                  "key", "lock.shield", "lock", "network", "building.2", "chart.bar",
                                  "person.badge.key", "heart", "arrow.uturn.backward"]
}

/// "Here is what leaves your device": the request, its address, headers and
/// body, with what was taken out marked and every sign-in value covered,
/// and a choice to send it or not.
struct CloudPreviewSheet: View {
    let preview: CloudPreview
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Everything that will be sent, as it goes: any sign-in hop, then the
    /// request, Host and Content-Length included.
    static func shownText(_ preview: CloudPreview) -> String { preview.shownText }

    /// What the payload card draws: `shownText`, with every sign-in value
    /// covered, so a screenshot or a shared screen never catches a secret.
    /// What is covered, the same way on the card and aloud
    /// (`spokenLines`):
    /// - in every hop, the value of each sign-in label (`isSignIn`); the
    ///   method, address, fixed labels, Host and Content-Length show;
    /// - the sign-in hop's whole body, but for the name of each part when
    ///   it is a JSON object (`maskedSignInBody`);
    /// - nothing of the message's body, which is the redacted chat.
    /// The names still show, so the person sees that a value goes and
    /// under what name. The sheet says the values are covered
    /// (`CloudWords.previewSignInCovered`).
    static func displayedText(_ preview: CloudPreview) -> String {
        func shown(_ request: CloudRequest, isSignInHop: Bool) -> String {
            let lines = CloudRequest.shownHeaders(url: request.url, headers: request.headers, body: request.body).map {
                "\($0.name): " + (isSignIn($0.name, $0.value) ? signInMask : $0.value)
            }
            return ([request.method + " " + request.url.absoluteString] + lines).joined(separator: "\n")
                + "\n\n" + (isSignInHop ? maskedSignInBody(request.body) : request.text)
        }
        guard let signIn = preview.signIn else { return shown(preview.request, isSignInHop: false) }
        return CloudWords.previewSignInFirst + "\n" + shown(signIn, isSignInHop: true) + "\n\n"
            + CloudWords.previewThenMessage + "\n" + shown(preview.request, isSignInHop: false)
    }

    /// What covers a sign-in value on the card. Always the same length, so
    /// it says nothing of the value's.
    static let signInMask = String(repeating: "\u{2022}", count: 8)

    /// The names of a sign-in body's parts, in name order, when it is a
    /// JSON object whose names are all tokens (`CloudSignIn.isToken`). Nil
    /// for any other body, so a name is never drawn that could make a line
    /// of its own. `CloudModel.preview` already refuses such a body; this
    /// keeps the card safe without leaning on that.
    static func signInBodyNames(_ body: Data) -> [String]? {
        guard let names = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?.keys.sorted(),
              names.allSatisfy(CloudSignIn.isToken) else { return nil }
        return names
    }

    /// A sign-in body as the card shows it: each part's name with its value
    /// covered, or one mask for a body that isn't a JSON object. Empty
    /// stays empty, since nothing is hidden.
    static func maskedSignInBody(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        guard let names = signInBodyNames(body) else { return signInMask }
        return "{\n" + names.map { "  \"\($0)\" : " + signInMask }.joined(separator: ",\n") + "\n}"
    }

    /// A label that is neither fixed nor one the system adds is sign-in,
    /// and its value is a secret.
    static func isSignIn(_ name: String, _ value: String) -> Bool {
        CloudHeaders.fixed[name] != value && CloudRequest.systemLines[name] != value
            && name != "Host" && name != "Content-Length"
    }

    /// True when the card covers anything: a sign-in hop, or a sign-in
    /// label on the message. The sheet then says what is covered.
    static func coversAnything(_ preview: CloudPreview) -> Bool {
        preview.signIn != nil || preview.request.headers.contains { isSignIn($0.key, $0.value) }
    }

    /// Who runs the server and what it keeps, from `CloudPolicy` alone.
    static var policyLine: String { CloudWords.previewPolicy }

    static func hiddenLine(_ preview: CloudPreview) -> String {
        let parts = Redaction.Kind.allCases.compactMap { kind in
            preview.hidden[kind].map { kind.counted($0) }
        }
        return parts.isEmpty ? CloudWords.previewNothingHidden : CloudWords.previewHidden(parts)
    }

    /// What VoiceOver reads instead of the raw text: where it goes, the
    /// labels, then each message by who said it, with masks read as
    /// "hidden name" and the like.
    /// Whenever the card covers anything, VoiceOver hears that it does, as
    /// the sheet's line says: under "First, to sign in" with a hop, or
    /// first of all when only the message has a sign-in label.
    static func spokenLines(_ preview: CloudPreview) -> [String] {
        guard let signIn = preview.signIn else {
            let covered = coversAnything(preview) ? [CloudWords.previewSignInCovered] : []
            return covered + spokenLines(preview.request, isSignInHop: false)
        }
        return [CloudWords.previewSignInFirst, CloudWords.previewSignInCovered]
            + spokenLines(signIn, isSignInHop: true)
            + [CloudWords.previewThenMessage] + spokenLines(preview.request, isSignInHop: false)
    }

    private static func spokenLines(_ request: CloudRequest, isSignInHop: Bool) -> [String] {
        var lines = [CloudWords.spokenAddress(request.url.absoluteString)]
        // A fixed label, or one the system adds, is read in full. Any other
        // is sign-in, whose value is a secret: VoiceOver says only that it
        // is hidden, so neither it nor its length is ever spoken aloud.
        let labels = CloudRequest.shownHeaders(url: request.url, headers: request.headers, body: request.body).map {
            isSignIn($0.name, $0.value) ? CloudWords.spokenSignIn($0.name) : "\($0.name), \($0.value)"
        }
        if !labels.isEmpty { lines.append(CloudWords.spokenLabels(labels)) }
        // Every body is read, never skipped. A sign-in body is read as the
        // card covers it: the name of each part, each value hidden.
        if isSignInHop {
            if !request.body.isEmpty { lines.append(CloudWords.spokenSignInBody(signInBodyNames(request.body) ?? [])) }
        } else if let payload = try? JSONDecoder().decode(CloudPayload.self, from: request.body) {
            lines += payload.messages.map {
                CloudWords.spokenMessage(role: $0.role, text: Redaction.Kind.spoken($0.text))
            }
        } else {
            lines.append(Redaction.Kind.spoken(request.text))
        }
        return lines
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CloudWords.previewTitle)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(CloudWords.previewDetail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(CloudWords.previewDestination(preview.request.url.host ?? ""), systemImage: "arrow.up.forward.circle")
                    Label(Self.policyLine, systemImage: "building.2")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloudPreviewPolicy")
                    Label(Self.hiddenLine(preview), systemImage: "eye.slash")
                    if Self.coversAnything(preview) {
                        Label(CloudWords.previewSignInCovered, systemImage: "key")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline.weight(.medium))
                CloudPayloadCard(preview: preview)
                VStack(spacing: 6) {
                    Button(CloudWords.previewSend, action: onSend)
                        .buttonStyle(PrimaryButtonStyle())
                    Button(CloudWords.previewCancel, action: onCancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// The request itself, as plain text, with what was taken out marked.
/// VoiceOver reads it message by message instead of as raw text.
///
/// The text can't be selected or copied, and a sign-in label's value is
/// covered (`CloudPreviewSheet.displayedText`), so the secret is neither one
/// long press from the clipboard, and from there Universal Clipboard, nor
/// in a screenshot.
struct CloudPayloadCard: View {
    let preview: CloudPreview
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text(highlighted)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card(scheme)
            // Hidden wherever the system hides private things, and in the
            // app switcher.
            .privacySensitive()
            .redacted(reason: privateRedaction(scenePhase))
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    ForEach(Array(CloudPreviewSheet.spokenLines(preview).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
            .accessibilityIdentifier("cloudPayload")
    }

    /// The request with each mask tinted, so what was taken out stands out.
    private var highlighted: AttributedString {
        var text = AttributedString(CloudPreviewSheet.displayedText(preview))
        for kind in Redaction.Kind.allCases {
            var start = text.startIndex
            while let range = text[start...].range(of: kind.mask) {
                text[range].backgroundColor = Theme.accent.opacity(Theme.maskWash(scheme))
                text[range].font = .system(.footnote, design: .monospaced).weight(.bold)
                start = range.upperBound
            }
        }
        return text
    }
}

extension View {
    /// Shows `review`'s preview over this screen. Closing it any way but
    /// Send means nothing is sent.
    ///
    /// `blocked` is true while another sheet or a question is open; only
    /// one sheet can show at a time, so the preview waits, unsent, until it
    /// closes. `waiting` is told whenever a preview is pending, shown or
    /// not, so `HomeCover` can count it as covering the screen.
    ///
    /// Always the same modifier, with or without a review, so a chat
    /// changing between the device and the cloud never gives the screen
    /// under it a new identity, and its state, such as the memory screen's,
    /// survives.
    func cloudPreview(_ review: CloudReview?, blocked: Bool = false,
                      waiting: Binding<Bool>? = nil) -> ModifiedContent<Self, CloudPreviewPresenter> {
        modifier(CloudPreviewPresenter(review: review ?? CloudReview.none, blocked: blocked, waiting: waiting))
    }

    /// The usual card surface.
    func card(_ scheme: ColorScheme) -> some View {
        background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
    }
}

struct CloudPreviewPresenter: ViewModifier {
    @ObservedObject var review: CloudReview
    let blocked: Bool
    let waiting: Binding<Bool>?

    /// The preview to put on screen now: none while something else is open.
    static func shown(_ pending: CloudPreview?, blocked: Bool) -> CloudPreview? {
        blocked ? nil : pending
    }

    func body(content: Content) -> some View {
        // Swiping the sheet away only ever cancels, which is always safe.
        // Send is tied to the preview that sheet showed. A preview held back
        // by another sheet is never cancelled for it.
        content.sheet(
            item: Binding(get: { Self.shown(review.pending, blocked: blocked) },
                          set: { if $0 == nil, !blocked { review.cancelPending() } })
        ) { preview in
            CloudPreviewSheet(preview: preview,
                              onSend: { review.answer(.send, for: preview.id) },
                              onCancel: { review.answer(.cancel, for: preview.id) })
        }
        .onChange(of: review.pending?.id, initial: true) { _, id in
            waiting?.wrappedValue = id != nil
        }
    }
}
#endif
