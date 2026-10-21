import Foundation
@testable import PebbleCore
import Testing

/// The names and private words are compiled once, when the redactor is
/// made, not for every message of every request.
struct RedactorPatternTests {
    /// Counts what is built while the redactor is made and then while it
    /// redacts many messages: everything is built up front, nothing after.
    @Test func eachWordIsCompiledOncePerRedactor() {
        let builds = WordPatterns.BuildCount()
        WordPatterns.$builds.withValue(builds) {
            let redactor = Redactor(names: ["Sam", "Priya", "sam"], privateWords: ["lemon cake"])
            let made = builds.value
            #expect(made == redactor.names.count + redactor.privateWords.count)
            #expect(redactor.patterns.names.count == redactor.names.count)
            #expect(redactor.patterns.privateWords.count == redactor.privateWords.count)
            for text in ["Ask Sam", "Priya’s lemon cake", "Sam and Priya", "nothing here"] {
                _ = redactor.redact(text)
            }
            #expect(builds.value == made, "redacting built patterns again")
        }
    }

    @Test func compiledPatternsHideTheSameAsBefore() {
        let redactor = Redactor(names: ["O'Brien"], privateWords: ["lemon cake", "cake shop"])
        #expect(redactor.redact("Ask O’Brien about the lemon cake shop.").text == "Ask [name] about the [private].")
        #expect(redactor.redact("LEMON CAKE").text == "[private]")
    }

    /// A plural s and hyphens are folded in, as the setting's words say.
    @Test func aPluralOrAHyphenatedSpellingIsHiddenToo() {
        let redactor = Redactor(names: ["Sam"], privateWords: ["lemon cake", "Anne-Marie"])
        #expect(redactor.redact("lemon cakes").text == "[private]")
        #expect(redactor.redact("two lemon-cakes, please").text == "two [private], please")
        #expect(redactor.redact("Lemon - cake").text == "[private]")
        #expect(redactor.redact("Anne Marie and Anne-Marie").text == "[private] and [private]")
        #expect(redactor.redact("Sams and Sam's").text == "[name] and [name]'s")
        // Still whole words: a longer word that starts the same stays.
        #expect(redactor.redact("Samson and lemon cakery").text == "Samson and lemon cakery")
    }

    /// What the setting admits it can miss: a joined or other spelling.
    @Test func anotherSpellingCanStillSlipBy() {
        let redactor = Redactor(privateWords: ["lemon cake"])
        #expect(redactor.redact("lemoncake").text == "lemoncake")
        #expect(CloudWords.privateDetail.hasPrefix("I take these out of anything I send, but I can miss another spelling, so check what I show you."))
    }

    /// Plurals fold a trailing s only. "Parties" and "boxes" slip by, a
    /// known gap the copy and the preview cover. Pinned, so a change that
    /// widens the fold is a decision rather than an accident: a looser one
    /// would start hiding words nobody asked to hide.
    @Test func aPluralOtherThanATrailingSSlipsBy() {
        let redactor = Redactor(privateWords: ["party", "box"])
        #expect(redactor.redact("two partys").text == "two [private]")
        #expect(redactor.redact("two parties").text == "two parties")
        #expect(redactor.redact("two boxes").text == "two boxes")
        #expect(redactor.redact("two boxs").text == "two [private]")
    }

    /// A word of nothing but hyphens hides nothing, rather than everything.
    @Test func aWordOfOnlyHyphensHidesNothing() {
        let redactor = Redactor(privateWords: ["-", "--"])
        #expect(redactor.patterns.privateWords.isEmpty)
        #expect(redactor.redact("Plan my week").text == "Plan my week")
    }

    /// A word of nothing but spaces hides nothing either.
    @Test func aWordOfOnlyWhitespaceHidesNothing() {
        let redactor = Redactor(privateWords: [" ", "\t\n", "  -  "])
        #expect(redactor.patterns.privateWords.isEmpty)
        #expect(redactor.redact("Plan my week").text == "Plan my week")
    }

    /// Two redactors with the same words are equal, whatever their patterns.
    @Test func equalityIsByTheWords() {
        #expect(Redactor(names: ["Sam"]) == Redactor(names: ["Sam"]))
        #expect(Redactor(names: ["Sam"]) != Redactor(names: ["Ana"]))
        #expect(Redactor(names: ["Sam"]).union(Redactor(privateWords: ["tea"]))
            == Redactor(names: ["Sam"], privateWords: ["tea"]))
    }
}
