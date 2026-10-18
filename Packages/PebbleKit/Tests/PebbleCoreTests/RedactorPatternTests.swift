import Foundation
@testable import PebbleCore
import Testing

/// The names and private words are compiled once, when the redactor is
/// made, not for every message of every request.
struct RedactorPatternTests {
    @Test func eachWordIsCompiledOncePerRedactor() {
        let redactor = Redactor(names: ["Sam", "Priya", "sam"], privateWords: ["lemon cake"])
        #expect(redactor.patterns.names.count == redactor.names.count)
        #expect(redactor.patterns.privateWords.count == redactor.privateWords.count)
        let before = redactor.patterns.names + redactor.patterns.privateWords
        // Redacting many messages builds nothing new.
        for text in ["Ask Sam", "Priya’s lemon cake", "Sam and Priya", "nothing here"] {
            _ = redactor.redact(text)
        }
        let copy = redactor
        let after = copy.patterns.names + copy.patterns.privateWords
        #expect(before.count == after.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }

    @Test func compiledPatternsHideTheSameAsBefore() {
        let redactor = Redactor(names: ["O'Brien"], privateWords: ["lemon cake", "cake shop"])
        #expect(redactor.redact("Ask O’Brien about the lemon cake shop.").text == "Ask [name] about the [private].")
        #expect(redactor.redact("LEMON CAKE").text == "[private]")
        #expect(redactor.redact("lemon cakes").text == "lemon cakes")
    }

    /// Two redactors with the same words are equal, whatever their patterns.
    @Test func equalityIsByTheWords() {
        #expect(Redactor(names: ["Sam"]) == Redactor(names: ["Sam"]))
        #expect(Redactor(names: ["Sam"]) != Redactor(names: ["Ana"]))
        #expect(Redactor(names: ["Sam"]).union(Redactor(privateWords: ["tea"]))
            == Redactor(names: ["Sam"], privateWords: ["tea"]))
    }
}
