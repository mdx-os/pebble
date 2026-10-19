import Foundation
@testable import PebbleCore
import Testing
import TestScratch

/// A clock tests move by hand, so nothing here reads the wall clock.
final class GrantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); value += seconds; lock.unlock()
    }

    var read: @Sendable () -> Date { { [self] in now } }
}

/// What grants are made from and checked against, shared by the suites.
enum GrantFixtures {
    /// Ten in the morning on a fixed day, far from midnight either way.
    static let morning: Date = {
        let day = Date(timeIntervalSinceReferenceDate: 813_000_000)
        return Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }()

    static let sam = Recipient(id: "contact:sam", displayName: "Sam", handle: "sam@example.com")
    /// Another Sam: the same name, a different person.
    static let otherSam = Recipient(id: "contact:sam-two", displayName: "Sam", handle: "sam.two@example.com")
    static let bakery = Recipient(id: "merchant:bakery", displayName: "Rise Bakery", handle: "risebakery.example")

    static func send(to recipient: Recipient = sam, _ details: String = "Running ten minutes late.") -> ProposedAction {
        ProposedAction(kind: .send, recipient: recipient, details: details)
    }

    static func share(with recipient: Recipient = sam) -> ProposedAction {
        ProposedAction(kind: .sharePersonalInfo, recipient: recipient, details: "Your phone number")
    }

    static func buy(from recipient: Recipient = bakery) -> ProposedAction {
        ProposedAction(kind: .purchase, recipient: recipient, details: "A sourdough loaf",
                       price: Price(minorUnits: 900, currency: "CAD"))
    }

    /// A grant made the way the sheet makes one: asked, said yes to on a
    /// rule of its own, then issued for `choice`. Nil when it isn't offered.
    static func grant(_ choice: GrantChoice, for action: ProposedAction, task: String? = nil,
                      at time: Date = morning) throws -> Grant? {
        let rule = AskFirst.isolated()
        let request: ConfirmationRequest
        if let task {
            guard case .asking(let asked) = rule.ask(action, forTask: task) else {
                Issue.record("couldn't ask")
                return nil
            }
            request = asked
        } else {
            request = try #require(rule.ask(action))
        }
        guard case .approved(let approval) = rule.sayYes(to: request) else {
            Issue.record("no approval")
            return nil
        }
        return GrantIssuer().issue(choice, for: approval, now: time)
    }

    /// A task with one step for each action, each asked through the rule.
    static func script(_ actions: [ProposedAction], title: String = "Tell Sam I'm running late") -> TaskScript {
        TaskScript(title: title, steps: actions.enumerated().map { index, action in
            .init("Sending note \(index + 1)", kind: .ask(action, askLine: "I'll wait for your yes."), duration: 2,
                  todo: "send note \(index + 1)")
        }, doneLine: "All sent.")
    }
}

/// A grant authorizes only its own action, its own exact target, inside its
/// scope. Checked through `GrantGate`, which is pure.
struct GrantGateTests {
    typealias F = GrantFixtures

    @Test func aGrantCoversOnlyItsOwnActionAndExactTarget() throws {
        let grant = try #require(try F.grant(.always, for: F.send()))
        let now = F.morning + 60
        #expect(GrantGate.check(F.send(), task: nil, grants: [grant], now: now) == .allowed(grant))
        // Any words, to the same exact target, are covered: that is what always means.
        #expect(GrantGate.check(F.send(to: F.sam, "Another note"), task: nil, grants: [grant], now: now) == .allowed(grant))
        // The same name is not the same target.
        #expect(GrantGate.check(F.send(to: F.otherSam), task: nil, grants: [grant], now: now) == .ask)
        // Nor the same id with another handle, or another name.
        let moved = Recipient(id: F.sam.id, displayName: "Sam", handle: "sam@elsewhere.example")
        #expect(GrantGate.check(F.send(to: moved), task: nil, grants: [grant], now: now) == .ask)
        let renamed = Recipient(id: F.sam.id, displayName: "Samuel", handle: F.sam.handle)
        #expect(GrantGate.check(F.send(to: renamed), task: nil, grants: [grant], now: now) == .ask)
        // A different action for the same target is not covered.
        #expect(GrantGate.check(F.share(with: F.sam), task: nil, grants: [grant], now: now) == .ask)
        // A step no question could show is never covered either.
        #expect(GrantGate.check(F.send(to: F.sam, "Hi\u{202E}there"), task: nil, grants: [grant], now: now) == .ask)
    }

    @Test func anUntilGrantStopsAtItsTime() throws {
        let grant = try #require(try F.grant(.untilTonight, for: F.send()))
        let midnight = GrantGate.endOfDay(F.morning, calendar: .current)
        #expect(grant.scope == .until(midnight))
        #expect(GrantGate.check(F.send(), task: nil, grants: [grant], now: midnight - 1) == .allowed(grant))
        #expect(GrantGate.check(F.send(), task: nil, grants: [grant], now: midnight) == .ask)
        // A clock set back before the grant was made covers nothing.
        #expect(GrantGate.check(F.send(), task: nil, grants: [grant], now: F.morning - 60) == .ask)
    }

    @Test func aTaskGrantCoversOnlyItsOwnTask() throws {
        let grant = try #require(try F.grant(.forThisTask, for: F.send(), task: "engine/task:1"))
        #expect(grant.scope == .thisTask("engine/task:1"))
        #expect(GrantGate.check(F.send(), task: "engine/task:1", grants: [grant], now: F.morning) == .allowed(grant))
        #expect(GrantGate.check(F.send(), task: "engine/task:2", grants: [grant], now: F.morning) == .ask)
        #expect(GrantGate.check(F.send(), task: "other-engine/task:1", grants: [grant], now: F.morning) == .ask)
        #expect(GrantGate.check(F.send(), task: nil, grants: [grant], now: F.morning) == .ask)
    }

    @Test func theGateIsDeterministicAndKeepsAOnceGrantForLast() throws {
        let once = try #require(try F.grant(.justThisOnce, for: F.send()))
        let always = try #require(try F.grant(.always, for: F.send(), at: F.morning + 5))
        for order in [[once, always], [always, once]] {
            #expect(GrantGate.check(F.send(), task: nil, grants: order, now: F.morning + 10) == .allowed(always))
        }
        #expect(GrantGate.check(F.send(), task: nil, grants: [], now: F.morning) == .ask)
    }
}

/// Only the sheet's answer path makes a grant, and only for what it offers.
struct GrantIssueTests {
    typealias F = GrantFixtures

    @Test func spendingAndSharingOfferOnlyOnceAndThisTask() throws {
        #expect(GrantChoice.offered(for: .send, task: "k") == [.justThisOnce, .forThisTask, .untilTonight, .always])
        #expect(GrantChoice.offered(for: .send, task: nil) == [.justThisOnce, .untilTonight, .always])
        for kind in [ConsequentialAction.purchase, .sharePersonalInfo] {
            #expect(GrantChoice.offered(for: kind, task: "k") == [.justThisOnce, .forThisTask])
            #expect(GrantChoice.offered(for: kind, task: nil) == [.justThisOnce])
        }
        // Asked for anyway, the issuer refuses.
        for action in [F.buy(), F.share()] {
            #expect(try F.grant(.always, for: action, task: "k") == nil)
            #expect(try F.grant(.untilTonight, for: action, task: "k") == nil)
            #expect(try F.grant(.forThisTask, for: action, task: "k") != nil)
        }
        // For this task needs a task.
        #expect(try F.grant(.forThisTask, for: F.send()) == nil)
    }

    @Test func theChoicesAreSaidInPlainWords() {
        #expect(GrantChoice.standard == .justThisOnce)
        #expect(GrantChoice.allCases.map { $0.title(for: F.sam) }
                    == ["Just this once", "For this task", "Until tonight", "Always for Sam"])
        let lines = GrantChoice.allCases.flatMap { choice in
            [choice.title(for: F.sam), GrantWords.choiceDetail(choice),
             GrantWords.promise(choice, kind: .send, handle: "sam@example.com")]
        } + GrantWords.all
        for line in lines {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
        }
    }
}

/// `AskFirst` consults the grants before it asks, and never otherwise.
struct GrantAskFirstTests {
    typealias F = GrantFixtures

    @Test func withNoGrantTheRuleAsksAsItAlwaysHas() throws {
        for rule in [AskFirst.isolated(), AskFirst.isolated(grants: .inMemory(now: { F.morning }))] {
            guard case .asking(let request) = rule.ask(F.send(), forTask: "engine/task:1") else {
                Issue.record("not asked")
                continue
            }
            #expect(request.action == F.send())
            #expect(request.task == "engine/task:1")
            #expect(!rule.isClosed(request))
            // A step that can't be asked still can't be, grant or not.
            #expect(rule.ask(F.send(to: Recipient(id: "x", displayName: "X")), forTask: "k") == .cannotAsk)
        }
    }

    @Test func aGrantLetsTheStepGoAheadAndAOnceGrantIsUsedUp() throws {
        let clock = GrantClock(F.morning)
        let book = GrantBook.inMemory(now: clock.read)
        let rule = AskFirst.isolated(grants: book)
        // Added straight to the book, as a step given a once grant ahead.
        let once = try #require(try F.grant(.justThisOnce, for: F.send()))
        book.insert(once)
        guard case .granted(let step) = rule.ask(F.send(), forTask: "k") else {
            Issue.record("not granted")
            return
        }
        #expect(step.grant == once)
        #expect(step.action == F.send())
        // Spent: the next one asks.
        guard case .asking = rule.ask(F.send(), forTask: "k") else {
            Issue.record("a once grant was used twice")
            return
        }
    }

    @Test func anExpiredUsedUpOrOtherTaskGrantDoesNotAuthorize() throws {
        let clock = GrantClock(F.morning)
        let book = GrantBook.inMemory(now: clock.read)
        let rule = AskFirst.isolated(grants: book)
        book.add(try #require(try F.grant(.untilTonight, for: F.send())))
        book.add(try #require(try F.grant(.forThisTask, for: F.send(to: F.otherSam), task: "engine/task:1")))
        guard case .granted = rule.ask(F.send(), forTask: "k") else {
            Issue.record("tonight's grant didn't cover the morning")
            return
        }
        // Another task's grant covers nothing here.
        guard case .asking = rule.ask(F.send(to: F.otherSam), forTask: "engine/task:2") else {
            Issue.record("another task's grant covered this one")
            return
        }
        // Its own task, until that ends.
        guard case .granted = rule.ask(F.send(to: F.otherSam), forTask: "engine/task:1") else {
            Issue.record("the task's grant didn't cover it")
            return
        }
        rule.taskEnded("engine/task:1")
        guard case .asking = rule.ask(F.send(to: F.otherSam), forTask: "engine/task:1") else {
            Issue.record("a task grant outlived its task")
            return
        }
        // Past midnight, tonight's grant is gone.
        clock.advance(15 * 60 * 60)
        guard case .asking = rule.ask(F.send(), forTask: "k") else {
            Issue.record("an expired grant still covered it")
            return
        }
        #expect(book.grants.isEmpty)
    }

    @Test func aRuleTakesItsBookOnceAndKeepsIt() throws {
        let rule = AskFirst.isolated()
        #expect(rule.grants == nil)
        let first = GrantBook.inMemory()
        rule.keepGrants(in: first)
        rule.keepGrants(in: .inMemory())
        #expect(rule.grants === first)
    }
}

/// A grant lets a task's step go ahead without a question, and the step
/// still writes its receipt, naming the grant.
struct GrantEngineTests {
    typealias F = GrantFixtures

    @Test func aStepAGrantAllowsStillWritesItsReceiptNamingTheGrant() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        book.add(try #require(try F.grant(.always, for: F.send())))
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning + 30)
        let id = engine.start(F.script([F.send()]))
        let task = try #require(engine.task(id))
        #expect(!task.waitsForApproval)
        #expect(task.history.last?.text == GrantWords.wentAhead)
        engine.advance(by: 3)
        #expect(engine.task(id)?.state == .done)
        let receipts = engine.takeReceipts()
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.grantedAt == F.morning)
        #expect(receipt.line == "Sent with your OK from earlier today.")
        #expect(receipt.title == "A message to Sam")
        #expect(receipt.handle == "sam@example.com")
    }

    @Test func withNoGrantTheTaskWaitsForAYesAsBefore() throws {
        let rule = AskFirst.isolated(grants: .inMemory(now: { F.morning }))
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let id = engine.start(F.script([F.send()]))
        let task = try #require(engine.task(id))
        #expect(task.waitsForApproval)
        #expect(task.question?.action == F.send())
        engine.advance(by: 10)
        #expect(engine.takeReceipts().isEmpty)
    }

    @Test func aTaskGrantCoversItsOwnLaterStepsAndEndsWithTheTask() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let id = engine.start(F.script([F.send(), F.send(to: F.sam, "Second"), F.send(to: F.sam, "Third")]))
        // The first step asks; the person says yes for this task.
        let question = try #require(engine.task(id)?.question)
        #expect(question.task != nil)
        guard case .approved(let approval) = rule.sayYes(to: question) else {
            Issue.record("no approval")
            return
        }
        book.add(try #require(GrantIssuer().issue(.forThisTask, for: approval, now: F.morning)))
        #expect(engine.resume(id, with: approval) == .proceeding)
        // The later steps go ahead without a question.
        engine.advance(by: 3)
        #expect(engine.task(id)?.waitsForApproval == false)
        engine.advance(by: 3)
        engine.advance(by: 3)
        #expect(engine.task(id)?.state == .done)
        #expect(engine.takeReceipts().map(\.grantedAt) == [nil, F.morning, F.morning])
        // Its grant ended with it.
        #expect(book.grants.isEmpty)
        // Another task, even with the same steps, asks.
        let next = engine.start(F.script([F.send()]))
        #expect(engine.task(next)?.waitsForApproval == true)
    }

    @Test func aTaskGrantNeverCoversATaskWithTheSameIdInAnotherWindow() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        let here = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let there = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let id = here.start(F.script([F.send(), F.send(to: F.sam, "Second")]))
        let question = try #require(here.task(id)?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else {
            Issue.record("no approval")
            return
        }
        book.add(try #require(GrantIssuer().issue(.forThisTask, for: approval, now: F.morning)))
        // The other window's first task has the same id, and still asks.
        let same = there.start(F.script([F.send()]))
        #expect(same == id)
        #expect(there.task(same)?.waitsForApproval == true)
    }

    @Test func aTaskStoppedEndsItsTaskGrant() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let id = engine.start(F.script([F.send(), F.send(to: F.sam, "Second")]))
        let question = try #require(engine.task(id)?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else {
            Issue.record("no approval")
            return
        }
        book.add(try #require(GrantIssuer().issue(.forThisTask, for: approval, now: F.morning)))
        #expect(book.grants.count == 1)
        engine.stop(id)
        #expect(book.grants.isEmpty)
    }

    @Test func removingAGrantTakesEffectAtOnceForATaskAlreadyRunning() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        let grant = try #require(try F.grant(.always, for: F.send()))
        book.add(grant)
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let id = engine.start(F.script([F.send(), F.send(to: F.sam, "Second")]))
        #expect(engine.task(id)?.waitsForApproval == false)
        // Removed while the first step is under way.
        #expect(book.remove(grant.id))
        engine.advance(by: 3)
        let task = try #require(engine.task(id))
        #expect(task.waitsForApproval)
        #expect(task.question?.action.details == "Second")
        // The step it covered still has its receipt, naming it.
        #expect(engine.takeReceipts().map(\.grantedAt) == [F.morning])
    }

    @Test func aGrantedStepUnderWayWhenTheAppClosedKeepsItsReceiptLine() throws {
        let book = GrantBook.inMemory(now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        book.add(try #require(try F.grant(.always, for: F.send())))
        let engine = LocalFakeEngine(rule: rule, scripts: [], origin: F.morning)
        let script = F.script([F.send()])
        engine.start(script)
        let saved = engine.saved()
        #expect(saved.first?.phase == .approved)
        #expect(saved.first?.grantedAt == F.morning)
        let later = LocalFakeEngine(rule: AskFirst.isolated(), scripts: [script], origin: F.morning + 60)
        later.restore(saved, now: F.morning + 60)
        let receipt = try #require(later.takeReceipts().first)
        #expect(receipt.grantedAt == F.morning)
        #expect(receipt.line == GrantWords.receiptMayBeDone)
    }
}

/// Where grants are kept, and Forget everything.
struct GrantStoreTests {
    typealias F = GrantFixtures

    @Test func onlyLastingGrantsAreKeptAndTheyComeBack() throws {
        let store = GrantMemoryStore()
        let book = GrantBook(store: store, now: { F.morning })
        let always = try #require(try F.grant(.always, for: F.send()))
        let tonight = try #require(try F.grant(.untilTonight, for: F.send(to: F.otherSam)))
        let task = try #require(try F.grant(.forThisTask, for: F.share(), task: "engine/task:1"))
        let once = try #require(try F.grant(.justThisOnce, for: F.send()))
        for grant in [always, tonight, task, once] { book.add(grant) }
        // The once grant is spent by the step that asked, so never added.
        #expect(Set(book.grants) == [always, tonight, task])
        // A later launch has the lasting ones only.
        let again = GrantBook(store: store, now: { F.morning })
        #expect(Set(again.grants) == [always, tonight])
    }

    @Test func whileTheStoreIsLockedKeptGrantsAllowNothingAndNothingIsWrittenOver() throws {
        let store = GrantMemoryStore()
        let always = try #require(try F.grant(.always, for: F.send()))
        GrantBook(store: store, now: { F.morning }).add(always)
        let before = store.bytes
        store.locked = true
        let book = GrantBook(store: store, now: { F.morning })
        let rule = AskFirst.isolated(grants: book)
        guard case .asking = rule.ask(F.send(), forTask: "k") else {
            Issue.record("a grant that couldn't be read let a step go")
            return
        }
        // Given while locked: held, then written with the rest once readable.
        let tonight = try #require(try F.grant(.untilTonight, for: F.send(to: F.otherSam)))
        book.add(tonight)
        #expect(store.bytes == before)
        store.locked = false
        #expect(Set(book.grants) == [always, tonight])
        #expect(Set(GrantBook(store: store, now: { F.morning }).grants) == [always, tonight])
    }

    @Test func aChangedFileCanNeverWidenAGrant() throws {
        let store = GrantMemoryStore()
        GrantBook(store: store, now: { F.morning }).add(try #require(try F.grant(.always, for: F.send())))
        let text = try #require(store.bytes.map { String(decoding: $0, as: UTF8.self) })
        // Changed into an always grant to spend money.
        store.write(Data(text.replacingOccurrences(of: "\"send\"", with: "\"purchase\"").utf8))
        #expect(GrantBook(store: store, now: { F.morning }).grants.isEmpty)
        // A file that can't be read back at all is cleared.
        store.write(Data("not json".utf8))
        let book = GrantBook(store: store, now: { F.morning })
        #expect(book.grants.isEmpty)
        #expect(store.bytes == nil)
    }

    @Test func forgetEverythingRemovesEveryGrant() throws {
        let store = GrantMemoryStore()
        let book = GrantBook(store: store, now: { F.morning })
        book.add(try #require(try F.grant(.always, for: F.send())))
        book.add(try #require(try F.grant(.forThisTask, for: F.share(), task: "engine/task:1")))
        book.forget()
        #expect(book.grants.isEmpty)
        #expect(store.bytes == nil)
        #expect(GrantBook(store: store, now: { F.morning }).grants.isEmpty)
        let rule = AskFirst.isolated(grants: book)
        guard case .asking = rule.ask(F.send(), forTask: "k") else {
            Issue.record("a forgotten grant let a step go")
            return
        }
    }

    @Test(.scratchFiles) func theFileHasCompleteProtectionAndForgetDeletesIt() throws {
        #expect(GrantFileStore.fileWriting(protected: true).contains(.completeFileProtection))
        #expect(!GrantFileStore.fileWriting(protected: false).contains(.completeFileProtection))
        let base = Scratch.url("grants").deletingPathExtension()
        let (file, marker) = GrantFileStore.location(base: base, app: "kept-tasks")
        let store = GrantFileStore(fileURL: file, forgetMarker: marker)
        let book = GrantBook(store: store, now: { F.morning })
        let always = try #require(try F.grant(.always, for: F.send()))
        book.add(always)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { F.morning }).grants == [always])
        book.forget()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(GrantBook(store: GrantFileStore(fileURL: file, forgetMarker: marker), now: { F.morning }).grants.isEmpty)
    }
}

extension GrantWords {
    /// Every fixed line, for the dash check.
    static var all: [String] {
        [choiceHeading, justThisOnce, forThisTask, untilTonight, always("Sam"), listTitle, listDetail, listEmpty,
         removeTitle, removeLabel(.send, "Sam"), removed, alwaysLine, whileTaskRuns, untilMidnight, wentAhead,
         receiptLine(.send, sameDay: true), receiptLine(.purchase, sameDay: false),
         receiptLine(.sharePersonalInfo, sameDay: true), receiptMayBeDone,
         title(.send, "Sam"), title(.purchase, "Rise Bakery"), title(.sharePersonalInfo, "Maple Dental")]
    }
}
