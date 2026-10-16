import PebbleCore
import Testing

struct AskFirstTests {
    let rule = AskFirst()
    let note = ProposedAction(kind: .send, recipient: "Sam", details: "Running ten minutes late")

    @Test(arguments: ConsequentialAction.allCases)
    func everyKindNeedsAQuestion(_ kind: ConsequentialAction) {
        #expect(rule.needsQuestion(kind))
    }

    @Test(arguments: ConsequentialAction.allCases)
    func withoutAnAnswerNothingHappens(_ kind: ConsequentialAction) {
        let action = ProposedAction(kind: kind, recipient: "the bakery", details: "x")
        #expect(rule.decide(action, answer: nil, answeredFor: nil) == .stop)
        #expect(rule.decide(action, answer: nil, answeredFor: action) == .stop)
    }

    @Test func aYesForTheShownActionLetsItHappen() {
        #expect(rule.decide(note, answer: .approved, answeredFor: note) == .proceed)
    }

    @Test func aNoStopsIt() {
        #expect(rule.decide(note, answer: .declined, answeredFor: note) == .stop)
    }

    @Test func aYesWithoutKnowingWhatWasShownStopsIt() {
        #expect(rule.decide(note, answer: .approved, answeredFor: nil) == .stop)
    }

    @Test func aYesDoesNotCarryOverToChangedDetails() {
        let changed = ProposedAction(kind: .send, recipient: "Sam", details: "My home address is 12 Elm St")
        #expect(rule.decide(changed, answer: .approved, answeredFor: note) == .stop)
    }

    @Test func aYesDoesNotCarryOverToSomeoneElse() {
        let other = ProposedAction(kind: .send, recipient: "a buyer", details: note.details)
        #expect(rule.decide(other, answer: .approved, answeredFor: note) == .stop)
    }

    @Test func aYesToSendDoesNotCoverSharingOrBuying() {
        let share = ProposedAction(kind: .sharePersonalInfo, recipient: "Sam", details: note.details)
        let buy = ProposedAction(kind: .purchase, recipient: "Sam", details: note.details)
        #expect(rule.decide(share, answer: .approved, answeredFor: note) == .stop)
        #expect(rule.decide(buy, answer: .approved, answeredFor: note) == .stop)
    }

    @Test func theQuestionNamesWhoItGoesTo() {
        #expect(note.question == "Send this to Sam?")
        #expect(ProposedAction(kind: .purchase, recipient: "the bakery", details: "").question == "Buy this from the bakery?")
        #expect(ProposedAction(kind: .sharePersonalInfo, recipient: "a buyer", details: "").question == "Share this with a buyer?")
    }

    @Test func theWordsUseNoDashes() {
        let words = [ProposedAction.yesTitle, ProposedAction.noTitle, ProposedAction.declined, note.question]
        for line in words {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
        }
    }
}
