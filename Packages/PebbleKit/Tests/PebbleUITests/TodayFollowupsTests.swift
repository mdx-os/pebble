#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI
import SourceScan

/// A monotonic clock tests can move forward.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += .milliseconds(Int64(seconds * 1000)); lock.unlock() }
}

/// Counts what the injected sleep was asked for, and moves the clock.
private final class Naps {
    var count = 0
}

/// Counts calls from a `@Sendable` hook. Main actor bound, so it is
/// Sendable and the hook changes it only on the main actor.
@MainActor
private final class Tally {
    var count = 0
}

/// The composer on Today, the count beside Today, the sheet handoff, and
/// the example markers.
@MainActor
struct TodayFollowupsTests {
    let brand = Brand(name: "Nova")
    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                              details: "Running ten minutes late")

    private func chat(beat: Duration = .zero) -> ChatController {
        ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: beat)
    }

    // MARK: Type and go from Today

    /// Today sends through the chat's own path: the line joins the same
    /// conversation, the shared draft clears, and while a reply is coming
    /// nothing more goes out, just as in the chat.
    @Test func sendingFromTodayUsesTheChatsOwnPath() async {
        let chat = chat()
        chat.draft = "Pack lunches"
        #expect(HomeView.sendsFromToday(chat.draft, chat: chat))
        #expect(chat.draft.isEmpty)
        #expect(chat.sentCount == 1)
        #expect(chat.conversation.turns.contains { $0.speaker == .person && $0.text == "Pack lunches" })
        #expect(chat.isReplying)
        #expect(!HomeView.sendsFromToday("And snacks", chat: chat))
        await chat.replyTask?.value
        #expect(chat.conversation.turns.last?.speaker == .agent)
        // Nothing to send is not a send, so the chat doesn't open on it.
        #expect(!HomeView.sendsFromToday("   ", chat: chat))
    }

    /// Words of care come first from Today too, with no beat held back.
    @Test func careComesFirstFromToday() async {
        let chat = chat(beat: .seconds(60))
        let started = ContinuousClock.now
        #expect(HomeView.sendsFromToday("I want to end my life", chat: chat))
        await chat.replyTask?.value
        #expect(chat.conversation.turns.last?.text == CareCheck.reply)
        #expect(ContinuousClock.now - started < .seconds(60))
    }

    /// A line sent from Today counts as speaking, so a new chat asks first.
    @Test func aLineFromTodayMeansANewChatAsksFirst() async {
        let chat = chat()
        #expect(!NewChatRule.asksFirst(personHasSpoken: chat.conversation.turns.contains { $0.speaker == .person },
                                       draft: chat.draft, pendingLine: nil))
        HomeView.sendsFromToday("Pack lunches", chat: chat)
        await chat.replyTask?.value
        #expect(NewChatRule.asksFirst(personHasSpoken: chat.conversation.turns.contains { $0.speaker == .person },
                                      draft: chat.draft, pendingLine: nil))
    }

    /// The empty Today says only what is true now and has no button of its
    /// own: the composer is the way in.
    @Test func theEmptyTodayPromisesOnlyWhatExists() throws {
        for promise in ["finish", "background", "while you", "show up here", "I'll only ask",
                        // A chat may already be going, so it never promises a new one.
                        "start a chat", "new chat", "we'll start"] {
            #expect(!FeedWords.empty.localizedCaseInsensitiveContains(promise), "\(promise)")
        }
        #expect(FeedWords.empty == "It's just us for now. Write to me below, and I'll answer in the chat.")
        #expect(FeedWords.empty.contains("below"))
        // The voice guide quotes it word for word.
        let guide = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("docs/VOICE.md")
        let text = try String(contentsOf: guide, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("\"\(FeedWords.empty)\""))
    }

    /// Today with its composer, at every text size, on a phone and a big iPad.
    @Test("Smoke: Today with its composer draws",
          arguments: [DynamicTypeSize.xSmall, .large, .accessibility3, .accessibility5], [ColorScheme.light, .dark])
    func smokeTodayWithItsComposer(text: DynamicTypeSize, scheme: ColorScheme) throws {
        let chat = chat()
        for size in [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)] {
            for sources in [[EmptyFeedSource()], [SampleFeedSource()]] as [[any FeedSource]] {
                let model = FeedModel(sources: sources, needsYou: NeedsYou(rule: .isolated()), place: .onDevice,
                                      now: { ShowcaseScene.morning })
                let view = NavigationStack {
                    FeedView(model: model, look: .startingPoint, onTalk: { _ in })
                        .safeAreaInset(edge: .bottom) { TodayComposer(chat: chat, inFront: true, send: { _ in }) }
                }
                try smokeRender(view
                    .environment(\.dynamicTypeSize, text)
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height))
            }
        }
    }

    // MARK: The count beside Today

    /// With no Today on screen at all, the loop the home screen runs still
    /// drops a timed out question, so the sidebar's count goes down.
    @Test func theNeedsYouCountDropsAfterTheWindowWithTodayOffScreen() async throws {
        let clock = Clock()
        let asks = NeedsYou(rule: .isolated(now: clock.now))
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        _ = try #require(asks.ask(note))
        await model.settled()
        #expect(model.feed.needsYou.count == 1)
        let naps = Naps()
        await model.keepFresh { wait in
            naps.count += 1
            #expect(wait == FeedModel.refreshInterval)
            // The first nap passes the window; the second ends the loop.
            guard naps.count == 1 else { throw CancellationError() }
            clock.advance(AskFirst.defaultWindow + 1)
        }
        #expect(naps.count == 2)
        #expect(model.feed.needsYou.isEmpty)
    }

    /// Before the window ends the count stays.
    @Test func theCountStaysInsideTheWindow() async throws {
        let clock = Clock()
        let asks = NeedsYou(rule: .isolated(now: clock.now))
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        _ = try #require(asks.ask(note))
        let naps = Naps()
        await model.keepFresh { _ in
            naps.count += 1
            guard naps.count == 1 else { throw CancellationError() }
            clock.advance(AskFirst.defaultWindow - 1)
        }
        #expect(model.feed.needsYou.count == 1)
    }

    /// Asking, a yes and a dismissal each show on the next turn of the main
    /// actor, with no refresh asked for.
    @Test func eachChangeToTheQuestionsShowsAtOnce() async throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        let calls = Tally()
        let counted = NeedsYou(rule: .isolated())
        _ = counted.observe { MainActor.assumeIsolated { calls.count += 1 } }

        let first = try #require(asks.ask(note))
        await model.settled()
        #expect(model.feed.needsYou.count == 1)
        let yes = ConfirmationState(request: first, rule: rule, onApprove: { asks.approved($0) }, onDecline: {})
        #expect(yes.tapPrimary() == .approved)
        await model.settled()
        #expect(model.feed.needsYou.isEmpty)

        let second = try #require(asks.ask(note))
        await model.settled()
        #expect(model.feed.needsYou.count == 1)
        asks.dismissed(second)
        await model.settled()
        #expect(model.feed.needsYou.isEmpty)

        // The hook fires once for each, and not for a dismissal of nothing.
        let asked = try #require(counted.ask(note))
        counted.dismissed(asked)
        counted.dismissed(asked)
        #expect(calls.count == 2)
    }

    /// Two windows, two Todays, one set of questions. A yes or a dismissal
    /// in either shows in both at once, and a window that closes stops
    /// watching, so the one left keeps hearing every change.
    @Test func everyWindowsTodayHearsEachChange() async throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let first = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        var second: FeedModel? = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        #expect(asks.observerCount == 2)
        func settled() async {
            await first.settled()
            await second?.settled()
        }

        let asked = try #require(asks.ask(note))
        await settled()
        #expect(first.feed.needsYou.count == 1)
        #expect(second?.feed.needsYou.count == 1)
        // Yes in the second window; the first one, made earlier, drops it too.
        let yes = ConfirmationState(request: asked, rule: rule, onApprove: { asks.approved($0) }, onDecline: {})
        #expect(yes.tapPrimary() == .approved)
        await settled()
        #expect(first.feed.needsYou.isEmpty)
        #expect(second?.feed.needsYou.isEmpty == true)

        let again = try #require(asks.ask(note))
        asks.dismissed(again)
        await settled()
        #expect(first.feed.needsYou.isEmpty)
        #expect(second?.feed.needsYou.isEmpty == true)

        // The second window closes. The first still hears the next question.
        await second?.settled()
        second = nil
        #expect(asks.observerCount == 1)
        _ = try #require(asks.ask(note))
        await first.settled()
        #expect(first.feed.needsYou.count == 1)
    }

    /// A change to the questions can arrive in the middle of a view update,
    /// such as a sheet's yes. The feed never publishes right then: the
    /// refresh waits for the next turn of the main actor.
    @Test func aChangeNeverPublishesInsideTheCallThatMadeIt() async throws {
        let asks = NeedsYou(rule: .isolated())
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        _ = try #require(asks.ask(note))
        // Still the same turn: nothing published yet.
        #expect(model.feed.needsYou.isEmpty)
        await model.settled()
        #expect(model.feed.needsYou.count == 1)
    }

    /// Only changes from `NeedsYou`'s hook wait a turn. A yes rebuilds the
    /// feed in the same call, so the card is gone before anything can read
    /// it, and a tap on the card it left behind opens nothing.
    ///
    /// And ask-first never rests on that timing: a second yes for the same
    /// question, from a sheet opened again, acts at most once, and once the
    /// action has gone ahead `AskFirst` refuses any later yes.
    @Test func aSecondYesOnAnAnsweredQuestionIsRefused() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note))
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        let card = try #require(model.feed.needsYou.first)
        model.perform(card, talk: { _ in })
        #expect(model.reviewing == request)
        var yeses: [Approval] = []
        func sheet() -> ConfirmationState {
            ConfirmationState(request: request, rule: model.rule,
                              onApprove: { yeses.append($0); model.approved($0) },
                              onDecline: { model.closedQuestion(request) })
        }
        #expect(sheet().tapPrimary() == .approved)
        // No wait for `settled()`: gone in the same call.
        #expect(model.reviewing == nil)
        #expect(model.feed.needsYou.isEmpty)
        model.perform(card, talk: { _ in })
        #expect(model.reviewing == nil, "the card left behind opens nothing")

        // The same question's sheet opened again before the asker acted:
        // its yes is the first one again, never a second go-ahead.
        _ = sheet().tapPrimary()
        #expect(yeses.count <= 2)
        let first = try #require(yeses.first)
        #expect(rule.decide(note, approval: first) == .proceed)
        for yes in yeses { #expect(rule.decide(note, approval: yes) == .stop, "only one go-ahead") }

        // After the action, a yes is refused outright.
        #expect(sheet().tapPrimary() != .approved)
        #expect(rule.sayYes(to: request) == .timedOut)
        #expect(model.feed.needsYou.isEmpty)
    }

    // MARK: The privacy place, from the model the home screen is given

    /// A model that does not run here, like a cloud model would.
    private struct RemoteModel: ModelClient {
        func reply(to transcript: [ChatTurn]) async throws -> String { "From afar." }
    }

    /// HomeView builds Today's model and the memory's from the model it is
    /// given, so with a cloud model neither promises the device.
    @Test func theHomeScreenPassesTheModelsPrivacyPlace() throws {
        let store = ShowcaseScene.emptyMemory()
        for (model, place) in [(RemoteModel() as any ModelClient, PrivacyPlace.mayLeaveDevice),
                               (LocalStubModel(), .onDevice)] {
            let feed = HomeView.feedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                          model: model, now: { ShowcaseScene.morning })
            #expect(feed.place == place)
            #expect(FeedWords.sampleNote(feed.place).contains("this device") == (place == .onDevice))
            let memory = HomeView.memoryModel(store: store, model: model)
            #expect(memory.place == place)
            #expect(MemoryWords.privacyNote(memory.place).contains("this device") == (place == .onDevice))
        }
        // And HomeView builds them no other way: each is made in one place,
        // the factory checked above, and the memory screen only through it.
        let home = try #require(try ContrastGuardTests.sources().first { $0.name == "HomeView.swift" }?.text)
        let source = SwiftSource(home)
        #expect(source.calls(named: ["FeedModel"]).count == 1)
        #expect(source.calls(named: ["MemoryModel"]).count == 1)
        #expect(source.calls(named: ["MemoryView"]).allSatisfy { $0.arguments.hasPrefix("model: HomeView.memoryModel(") })
    }

    /// Two of the same kind of model are the same screen; another kind, or
    /// one whose words go elsewhere, is a new one.
    @Test func theScreenIsKeyedOnTheModel() {
        #expect(HomeView.identity(of: LocalStubModel()) == HomeView.identity(of: LocalStubModel()))
        #expect(HomeView.identity(of: LocalStubModel()) != HomeView.identity(of: RemoteModel()))
        #expect(HomeView.identity(of: LocalStubModel()) != HomeView.identity(of: SwitchingModel(runsOnDevice: false)))
        #expect(HomeView.identity(of: SwitchingModel(runsOnDevice: true))
                != HomeView.identity(of: SwitchingModel(runsOnDevice: false)))
    }

    /// One kind of model whose words may stay or go, as an adapter with a
    /// local and a cloud setting would be.
    private struct SwitchingModel: ModelClient {
        let runsOnDevice: Bool
        func reply(to transcript: [ChatTurn]) async throws -> String { "Hi." }
    }

    #if os(macOS)
    /// Counts the Today models made, since each one starts by watching the
    /// engine. Nothing else about it is used.
    private final class CountingEngine: TaskEngine, @unchecked Sendable {
        let rule = AskFirst.isolated()
        private(set) var watchers = 0
        var tasks: [AgentTask] { [] }
        func start(_ request: TaskRequest) -> String { "" }
        func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
            watchers += 1
            return TaskObservation {}
        }
        func redirect(_ id: String, with instructions: String) -> Bool { false }
        func stop(_ id: String) -> Bool { false }
        func dismiss(_ id: String) -> Bool { false }
        func clear() -> ClearedTasks { .none }
        func retry(_ id: String) -> Bool { false }
        func resume(_ id: String, with approval: Approval) -> TaskApproval { .refused }
        func questionClosed(_ request: ConfirmationRequest) {}
        func refresh() {}
    }

    /// The model swapped while the home screen is up: Today's model is made
    /// again, from the new model, so its words change with it. Drawn again
    /// with the same model, nothing is made again.
    @MainActor
    @Test func anotherModelMakesTheHomeScreenAgain() throws {
        let engine = CountingEngine()
        let suite = "swap-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        func home(_ model: any ModelClient) -> HomeView {
            HomeView(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                     onboarding: InMemoryOnboardingStore(finished: true), memory: nil, looks: looks,
                     conversation: nil, section: .today, feed: [SampleFeedSource()],
                     needsYou: NeedsYou(rule: engine.rule), tasks: engine, now: { ShowcaseScene.morning })
        }
        let host = NSHostingView(rootView: home(LocalStubModel()))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(engine.watchers == 1)
        host.rootView = home(LocalStubModel())
        host.layoutSubtreeIfNeeded()
        #expect(engine.watchers == 1, "the same model keeps the same screen")
        host.rootView = home(RemoteModel())
        host.layoutSubtreeIfNeeded()
        #expect(engine.watchers == 2, "another model makes Today's model again")
        // What the new one says, built the same way from the new model.
        let today = HomeView.feedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                       model: RemoteModel(), now: { ShowcaseScene.morning })
        #expect(!FeedWords.sampleNote(today.place).contains("this device"))
        #expect(FeedWords.sampleNote(.onDevice).contains("this device"))
    }

    /// Switching models clears the chat, on purpose: see `PrivacyPlace`.
    /// The new screen starts with only its own opening, nothing said to the
    /// old model, and no Forget everything waiting for an answer. If a
    /// change ever carries either one across, this fails loudly, so the
    /// choice is made on purpose.
    @MainActor
    @Test func aNewModelStartsAFreshChat() throws {
        let log = HomeScreenLog()
        let store = ShowcaseScene.emptyMemory()
        // Nothing outlives the test: not its defaults on disk, and not a
        // window left open when a #require throws partway through.
        let suite = "fresh-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        func home(_ model: any ModelClient) -> HomeView {
            HomeView(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                     onboarding: InMemoryOnboardingStore(finished: true), memory: store, looks: looks,
                     conversation: nil, section: .memory, needsYou: NeedsYou(rule: .isolated()), log: log)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Under ARC a window released on close is released twice.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: home(LocalStubModel()))
        window.contentView = host
        // Runs the window until `done`, or gives up after a few seconds,
        // so a slow machine waits longer and a fast one doesn't wait at all.
        func settle(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            host.layoutSubtreeIfNeeded()
            while !done(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle { log.chats.last != nil && log.memories.last != nil }
        let oldChat = try #require(log.chats.last)
        let oldMemory = try #require(log.memories.last, "the memory screen is shown, so its model is made")
        oldChat.conversation = try oldChat.conversation.appendingPerson("A secret for the model on this device")
        oldMemory.askForgetEverything = true

        host.rootView = home(RemoteModel())
        settle { log.chats.last !== oldChat && log.memories.last !== oldMemory }
        let newChat = try #require(log.chats.last)
        #expect(newChat !== oldChat, "another model makes the chat again")
        #expect(newChat.conversation.turns.map(\.text) == [FirstConversation.opening(named: "Pip", place: .mayLeaveDevice)],
                "only the new opening, nothing said to the old model")
        #expect(!newChat.conversation.turns.contains { $0.text.contains("secret") })
        let newMemory = try #require(log.memories.last)
        #expect(newMemory !== oldMemory, "another model makes the memory model again")
        #expect(!newMemory.askForgetEverything, "no Forget everything is left waiting")
        #expect(newMemory.pendingForget == nil)
    }

    /// The memory screen's model is made once, inside its StateObject,
    /// however often the screen around it is drawn again. So a "Saved."
    /// or a Forget everything waiting for its answer is never lost to a
    /// publish on Today or in the chat.
    @MainActor
    @Test func theMemoryModelIsMadeOnce() throws {
        let store = ShowcaseScene.emptyMemory()
        var made = 0
        func screen() -> MemoryView {
            MemoryView(model: {
                made += 1
                return HomeView.memoryModel(store: store, model: LocalStubModel())
            }())
        }
        let host = NSHostingView(rootView: screen())
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(made == 1)
        for _ in 0..<3 {
            host.rootView = screen()
            host.layoutSubtreeIfNeeded()
        }
        #expect(made == 1, "drawn again, never made again")
    }
    #endif

    /// The log the tests read counts each chat the home screen showed once,
    /// however often it appears, so a count of chats is a count of chats made.
    @MainActor
    @Test func aChatShownAgainIsLoggedOnce() throws {
        let log = HomeScreenLog()
        let first = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore())
        let second = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore())
        log.showed(first)
        log.showed(first)
        log.showed(second)
        log.showed(first)
        #expect(log.chats.count == 2)
        #expect(log.chats.first === first && log.chats.last === second)
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/HomeView.swift"),
                              encoding: .utf8)
        let code = String(SwiftSource(text).code)
        #expect(code.contains(".onAppear { log?.showed(chat) }"))
        #expect(!code.contains("log?.chats.append"), "the screen writes down a chat only through showed(_:)")
    }

    // MARK: Closing a sheet, then moving on

    private let todayNarrow = SheetHandoff.Place(section: .today, usesSidebar: false)

    @Test func theHandoffWaitsForTheSheetToGo() {
        var handoff = SheetHandoff()
        var ran = 0
        handoff.hold({ ran += 1 }, at: todayNarrow)
        // The home screen arriving where it was meant to be keeps it waiting.
        handoff.moved(to: todayNarrow)
        #expect(handoff.waiting != nil)
        // Another sheet is still on its way out: keep waiting.
        #expect(handoff.sheetClosed(stillOpen: true, questionOpen: false) == nil)
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(ran == 1)
        // Only once.
        #expect(handoff.sheetClosed(stillOpen: false, questionOpen: false) == nil)
    }

    /// A question that opened while the sheet was closing waits for its
    /// answer; nothing waiting is allowed to sweep it away.
    @Test func aQuestionThatOpensMeanwhileWins() {
        var handoff = SheetHandoff()
        var ran = false
        handoff.hold({ ran = true }, at: todayNarrow)
        #expect(handoff.sheetClosed(stillOpen: false, questionOpen: true) == nil)
        #expect(!ran)
        #expect(handoff.waiting == nil)
    }

    /// The window turned into a sidebar mid-close, so the sheet that was
    /// closing may never say so. A much later, unrelated dismissal must not
    /// run what was held.
    @Test func aResizeMidCloseDropsTheHandoff() {
        var handoff = SheetHandoff()
        var ran = false
        handoff.hold({ ran = true }, at: todayNarrow)
        handoff.moved(to: SheetHandoff.Place(section: .today, usesSidebar: true))
        #expect(handoff.waiting == nil)
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(!ran)
    }

    /// Moving to another section before the sheet is gone drops it too.
    @Test func movingElsewhereMidCloseDropsTheHandoff() {
        var handoff = SheetHandoff()
        var ran = false
        handoff.hold({ ran = true }, at: todayNarrow)
        handoff.moved(to: SheetHandoff.Place(section: .chat, usesSidebar: false))
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(!ran)
    }

    /// When nothing was open to close, `start` hands the step back to run
    /// at once and clears anything older, so a later dismissal runs nothing.
    @Test func nothingOpenClearsAnOlderHandoff() throws {
        var handoff = SheetHandoff()
        var older = false
        handoff.hold({ older = true }, at: todayNarrow)
        var ran = false
        let now = handoff.start({ ran = true }, sheetOpen: false, at: todayNarrow)
        try #require(now != nil)
        now?()
        #expect(ran)
        #expect(handoff.waiting == nil)
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(!older)
    }

    /// With a sheet open, `start` holds the step for the sheet's close.
    @Test func aSheetOpenMakesTheStepWait() {
        var handoff = SheetHandoff()
        var ran = false
        #expect(handoff.start({ ran = true }, sheetOpen: true, at: todayNarrow) == nil)
        #expect(!ran)
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(ran)
    }

    // MARK: Command Return

    private func cover(sidebar: Bool = false, _ section: HomeSection, shortcuts: Bool = false,
                       reader: Bool = false, question: Bool = false) -> HomeCover {
        HomeCover(usesSidebar: sidebar, section: section, showsShortcuts: shortcuts,
                  readerOpen: reader, questionOpen: question)
    }

    /// Command Return never sends from behind a question, the shortcuts, a
    /// piece of work open to read, or the memory sheet on a narrow window;
    /// and Today's composer only while Today is in front. Every case reads
    /// the same `HomeCover`, which also decides the handoff.
    @Test func commandReturnNeverSendsFromBehindASheet() {
        for sidebar in [false, true] {
            #expect(cover(sidebar: sidebar, .chat).chatSendsFromKeyboard)
            #expect(cover(sidebar: sidebar, .today).todayInFront)
            #expect(!cover(sidebar: sidebar, .chat).todayInFront)
            for covered in [cover(sidebar: sidebar, .chat, question: true), cover(sidebar: sidebar, .chat, shortcuts: true),
                            cover(sidebar: sidebar, .chat, reader: true), cover(sidebar: sidebar, .today, question: true),
                            cover(sidebar: sidebar, .today, shortcuts: true), cover(sidebar: sidebar, .today, reader: true)] {
                #expect(!covered.chatSendsFromKeyboard, "\(covered)")
                #expect(!covered.todayInFront, "\(covered)")
            }
        }
        // The memory on a narrow window is a sheet over the chat.
        let memorySheet = cover(.memory)
        #expect(memorySheet.memorySheetOpen)
        #expect(memorySheet.anySheetOpen)
        #expect(!memorySheet.chatSendsFromKeyboard)
        #expect(!memorySheet.todayInFront)
        // Beside a sidebar it is a screen of its own, not a sheet.
        #expect(!cover(sidebar: true, .memory).anySheetOpen)
    }

    /// Whatever stops Command Return also makes the handoff wait, and a
    /// question is never something the handoff closes.
    @Test func oneCoverDrivesTheKeyboardAndTheHandoff() {
        for sidebar in [false, true] {
            for section in HomeSection.allCases {
                for (shortcuts, reader) in [(false, false), (true, false), (false, true)] {
                    let c = cover(sidebar: sidebar, section, shortcuts: shortcuts, reader: reader)
                    #expect(c.chatSendsFromKeyboard == !c.anySheetOpen, "\(c)")
                    #expect(c.chatIsCovered == c.anySheetOpen, "\(c)")
                }
            }
        }
        let asking = cover(.chat, question: true)
        #expect(!asking.anySheetOpen)
        #expect(asking.chatIsCovered)
    }

    /// A VoiceOver user hears that sending from Today opens the chat.
    @Test func todaysComposerSaysWhereTheWordsGo() {
        let composer = TodayComposer(chat: chat(), inFront: true, send: { _ in }).composer
        #expect(composer.hint == FeedWords.composerHint)
        #expect(FeedWords.composerHint.contains("chat"))
        #expect(Composer(draft: .constant(""), isBusy: false, keyboardSends: true, send: { _ in }).hint == nil)
    }

    /// No guessed delay is left in the home screen.
    @Test func theHomeScreenWaitsOnNoTimer() throws {
        let source = try ContrastGuardTests.sources().first { $0.name == "HomeView.swift" }?.text ?? ""
        #expect(!source.isEmpty)
        #expect(!source.contains("asyncAfter"))
    }

    // MARK: Examples say so

    @Test func exampleCardsSayExampleFirst() throws {
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: ShowcaseScene.sampleQuestion(), place: .onDevice,
                              now: { ShowcaseScene.morning })
        let cards = model.feed.needsYou + model.feed.groups.flatMap(\.items)
        #expect(cards.count > 2)
        for item in cards {
            #expect(model.isSample(item))
            let card = FeedCard(item: item, time: "9:36 AM", isSample: model.isSample(item), perform: {})
            #expect(card.spoken.hasPrefix("\(FeedWords.exampleMarker). \(item.spokenKind). "))
        }
        // Real cards and real questions don't.
        let asks = NeedsYou(rule: .isolated())
        _ = asks.ask(note)
        let real = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        let question = try #require(real.feed.needsYou.first)
        #expect(!real.isSample(question))
        #expect(!FeedCard(item: question, time: "9:36 AM", isSample: false, perform: {}).spoken.contains(FeedWords.exampleMarker))
    }

    /// The sample payment sheet, from Today's sample question and from the
    /// question scenes, is built as an example, so it shows the label.
    @Test func theSamplePaymentSheetIsAnExample() throws {
        let asks = ShowcaseScene.sampleQuestion()
        #expect(asks.isSample)
        let request = try #require(asks.items(now: Date()).first?.request)
        // What HomeView passes: the sheet is an example when the questions are.
        let fromToday = ConfirmationSheet(request: request, rule: asks.rule, isExample: asks.isSample,
                                          onApprove: { _ in }, onDecline: {})
        #expect(fromToday.isExample)
        for scene in [ShowcaseScene.confirm, .confirmTimedOut] {
            let sheet = try #require(scene.sampleSheet)
            #expect(sheet.isExample, "\(scene)")
        }
        // A real question is not.
        #expect(!ConfirmationSheet(request: request, rule: asks.rule, onApprove: { _ in }, onDecline: {}).isExample)
    }

    // MARK: Every sample sheet says it is an example

    /// PERMANENT GUARD. Every showcase scene that can show a confirmation
    /// sheet marks it as an example. A new scene that shows one is counted
    /// here, so it can't slip by unmarked.
    @Test func everyShowcaseSheetIsMarkedAsAnExample() {
        var showing: [ShowcaseScene] = []
        for scene in ShowcaseScene.allCases {
            guard let examples = scene.confirmationSheetsAreExamples else { continue }
            showing.append(scene)
            #expect(examples, "\(scene) shows a sample question not marked as an example")
        }
        #expect(Set(showing) == [.confirm, .confirmTimedOut, .todayNeedsYou,
                                 .taskRunning, .taskRetrying, .taskWaiting, .taskDone, .tasksLive])
    }

    /// A scripted task's question, opened from its card's Approve as Today
    /// does, is an example in the sheet too.
    @Test func aSampleTaskQuestionOpensAsAnExample() throws {
        let rule = AskFirst.isolated()
        let scene = ShowcaseScene.taskWaiting
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: try #require(scene.needsYou(rule: rule)),
                              tasks: scene.tasks(rule: rule), place: .onDevice, now: { ShowcaseScene.morning })
        let task = try #require(model.feed.needsYou.compactMap(\.task).first { $0.question != nil })
        model.review(task)
        let request = try #require(model.reviewing)
        #expect(model.isSample(request))
    }

    /// The showcase builds a sheet only from what the guard above reads: no
    /// `ConfirmationSheet(` there that doesn't pass the sample's own flag,
    /// and the Today scenes take their questions from `needsYou(at:)` and
    /// their tasks from `tasks(rule:)`.
    @Test func theShowcaseBuildsSheetsOnlyFromWhatTheGuardReads() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/ShowcaseScene.swift"),
                              encoding: .utf8)
        let source = SwiftSource(text)
        let sheets = source.calls(named: ["ConfirmationSheet"])
        #expect(!sheets.isEmpty)
        for sheet in sheets {
            #expect(sheet.arguments.contains("isExample: sheet.isExample"), "line \(sheet.line): \(sheet.arguments)")
        }
        for home in source.calls(named: ["HomeView"]) {
            #expect(home.arguments.contains("needsYou: needsYou(at: morning"), "line \(home.line)")
            if home.arguments.contains("tasks:") {
                #expect(home.arguments.contains("tasks: tasks(rule: rule)"), "line \(home.line)")
            }
        }
    }

    /// What each file may pass a `ConfirmationSheet` as `isExample:`, and
    /// the request that flag must be about. Each one is tied to the sample
    /// flag of where the question came from: Today's `isSample(request)`
    /// reads the questions' and the tasks' own `isSample`, and the
    /// showcase's sample sheet is made with `isExample: true`.
    static let sheetExamples: [String: (request: String, isExample: String)] = [
        "PebbleUI/HomeView.swift": ("request: request", "isExample: feed.isSample(request)"),
        "PebbleUI/ShowcaseScene.swift": ("request: sheet.request", "isExample: sheet.isExample"),
    ]

    /// The problems with every `ConfirmationSheet(` call in `files`.
    static func sheetProblems(in files: [(name: String, text: String)]) -> [String] {
        var problems: [String] = []
        for file in files {
            let source = SwiftSource(file.text)
            for call in source.calls(named: ["ConfirmationSheet"]) {
                let arguments = call.arguments.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let wanted = sheetExamples[file.name] else {
                    problems.append("\(file.name):\(call.line): a ConfirmationSheet here has no isExample rule in sheetExamples")
                    continue
                }
                // A missing isExample: is false, so a sample would pass as real.
                if !arguments.contains(wanted.isExample) {
                    problems.append("\(file.name):\(call.line): isExample must be \"\(wanted.isExample)\", got \(call.arguments)")
                }
                if !arguments.contains(wanted.request) {
                    problems.append("\(file.name):\(call.line): the flag must be about \"\(wanted.request)\"")
                }
            }
            // The showcase's sample sheet is always an example.
            for sheet in source.calls(named: ["SampleSheet"])
            where !sheet.arguments.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .contains("isExample: true") {
                problems.append("\(file.name):\(sheet.line): a SampleSheet must be made with isExample: true")
            }
        }
        return problems
    }

    /// PERMANENT GUARD. Every `ConfirmationSheet(` in the package sources
    /// and the app is passed an `isExample:` that is the sample flag of
    /// the very question it shows, rather than trusting each source's
    /// `isSample` to reach the sheet on its own.
    @Test func everySheetIsToldWhetherItIsAnExample() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let package = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App")).map { ("App/\($0.name)", $0.text) }
        let files = package + app
        let calling = files.filter { !SwiftSource($0.text).calls(named: ["ConfirmationSheet"]).isEmpty }.map(\.name)
        #expect(Set(calling) == Set(Self.sheetExamples.keys), "each file that shows a sheet has its rule, and only those")
        for problem in Self.sheetProblems(in: files) {
            Issue.record(Comment(rawValue: problem))
        }
        let wrong: [(String, String)] = [
            ("PebbleUI/HomeView.swift", "ConfirmationSheet(request: request, rule: feed.rule, onApprove: { _ in }, onDecline: {})"),
            ("PebbleUI/HomeView.swift", "ConfirmationSheet(request: request, rule: feed.rule, isExample: false, onApprove: { _ in })"),
            ("PebbleUI/HomeView.swift", "ConfirmationSheet(request: other, rule: r, isExample: feed.isSample(request))"),
            ("PebbleUI/HomeView.swift", "ConfirmationSheet(request: request, isExample: !feed.isSample(request))"),
            ("PebbleUI/ShowcaseScene.swift", "ConfirmationSheet(request: sheet.request, rule: sheet.rule, isExample: true)"),
            ("PebbleUI/ShowcaseScene.swift", "SampleSheet(request: request, rule: rule, isExample: false)"),
            ("PebbleUI/FeedView.swift", "ConfirmationSheet(request: request, rule: rule, isExample: model.isSample(request))"),
        ]
        for (name, text) in wrong {
            #expect(!Self.sheetProblems(in: [(name, text)]).isEmpty, "missed: \(text)")
        }
        let right = "ConfirmationSheet(request: sheet.request, rule: sheet.rule, isExample: sheet.isExample,\n"
            + "    onApprove: { _ in }, onDecline: {})\nSampleSheet(request: request, rule: rule, isExample: true)"
        #expect(Self.sheetProblems(in: [("PebbleUI/ShowcaseScene.swift", right)]).isEmpty)
        // Each argument wrapped onto a line of its own still reads the same.
        let wrapped = "ConfirmationSheet(\n    request: sheet.request,\n    rule: sheet.rule,\n    isExample:\n"
            + "        sheet.isExample\n)\nSampleSheet(\n    request: request,\n    isExample: true\n)"
        #expect(Self.sheetProblems(in: [("PebbleUI/ShowcaseScene.swift", wrapped)]).isEmpty)
    }

    @Test func theShowcaseBakeryUsesAnExampleDomain() throws {
        let item = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first)
        #expect(item.title.contains("risebakery.example"))
    }

    // MARK: Cards never run off the screen, measured

    /// The size a view takes when offered `width`, as rendered.
    private func measured(_ view: some View, width: CGFloat, text: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, text))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        return CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
    }

    /// Every card, rendered at the width its column gives it, from Slide
    /// Over to a 13-inch iPad and the smallest text size to the largest,
    /// takes no more than that width. This measures what SwiftUI lays out,
    /// so a card that refuses to wrap fails here.
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .accessibility1, .accessibility5])
    func everyCardFitsItsColumnAsRendered(text: DynamicTypeSize) throws {
        let long = FeedItem(id: "long", kind: .ready, time: ShowcaseScene.morning,
                            title: "accounts.risebakery.example.billing-secure-example.net sent a receipt",
                            body: String(repeating: "A rather long line of words to wrap. ", count: 6), action: .open("x"))
        let items = SampleFeedSource().items(now: ShowcaseScene.morning)
            + (ShowcaseScene.sampleQuestion().items(now: Date())) + [long]
        for window in [320, 393, 678, 1032, 1376] as [CGFloat] {
            let content = FeedView.contentWidth(in: window, column: Theme.feedWidth)
            let count = FeedView.columnCount(for: content, minimum: 320, accessibilityText: text.isAccessibilitySize)
            let column = (content - CGFloat(count - 1) * FeedView.cardSpacing) / CGFloat(count)
            for item in items {
                let size = try measured(FeedCard(item: item, time: "9:36 AM", isSample: true, perform: {}),
                                        width: column, text: text)
                #expect(size.width <= column + 0.5, "\(item.id) is \(size.width) wide in \(column) at \(text)")
            }
            // The grid as Today builds it fits the room it has, too.
            let grid = LazyVGrid(columns: FeedView.columns(for: content, minimum: 320,
                                                          accessibilityText: text.isAccessibilitySize),
                                 alignment: .leading, spacing: FeedView.cardSpacing) {
                ForEach(items) { FeedCard(item: $0, time: "9:36 AM", perform: {}) }
            }
            let size = try measured(grid, width: content, text: text)
            #expect(size.width <= content + 0.5, "the grid is \(size.width) wide in \(content) at \(text)")
        }
    }
}
#endif
