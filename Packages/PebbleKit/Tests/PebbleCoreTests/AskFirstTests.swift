import PebbleCore
import Testing

struct AskFirstTests {
    let sam = Recipient(id: "contact:1/sms:+14165550101", displayName: "Sam")
    var note: ProposedAction { ProposedAction(kind: .send, recipient: sam, details: "Running ten minutes late") }
    let bakery = Recipient(id: "merchant:bakery-42", displayName: "the bakery")

    func yes(_ action: ProposedAction) -> Approval { ConfirmationRequest(action: action).approve() }

    @Test(arguments: ConsequentialAction.allCases)
    func withoutAnApprovalNothingHappens(_ kind: ConsequentialAction) {
        let action = ProposedAction(kind: kind, recipient: bakery, details: "x", price: Price(minorUnits: 500, currency: "cad"))
        #expect(AskFirst().decide(action, approval: nil) == .stop)
    }

    @Test func aYesForTheShownActionLetsItHappenOnce() {
        let rule = AskFirst()
        let approval = yes(note)
        #expect(rule.decide(note, approval: approval) == .proceed)
        #expect(rule.decide(note, approval: approval) == .stop)
    }

    @Test func aSecondSendNeedsASecondYes() {
        let rule = AskFirst()
        #expect(rule.decide(note, approval: yes(note)) == .proceed)
        #expect(rule.decide(note, approval: yes(note)) == .proceed)
    }

    @Test func aYesDoesNotCarryOverToChangedDetails() {
        let changed = ProposedAction(kind: .send, recipient: sam, details: "My home address is 12 Elm St")
        #expect(AskFirst().decide(changed, approval: yes(note)) == .stop)
    }

    @Test func anotherPersonWithTheSameNameIsSomeoneElse() {
        let otherSam = Recipient(id: "contact:9/sms:+14165550199", displayName: "Sam")
        let other = ProposedAction(kind: .send, recipient: otherSam, details: note.details)
        #expect(other.question == note.question)
        #expect(AskFirst().decide(other, approval: yes(note)) == .stop)
    }

    @Test func aYesToSendDoesNotCoverSharingOrBuying() {
        let share = ProposedAction(kind: .sharePersonalInfo, recipient: sam, details: note.details)
        let buy = ProposedAction(kind: .purchase, recipient: sam, details: note.details, price: Price(minorUnits: 1, currency: "CAD"))
        #expect(AskFirst().decide(share, approval: yes(note)) == .stop)
        #expect(AskFirst().decide(buy, approval: yes(note)) == .stop)
    }

    @Test func aPriceChangeAfterTheYesStopsThePurchase() {
        let shown = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: Price(minorUnits: 850, currency: "CAD"))
        let pricier = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: Price(minorUnits: 8500, currency: "CAD"))
        let otherCurrency = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough", price: Price(minorUnits: 850, currency: "USD"))
        #expect(AskFirst().decide(pricier, approval: yes(shown)) == .stop)
        #expect(AskFirst().decide(otherCurrency, approval: yes(shown)) == .stop)
        #expect(AskFirst().decide(shown, approval: yes(shown)) == .proceed)
    }

    @Test func aPurchaseWithoutAPriceIsNeverApproved() {
        let vague = ProposedAction(kind: .purchase, recipient: bakery, details: "Sourdough")
        #expect(AskFirst().decide(vague, approval: yes(vague)) == .stop)
    }

    @Test func theQuestionNamesWhoItGoesTo() {
        #expect(note.question == "Send this to Sam?")
        #expect(ProposedAction(kind: .purchase, recipient: bakery, details: "").question == "Buy this from the bakery?")
        let buyer = Recipient(id: "x", displayName: "a buyer")
        #expect(ProposedAction(kind: .sharePersonalInfo, recipient: buyer, details: "").question == "Share this with a buyer?")
    }

    @Test func oddRecipientNamesAreTidiedForTheQuestion() {
        let long = Recipient(id: "x", displayName: "  Sam \n\n" + String(repeating: "z", count: 80))
        #expect(!long.displayName.contains("\n"))
        #expect(long.displayName.count <= Recipient.maxDisplayLength + 3)
        #expect(Recipient(id: "y", displayName: "  ").displayName == "someone")
    }

    @Test func theWordsUseNoDashes() {
        let words = [ProposedAction.yesTitle, ProposedAction.noTitle, ProposedAction.declined, note.question]
        for line in words {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
        }
    }
}
