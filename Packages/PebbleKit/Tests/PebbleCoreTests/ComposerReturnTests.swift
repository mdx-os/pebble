import Testing
@testable import PebbleCore

struct ComposerReturnTests {
    @Test func aLoneReturnAtTheEndSends() {
        #expect(ComposerReturn.textToSend(old: "Pack lunches", new: "Pack lunches\n") == "Pack lunches")
    }

    @Test func aLoneReturnInTheMiddleSendsWhatWasThere() {
        #expect(ComposerReturn.textToSend(old: "Pack lunches", new: "Pack\n lunches") == "Pack lunches")
    }

    @Test func aReturnInAnEmptyFieldSendsNothingToSpeakOf() {
        #expect(ComposerReturn.textToSend(old: "", new: "\n") == "")
    }

    @Test(arguments: [
        ("Pack", "Pack l"),                     // typing
        ("Pack lunches", "Pack lunche"),        // deleting
        ("", "first line\nsecond line"),        // pasting several lines
        ("Pack", "Pack\n\n"),                   // more than one break at once
        ("Pack", "Pick"),                       // a correction
    ])
    func otherEditsAreJustEdits(old: String, new: String) {
        #expect(ComposerReturn.textToSend(old: old, new: new) == nil)
    }

    @Test(arguments: [
        ("Pack lunhces", "Pack lunches\n"),     // autocorrect swaps the last word as Return lands
        ("Pack lunhces", "Pack lunches \n"),    // with the trailing space some keyboards add
        ("teh", "the\n"),
    ])
    func returnWithAPendingCorrectionSendsTheCorrection(old: String, new: String) {
        #expect(ComposerReturn.textToSend(old: old, new: new) == String(new.dropLast()))
    }

    @Test(arguments: [
        ("Pack", "Pack then walk\n"),           // a pasted phrase ending in a break
        ("Pack lunches", "Pick lunches\n"),     // a change before the last word
        ("Pack\n", "Pack\nx\n"),               // the draft already ended in a break
    ])
    func otherBreaksAtTheEndStayEdits(old: String, new: String) {
        #expect(ComposerReturn.textToSend(old: old, new: new) == nil)
    }

    @Test func newChatWordsHaveNoDashes() {
        for line in [HomeWords.newChatQuestion, HomeWords.newChatDetail, HomeWords.newChatConfirm, HomeWords.cancelTitle] {
            #expect(!line.isEmpty && !line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(line)")
        }
    }

    @Test func existingLineBreaksStay() {
        let old = "Pack lunches\nthen walk"
        #expect(ComposerReturn.textToSend(old: old, new: old + "\n") == old)
    }
}

struct HomeWordsTests {
    @Test func everyPlaceHasAWarmTitleAndASymbol() {
        for place in HomeSection.allCases {
            #expect(!place.title.isEmpty)
            #expect(!place.symbol.isEmpty)
        }
        #expect(HomeSection.memory.title == MemoryWords.title)
    }

    @Test func shortcutWordsHaveNoDashes() {
        let words = [HomeWords.chatTitle, HomeWords.newChatTitle, HomeWords.goMenuTitle, HomeWords.shortcutsTitle]
            + HomeWords.shortcuts.flatMap { [$0.keys, $0.action] }
        for line in words {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(line)")
        }
    }

    @Test func eachShortcutIsListedOnce() {
        let actions = HomeWords.shortcuts.map(\.action)
        #expect(Set(actions).count == actions.count)
        #expect(actions.contains(HomeWords.newChatTitle))
        #expect(actions.contains(HomeWords.newLineShortcut))
    }
}
