import Foundation
@testable import PebbleCore
import Testing

struct AskFirstTests {
    let sam = Recipient(id: "contact:1/sms:+14165550101", displayName: "Sam", handle: "416 555 0101")
    var note: ProposedAction { ProposedAction(kind: .send, recipient: sam, details: "Running ten minutes late") }
    let bakery = Recipient(id: "merchant:bakery-42", displayName: "the bakery", handle: "risebakery.ca")
    let cad850 = Price(minorUnits: 850, currency: "CAD")!
    let en = Locale(identifier: "en_CA")

    @Test(arguments: ConsequentialAction.allCases)
    func withoutAnApprovalNothingHappens(_ kind: ConsequentialAction) {
        let rule = AskFirst.isolated()
        let action = ProposedAction(kind: kind, recipient: bakery, details: "x", price: cad850)
        _ = rule.ask(action)
        #expect(rule.decide(action, approval: nil) == .stop)
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
        let tail = "accounts.risebakery.ca.billing-secure-example.net"
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
        #expect(buy.question(locale: en) == "Pay $8.50 to risebakery.ca?")
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
