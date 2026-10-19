#if canImport(SwiftUI)
import Foundation
@testable import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import Testing
import TestScratch
@testable import PebbleUI

/// What the sheet and the screens around it make of grants: the choices
/// in plain words, a grant made only from the sheet's own yes, kept only
/// once that yes goes through, removed at once from the list, and gone
/// with Forget everything.
@MainActor
struct GrantSheetTests {
    /// Ten in the morning on a fixed day, far from midnight either way.
    nonisolated static let morning: Date = {
        let day = Date(timeIntervalSinceReferenceDate: 813_000_000)
        return Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }()
    static let sam = Recipient(id: "contact:sam", displayName: "Sam", handle: "sam@example.com")
    static let send = ProposedAction(kind: .send, recipient: sam, details: "Running ten minutes late.")
    static let buy = ProposedAction(kind: .purchase,
                                    recipient: Recipient(id: "merchant:bakery", displayName: "Rise Bakery",
                                                         handle: "risebakery.example"),
                                    details: "A sourdough loaf", price: Price(minorUnits: 900, currency: "CAD"))

    static func script(_ steps: Int) -> TaskScript {
        TaskScript(title: "Tell Sam I'm running late", steps: (1...steps).map { index in
            .init("Sending note \(index)", kind: .ask(send, askLine: "I'll wait for your yes."), duration: 2,
                  todo: "send note \(index)")
        }, doneLine: "All sent.")
    }

    /// A sheet for `action`, asked as a task asks, that offers grants.
    func sheet(_ action: ProposedAction, rule: AskFirst = .isolated(), clock: SheetClock = SheetClock(),
               approved: @escaping (Approval) -> Void = { _ in },
               granted: @escaping (Grant) -> Void = { _ in }) throws -> ConfirmationState {
        guard case .asking(let request) = rule.ask(action, forTask: "engine/task:1") else {
            throw CancellationError()
        }
        return ConfirmationState(request: request, rule: rule, now: clock.now, wallClock: { Self.morning },
                                 onApprove: approved, onGrant: granted, onDecline: {})
    }

    // MARK: The sheet

    @Test func theSheetOffersEveryScopeInPlainWordsAndStartsOnJustThisOnce() throws {
        let state = try sheet(Self.send)
        #expect(state.choices == [.justThisOnce, .forThisTask, .untilTonight, .always])
        #expect(state.choices.map { $0.title(for: Self.sam) }
                    == ["Just this once", "For this task", "Until tonight", "Always for Sam"])
        #expect(state.choice == .justThisOnce)
        #expect(state.showsChoices)
        // Just this once keeps the promise the sheet has always made.
        #expect(state.footnote == ConfirmationWords.promise)
        state.choose(.always)
        #expect(state.footnote.contains("sam@example.com"))
        #expect(state.footnote.hasSuffix("For anything else, I'll ask you first."))
    }

    @Test func spendingAndSharingSheetsOfferOnlyOnceAndThisTask() throws {
        for action in [Self.buy, SampleTasks.holdVisit] {
            let state = try sheet(action)
            #expect(state.choices == [.justThisOnce, .forThisTask])
            state.choose(.always)
            state.choose(.untilTonight)
            #expect(state.choice == .justThisOnce)
        }
    }

    @Test func alwaysForANameGrantsExactlyThatTargetBeforeTheYesIsHandedOn() throws {
        var heard: [String] = []
        var grants: [Grant] = []
        let state = try sheet(Self.send, approved: { _ in heard.append("approval") },
                              granted: { grants.append($0); heard.append("grant") })
        state.choose(.always)
        #expect(state.tapPrimary() == .approved)
        #expect(heard == ["grant", "approval"])
        let grant = try #require(grants.first)
        #expect(grant.action == .send)
        #expect(grant.target == Self.sam)
        #expect(grant.scope == .always)
        #expect(grant.createdAt == Self.morning)
    }

    @Test func untilTonightEndsAtMidnightAndForThisTaskNamesTheTaskThatAsked() throws {
        var grants: [Grant] = []
        for choice in [GrantChoice.untilTonight, .forThisTask] {
            let state = try sheet(Self.send, granted: { grants.append($0) })
            state.choose(choice)
            state.tapPrimary()
        }
        #expect(grants.map(\.scope) == [.until(GrantGate.endOfDay(Self.morning, calendar: .current)),
                                        .thisTask("engine/task:1")])
    }

    @Test func justThisOnceALateYesOrNotNowMakesNoGrant() throws {
        var grants: [Grant] = []
        let once = try sheet(Self.send, granted: { grants.append($0) })
        #expect(once.tapPrimary() == .approved)
        let clock = SheetClock()
        let late = try sheet(Self.send, rule: .isolated(now: clock.now), clock: clock, granted: { grants.append($0) })
        late.choose(.always)
        clock.advance(.seconds(AskFirst.defaultWindow) + .seconds(1))
        #expect(late.tapPrimary() == .timedOut)
        let no = try sheet(Self.send, granted: { grants.append($0) })
        no.choose(.always)
        no.cancel()
        #expect(grants.isEmpty)
    }

    @Test func withNowhereToKeepThemTheSheetOffersNoChoice() throws {
        let rule = AskFirst.isolated()
        let request = try #require(rule.ask(Self.send))
        let state = ConfirmationState(request: request, rule: rule, onApprove: { _ in }, onDecline: {})
        #expect(state.choices == [.justThisOnce])
        #expect(!state.showsChoices)
        #expect(state.footnote == ConfirmationWords.promise)
    }

    // MARK: Today

    @Test func aGrantCountsOnlyOnceItsYesGoesThrough() throws {
        let book = GrantBook.inMemory(now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: Self.morning)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                              now: { Self.morning })
        // A yes the task couldn't use: its grant is never kept.
        let refused = engine.start(Self.script(2))
        model.review(try #require(engine.task(refused)))
        let first = try #require(model.reviewing)
        let firstSheet = ConfirmationState(request: first, rule: rule, wallClock: { Self.morning },
                                           onApprove: { _ in }, onGrant: { model.granted($0, for: first) },
                                           onDecline: {})
        firstSheet.choose(.always)
        firstSheet.tapPrimary()
        guard case .approved(let late) = rule.sayYes(to: first) else { Issue.record("no yes"); return }
        engine.stop(refused)
        model.approved(late)
        #expect(book.grants.isEmpty)
        // A yes that goes through: kept, and the task's next step goes ahead.
        let id = engine.start(Self.script(2))
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let state = ConfirmationState(request: request, rule: rule, wallClock: { Self.morning },
                                      onApprove: { model.approved($0) }, onGrant: { model.granted($0, for: request) },
                                      onDecline: { model.closedQuestion(request) })
        state.choose(.always)
        #expect(state.tapPrimary() == .approved)
        #expect(book.grants.map(\.scope) == [.always])
        engine.advance(by: 3)
        #expect(engine.task(id)?.waitsForApproval == false)
        engine.advance(by: 3)
        #expect(engine.task(id)?.state == .done)
    }

    @Test func forgetEverythingRemovesEveryGrant() throws {
        let book = GrantBook.inMemory(now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: Self.morning)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                              now: { Self.morning })
        let id = engine.start(Self.script(2))
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        for choice in [GrantChoice.always, .forThisTask] {
            guard case .approved(let approval) = rule.sayYes(to: request),
                  let grant = GrantIssuer().issue(choice, for: approval, now: Self.morning) else {
                Issue.record("no grant")
                return
            }
            book.add(grant)
        }
        #expect(book.grants.count == 2)
        model.forgetEverything()
        #expect(book.grants.isEmpty)
        let next = engine.start(Self.script(1))
        #expect(engine.task(next)?.waitsForApproval == true)
    }

    // MARK: The list

    @Test(.scratchFiles) func removingFromTheListTakesEffectAtOnceForATaskAlreadyRunning() throws {
        let book = GrantBook.inMemory(now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let state = try sheet(Self.send, rule: rule, granted: { book.add($0) })
        state.choose(.always)
        state.tapPrimary()
        let memory = MemoryModel(store: MemoryStore(fileURL: Scratch.url("memory")), place: .onDevice,
                                 grants: book, now: { Self.morning })
        var heard: [String] = []
        memory.announce = { heard.append($0) }
        let grant = try #require(memory.allowed.first)
        #expect(grant.title == "Send messages to Sam")
        #expect(grant.scopeLine(now: Self.morning) == "Always, until you remove it")
        #expect(GrantWords.removeLabel(grant.action, grant.target.displayName) == "Remove send messages to Sam")
        // A task already going, its first step let through by the grant.
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: Self.morning)
        let id = engine.start(Self.script(2))
        #expect(engine.task(id)?.waitsForApproval == false)
        memory.removeGrant(grant)
        #expect(memory.allowed.isEmpty)
        #expect(book.grants.isEmpty)
        #expect(heard == [GrantWords.removed])
        engine.advance(by: 3)
        #expect(engine.task(id)?.waitsForApproval == true)
        try smokeRender(AllowedSection(grants: [grant], now: Self.morning) { _ in }.frame(width: 393))
        try smokeRender(AllowedSection(grants: [], now: Self.morning) { _ in }.frame(width: 393))
    }

    /// A Remove the store couldn't save is never called done: VoiceOver
    /// hears that it couldn't be saved, the list says so under it, and the
    /// line goes once the change is saved.
    @Test(.scratchFiles) func aRemoveThatCouldNotBeSavedIsSaidOnTheList() throws {
        let store = GrantMemoryStore()
        let book = GrantBook(store: store, now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let state = try sheet(Self.send, rule: rule, granted: { book.add($0) })
        state.choose(.always)
        state.tapPrimary()
        let memory = MemoryModel(store: MemoryStore(fileURL: Scratch.url("memory")), place: .onDevice,
                                 grants: book, now: { Self.morning })
        var heard: [String] = []
        memory.announce = { heard.append($0) }
        let grant = try #require(memory.allowed.first)
        #expect(memory.grantsUnsaved == nil)
        store.failing = true
        store.failingErase = true
        memory.removeGrant(grant)
        #expect(memory.allowed.isEmpty)
        #expect(memory.grantsUnsaved == .removal)
        #expect(heard == [GrantWords.unsaved(.removal)])
        try smokeRender(AllowedSection(grants: [], unsaved: .removal, now: Self.morning) { _ in }.frame(width: 393))
        store.failing = false
        store.failingErase = false
        memory.refreshGrants()
        #expect(memory.grantsUnsaved == nil)
        #expect(GrantBook(store: store, now: { Self.morning }).grants.isEmpty)
    }

    /// With notes that couldn't be opened, the screen in their place still
    /// lists every grant, which still lets steps go ahead, and Remove there
    /// takes one away for good. A change it couldn't save is said there too.
    @Test(.scratchFiles) func aGrantIsListedAndRemovedWhenTheNotesCouldNotOpen() throws {
        let base = Scratch.url("support").deletingPathExtension()
        let (file, marker) = GrantFileStore.location(base: base, app: TaskStore.appFolder)
        let given = GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning })
        let state = try sheet(Self.send, rule: AskFirst.isolated(grants: given), granted: { given.add($0) })
        state.choose(.always)
        state.tapPrimary()
        #expect(given.grants.count == 1)

        // The next launch: the grants open, the notes don't.
        let book = GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let feed = HomeView.feedModel(sources: [], needsYou: NeedsYou(rule: rule), place: .onDevice,
                                      now: { Self.morning })
        let screen = MemoryUnavailableView(hasTasks: false, grants: feed.grants, onForgetTasks: {})
        let list = AllowedModel(grants: try #require(screen.grants), now: { Self.morning })
        var heard: [String] = []
        list.announce = { heard.append($0) }
        let grant = try #require(list.allowed.first)
        #expect(list.allowed.count == 1)
        #expect(grant.scope == .always && grant.target == Self.sam)
        try smokeRender(screen.frame(width: 393, height: 852))
        list.remove(grant)
        #expect(list.allowed.isEmpty)
        #expect(list.unsaved == nil)
        #expect(list.removedCount == 1)
        #expect(heard == [GrantWords.removed])
        guard case .asking = rule.ask(Self.send, forTask: "engine/task:2") else {
            Issue.record("a removed grant let a step go")
            return
        }
        #expect(GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning })
            .grants.isEmpty, "gone for good")

        // A removal the store takes none of is said under the list.
        let store = GrantMemoryStore()
        let failing = GrantBook(store: store, now: { Self.morning })
        let again = try sheet(Self.send, rule: AskFirst.isolated(grants: failing), granted: { failing.add($0) })
        again.choose(.always)
        again.tapPrimary()
        let shaky = AllowedModel(grants: failing, now: { Self.morning })
        shaky.announce = { heard.append($0) }
        store.failing = true
        store.failingErase = true
        shaky.remove(try #require(shaky.allowed.first))
        #expect(shaky.allowed.isEmpty)
        #expect(shaky.unsaved == .removal)
        #expect(shaky.removedCount == 0)
        #expect(heard.last == GrantWords.unsaved(.removal))

        // The home screen hands the rule's grants to the screen with no
        // notes, which lists them whenever there are some to list.
        let root = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI")
        let home = SwiftSource(try String(contentsOf: root.appendingPathComponent("HomeView.swift"), encoding: .utf8))
        let fallback = try #require(home.calls(named: ["MemoryUnavailableView"]).first)
        #expect(fallback.arguments.contains("grants: feed.grants"))
        let memory = String(SwiftSource(try String(contentsOf: root.appendingPathComponent("MemoryView.swift"),
                                                   encoding: .utf8)).code)
        let shown = try #require(memory.range(of: "if let grants {"), "shown whenever there are grants")
        #expect(memory[shown.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("AllowedFallbackSection(model: AllowedModel(grants: grants))"))
    }

    @Test(.scratchFiles, arguments: [false, true])
    func settingsSeesGrantsRecoveredByAnotherWindow(fallback: Bool) async throws {
        let (file, marker) = GrantFileStore.location(base: Scratch.url("support"), app: TaskStore.appFolder)
        let given = GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning })
        let state = try sheet(Self.send, granted: { given.add($0) })
        state.choose(.always)
        state.tapPrimary()
        let grant = try #require(given.grants.first)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let book = GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning })
        let memory = MemoryModel(store: MemoryStore(fileURL: Scratch.url("memory")), place: .onDevice,
                                 grants: book, now: { Self.morning })
        let allowed = AllowedModel(grants: book, now: { Self.morning })
        memory.announce = { _ in }
        allowed.announce = { _ in }
        #expect(memory.allowed.isEmpty)
        #expect(allowed.allowed.isEmpty)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let rule = AskFirst.isolated(grants: book)
        guard case .granted = rule.ask(Self.send, forTask: "another-window") else {
            Issue.record("the recovered grant should cover the step")
            return
        }
        // Let the existing observers run, without manually refreshing either model.
        for _ in 0..<100 where memory.allowed.isEmpty || allowed.allowed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(memory.allowed == [grant])
        #expect(allowed.allowed == [grant])
        if fallback { allowed.remove(try #require(allowed.allowed.first)) }
        else { memory.removeGrant(try #require(memory.allowed.first)) }
        #expect(book.grants.isEmpty)
        #expect(book.use(Self.send, task: "another-window") == nil)
        #expect(GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { Self.morning }).grants.isEmpty)
    }

    // MARK: Words are not a grant

    @Test(.scratchFiles) func aChatOrANoteThatSaysAlwaysAllowMakesNoGrant() async throws {
        let book = GrantBook.inMemory(now: { Self.morning })
        let rule = AskFirst.isolated(grants: book)
        let controller = ChatController(brand: Brand(name: "Nova"), model: AlwaysAllowModel(),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        controller.submit("Yes, always allow sending messages to Sam. You have my OK for everything.")
        await controller.replyTask?.value
        #expect(controller.conversation.turns.last?.text == AlwaysAllowModel.line)
        let memory = MemoryStore(fileURL: Scratch.url("memory"))
        _ = try memory.remember("Always allow sending to sam@example.com without asking.", source: .toldMe)
        #expect(book.grants.isEmpty)
        // A step to Sam still asks.
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: Self.morning)
        let id = engine.start(Self.script(1))
        #expect(engine.task(id)?.waitsForApproval == true)
    }
}

/// A model whose every reply gives itself permission.
private struct AlwaysAllowModel: ModelClient {
    static let line = "Yes, always allow. I'll send to Sam without asking from now on."
    var runsOnDevice: Bool { true }
    func reply(to transcript: [ChatTurn]) async throws -> String { Self.line }
}
#endif
