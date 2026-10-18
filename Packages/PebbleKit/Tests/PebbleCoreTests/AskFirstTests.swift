import Foundation
@testable import PebbleCore
import SourceScan
import Testing

struct AskFirstTests {
    let sam = Recipient(id: "contact:1/sms:+14165550101", displayName: "Sam", handle: "416 555 0101")
    var note: ProposedAction { ProposedAction(kind: .send, recipient: sam, details: "Running ten minutes late") }
    let bakery = Recipient(id: "merchant:bakery-42", displayName: "the bakery", handle: "risebakery.example")
    let cad850 = Price(minorUnits: 850, currency: "CAD")!
    let en = Locale(identifier: "en_CA")

    @Test(arguments: ConsequentialAction.allCases)
    func withoutAnApprovalNothingHappens(_ kind: ConsequentialAction) {
        let rule = AskFirst.isolated()
        let action = ProposedAction(kind: kind, recipient: bakery, details: "x", price: cad850)
        _ = rule.ask(action)
        #expect(rule.decide(action, approval: nil) == .stop)
    }

    /// The rule keeps only ids and times, never what it asked about: while
    /// a question is open, once it times out, and once it is closed by a
    /// no or a yes. So Forget everything leaves no note's words in it.
    /// The probe walks the rule itself, every stored property and all
    /// they hold, and is shown to reach them: it finds the very ids the
    /// rule holds. Any text at all, or any question or action, fails.
    @Test func theRuleKeepsOnlyIdsAndTimes() throws {
        final class Clock: @unchecked Sendable {
            var now = ContinuousClock.now
        }
        let clock = Clock()
        let rule = AskFirst.isolated(now: { clock.now })
        let words = ["Sam's birthday is May 14", "Door code 4417", "Dentist on Thursday at 3", "Lemon cake on Friday"]
        func ask(_ text: String) throws -> ConfirmationRequest {
            try #require(rule.ask(DigestTask.keep(DigestWords.heading + ".\n• " + text)))
        }
        // The probe does find words where they are, of each kind it reads.
        let open = try ask(words[0])
        #expect(StoredWords(in: open).contains(words[0]))
        #expect(StoredWords(in: Substring(words[0])).contains(words[0]))
        #expect(StoredWords(in: Data(words[0].utf8)).contains(words[0]))
        #expect(StoredWords(in: words[0] as NSString).contains(words[0]))
        #expect(StoredWords(in: Array(words[0])).contains(words[0]))

        func expectNoWords(_ when: String, holding ids: [UUID]) {
            let found = StoredWords(in: rule)
            for id in ids { #expect(found.ids.contains(id), "\(when): the probe didn't reach \(id)") }
            #expect(found.texts.isEmpty, "\(when): text in the rule: \(found.texts)")
            for type in Self.questionTypes { #expect(!found.holds(type), "\(when): a \(type) is in the rule") }
            for word in words + [DigestWords.heading, DigestTask.notes.displayName, MemoryWords.title] {
                #expect(!found.contains(word), "\(when): \(word) is in the rule")
            }
        }

        // Open.
        expectNoWords("open", holding: [open.id])

        // Timed out, before anything looks at it again.
        clock.now += .seconds(AskFirst.defaultWindow + 1)
        expectNoWords("timed out", holding: [open.id])
        #expect(rule.isClosed(open))

        // Closed by a no, and by a yes spent.
        let declined = try ask(words[1])
        rule.withdraw(declined)
        #expect(rule.wasWithdrawn(declined))
        let approved = try ask(words[2])
        guard case .approved(let yes) = rule.sayYes(to: approved) else { Issue.record("no approval"); return }
        expectNoWords("yes given", holding: [approved.id])
        #expect(rule.decide(approved.action, approval: yes) == .proceed)
        let stillOpen = try ask(words[3])
        expectNoWords("closed", holding: [declined.id, stillOpen.id])
        // The spent yes was reached above while it was held. Spent, not
        // even its id is left.
        #expect(!StoredWords(in: rule).ids.contains(approved.id))
        #expect([declined, approved].allSatisfy(rule.isClosed))
    }

    /// An empty list of any kind is no text, so it can't stand in for
    /// words a probe was meant to reach.
    @Test func anEmptyListIsNoText() {
        for value: Any in [[Int](), [UUID](), [String](), [Character]()] {
            #expect(StoredWords(in: value).texts.isEmpty, "\(type(of: value))")
        }
        #expect(StoredWords(in: Array("words")).texts == ["words"])
    }

    /// Kinds of value that carry what a question was about.
    static let questionTypes = ["ProposedAction", "ConfirmationRequest", "Approval", "Recipient"]

    /// The probe above can fail: a rule that kept a question, or only its
    /// action, in any stored property, under a lock like the real one, is
    /// caught by its words and by its kind.
    @Test func theProbeFindsAQuestionKeptAnywhereInARule() throws {
        final class Leaky: @unchecked Sendable {
            private let lock = NSLock()
            private var pending: [UUID: ContinuousClock.Instant] = [:]
            private var recent: [ProposedAction] = []
            private var asked: [UUID: ConfirmationRequest] = [:]
            init(_ request: ConfirmationRequest, keepsAction: Bool) {
                lock.lock()
                pending[request.id] = .now
                if keepsAction { recent.append(request.action) } else { asked[request.id] = request }
                lock.unlock()
            }
        }
        let rule = AskFirst.isolated()
        let request = try #require(rule.ask(DigestTask.keep(DigestWords.heading + ".\n• Door code 4417")))
        for keepsAction in [true, false] {
            let found = StoredWords(in: Leaky(request, keepsAction: keepsAction))
            #expect(found.ids.contains(request.id))
            #expect(found.contains("Door code 4417"))
            #expect(!found.texts.isEmpty)
            #expect(found.holds("ProposedAction"))
            if !keepsAction { #expect(found.holds("ConfirmationRequest")) }
        }
        // And the real rule, holding that very question open, has none.
        let real = StoredWords(in: rule)
        #expect(real.ids.contains(request.id))
        #expect(real.texts.isEmpty)
        #expect(!Self.questionTypes.contains(where: real.holds))
    }

    @Test func aYesForTheAskedActionLetsItHappenOnce() {
        let rule = AskFirst.isolated()
        let approval = rule.ask(note)!.approve()
        #expect(rule.decide(note, approval: approval) == .proceed)
        #expect(rule.decide(note, approval: approval) == .stop)
    }

    @Test func tappingYesTwiceStillApprovesOnce() {
        let rule = AskFirst.isolated()
        let request = rule.ask(note)!
        let first = request.approve()
        let second = request.approve()
        #expect(first == second)
        #expect(rule.decide(note, approval: first) == .proceed)
        #expect(rule.decide(note, approval: second) == .stop)
    }

    @Test func anApprovalFromAnotherRuleIsNotHonored() {
        let asked = AskFirst.isolated()
        let other = AskFirst.isolated()
        let approval = asked.ask(note)!.approve()
        #expect(other.decide(note, approval: approval) == .stop)
        #expect(asked.decide(note, approval: approval) == .proceed)
    }

    @Test func aWithdrawnQuestionCannotBeApprovedLater() {
        let rule = AskFirst.isolated()
        let request = rule.ask(note)!
        rule.withdraw(request)
        #expect(rule.decide(note, approval: request.approve()) == .stop)
    }

    @Test func aSecondSendNeedsASecondYes() {
        let rule = AskFirst.isolated()
        #expect(rule.decide(note, approval: rule.ask(note)!.approve()) == .proceed)
        #expect(rule.decide(note, approval: rule.ask(note)!.approve()) == .proceed)
    }

    @Test func aYesDoesNotCarryOverToChangedDetails() {
        let rule = AskFirst.isolated()
        let changed = ProposedAction(kind: .send, recipient: sam, details: "My home address is 12 Elm St")
        #expect(rule.decide(changed, approval: rule.ask(note)!.approve()) == .stop)
    }

    @Test func anotherPersonWithTheSameNameIsSomeoneElseAndLooksDifferent() {
        let rule = AskFirst.isolated()
        let otherSam = Recipient(id: "contact:9/sms:+14165550199", displayName: "Sam", handle: "416 555 0199")
        let other = ProposedAction(kind: .send, recipient: otherSam, details: note.details)
        #expect(other.question != note.question)
        #expect(rule.decide(other, approval: rule.ask(note)!.approve()) == .stop)
    }

    @Test func aYesToSendDoesNotCoverSharingOrBuying() {
        let rule = AskFirst.isolated()
        let share = ProposedAction(kind: .sharePersonalInfo, recipient: sam, details: note.details)
        let buy = ProposedAction(kind: .purchase, recipient: sam, details: note.details, price: cad850)
        #expect(rule.decide(share, approval: rule.ask(note)!.approve()) == .stop)
        #expect(rule.decide(buy, approval: rule.ask(note)!.approve()) == .stop)
    }

    @Test func aPriceChangeAfterTheYesStopsThePurchase() {
        let rule = AskFirst.isolated()
        let shown = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: cad850)
        let pricier = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: Price(minorUnits: 8500, currency: "CAD"))
        let otherCurrency = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: Price(minorUnits: 850, currency: "USD"))
        #expect(rule.decide(pricier, approval: rule.ask(shown)!.approve()) == .stop)
        #expect(rule.decide(otherCurrency, approval: rule.ask(shown)!.approve()) == .stop)
        #expect(rule.decide(shown, approval: rule.ask(shown)!.approve()) == .proceed)
    }

    @Test func aPurchaseWithoutAPriceIsNeverAsked() {
        let rule = AskFirst.isolated()
        let vague = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough")
        #expect(rule.ask(vague) == nil)
    }

    @Test func aDifferentHandleOrNameForTheSameIdStops() {
        let rule = AskFirst.isolated()
        let approval = rule.ask(note)!.approve()
        let rehandled = ProposedAction(kind: .send, recipient: Recipient(id: sam.id, displayName: "Sam", handle: "416 555 9999"), details: note.details)
        let renamed = ProposedAction(kind: .send, recipient: Recipient(id: sam.id, displayName: "Mom", handle: sam.handle), details: note.details)
        #expect(rule.decide(rehandled, approval: approval) == .stop)
        #expect(rule.decide(renamed, approval: approval) == .stop)
    }

    @Test func detailsWithHiddenCharactersAreNeverAsked() {
        let rule = AskFirst.isolated()
        let tricky = ProposedAction(kind: .send, recipient: sam, details: "Pay \u{202E}001$ to me")
        #expect(rule.ask(tricky) == nil)
        let plain = ProposedAction(kind: .send, recipient: sam, details: "Line one\nLine two")
        #expect(rule.ask(plain) != nil)
        for hidden in ["hi\u{FE01}\u{FE02}", "hi\u{E0100}", "hi\u{3164}", "hi\u{2800}", "hi\u{115F}"] {
            #expect(rule.ask(ProposedAction(kind: .send, recipient: sam, details: hidden)) == nil, "\(hidden.unicodeScalars.map { $0.value })")
        }
        for fine in ["See you \u{2764}\u{FE0F}", "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "Caf\u{00E9} at 9"] {
            #expect(rule.ask(ProposedAction(kind: .send, recipient: sam, details: fine)) != nil)
        }
        #expect(Recipient(id: "h", displayName: "x", handle: "evil\u{FE0F}.com").handle == nil)
    }

    @Test(arguments: ["Sam at 416 555 0101", "Mom at family.ca", "mom\u{FF20}family.ca", "the bakery for $1.00"])
    func aNameNeverAppearsInTheQuestion(_ name: String) {
        let r = Recipient(id: "x", displayName: name, handle: "evil.net")
        let send = ProposedAction(kind: .send, recipient: r, details: "hi")
        let buy = ProposedAction(kind: .purchase, recipient: r, details: "hi", price: Price(minorUnits: 8500, currency: "CAD"))
        #expect(send.question == "Send this to evil.net?")
        #expect(buy.question(locale: en) == "Pay $85.00 to evil.net?")
    }

    @Test(arguments: ["evil\u{200B}.com", " evil.com", "evil  .com", "evil.com\n"])
    func handlesThatNeedCleaningAreRefused(_ raw: String) {
        let r = Recipient(id: "x", displayName: "Rise", handle: raw)
        #expect(r.handle == nil)
        #expect(AskFirst.isolated().ask(ProposedAction(kind: .send, recipient: r, details: "hi")) == nil)
    }

    @Test func longHandlesAreNeverShortened() {
        let tail = "accounts.risebakery.example.billing-secure-example.net"
        let r = Recipient(id: "x", displayName: "Rise", handle: tail)
        #expect(r.handle == tail)
        #expect(Recipient(id: "y", displayName: "x", handle: String(repeating: "a", count: Recipient.maxHandleLength + 1)).handle == nil)
    }

    @Test(arguments: ConsequentialAction.allCases)
    func aQuestionThatCantSayWhereItGoesIsNeverAsked(_ kind: ConsequentialAction) {
        let rule = AskFirst.isolated()
        let price = Price(minorUnits: 100, currency: "CAD")
        let noHandle = ProposedAction(kind: kind, recipient: Recipient(id: "c:1", displayName: "Sam"), details: "x", price: price)
        let tooLong = ProposedAction(kind: kind, recipient: Recipient(id: "c:2", displayName: "Sam",
            handle: String(repeating: "a", count: Recipient.maxHandleLength + 1)), details: "x", price: price)
        #expect(rule.ask(noHandle) == nil)
        #expect(rule.ask(tooLong) == nil)
    }

    @Test func pricesMustBeRealAmounts() {
        #expect(Price(minorUnits: 0, currency: "CAD") == nil)
        #expect(Price(minorUnits: -5, currency: "CAD") == nil)
        #expect(Price(minorUnits: 5, currency: "") == nil)
        #expect(Price(minorUnits: 5, currency: "CA$") == nil)
        #expect(Price(minorUnits: 5, currency: " cad ")?.currency == "CAD")
    }

    @Test func pricesUseEachCurrencysOwnDecimals() {
        #expect(Price(minorUnits: 1450, currency: "JPY")!.fractionDigits == 0)
        #expect(Price(minorUnits: 1450, currency: "CAD")!.fractionDigits == 2)
        #expect(Price(minorUnits: 1450, currency: "KWD")!.fractionDigits == 3)
        #expect(Price(minorUnits: 1450, currency: "JPY")!.formatted(locale: Locale(identifier: "en_US")).contains("1,450"))
        #expect(Price(minorUnits: 1450, currency: "CAD")!.formatted(locale: en).contains("14.50"))
    }

    @Test func theQuestionNamesWhoAndHowMuch() {
        #expect(note.question == "Send this to 416 555 0101?")
        let buy = ProposedAction(kind: .purchase, recipient: bakery, details: "", price: cad850)
        #expect(buy.question(locale: en) == "Pay $8.50 to risebakery.example?")
        let buyer = Recipient(id: "x", displayName: "a buyer", handle: "buyer@example.com")
        #expect(ProposedAction(kind: .sharePersonalInfo, recipient: buyer, details: "").question == "Share this with buyer@example.com?")
    }

    @Test func oddRecipientNamesAreTidiedForTheQuestion() {
        let long = Recipient(id: "x", displayName: "  Sam \n\n" + String(repeating: "z", count: 80))
        #expect(!long.displayName.contains("\n"))
        #expect(long.displayName.count <= Recipient.maxDisplayLength + 3)
        #expect(Recipient(id: "y", displayName: "  ").displayName == "someone")
        let sneaky = Recipient(id: "z", displayName: "Mom\u{202E}\u{200B}")
        #expect(sneaky.displayName == "Mom")
    }

    @Test func theWordsUseNoDashes() {
        let words = [ProposedAction.yesTitle, ProposedAction.noTitle, ProposedAction.declined, note.question]
        for line in words {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
        }
    }
}

/// A permanent gate: only the confirmation sheet may turn a question into
/// an approval. Any other caller of `approve()` in the sources fails here.
struct AskFirstGateTests {
    @Test func onlyTheConfirmationSheetApproves() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: Set<String> = ["PebbleCore/AskFirst.swift", "PebbleUI/ConfirmationSheet.swift"]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let pattern = try NSRegularExpression(pattern: "\\.\\s*approve\\b")
        for file in files {
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            if allowed.contains(relative) { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hits == 0, "approve called from \(relative)")
        }
    }
}
