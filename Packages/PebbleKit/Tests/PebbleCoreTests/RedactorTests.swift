import Foundation
import PebbleCore
import Testing

struct RedactorTests {
    static let notes = [
        MemoryNote(text: "Sam's birthday is May 14. Loves lemon cake.", source: .toldMe),
        MemoryNote(text: "Dentist on Thursday at 3", source: .fromApp("Calendar")),
        MemoryNote(text: "Lunch with Priya and Ana every Friday", source: .toldMe),
        MemoryNote(text: "Prefers tea in the afternoon", source: .inferred),
    ]

    // MARK: Names from memory

    @Test func findsNamesInNotesButNotMonthsDaysOrSentenceStarts() {
        let names = Redactor.names(in: Self.notes)
        #expect(names == ["Sam", "Priya", "Ana"])
    }

    @Test func hidesNamesFromMemoryInAnyCaseAndKeepsPossessives() {
        let redactor = Redactor(memory: Self.notes)
        let out = redactor.redact("Remind me to call Sam, and ask priya about Sam's gift.")
        #expect(out.text == "Remind me to call [name], and ask [name] about [name]'s gift.")
        #expect(out.hidden == [.name: 3])
    }

    /// The most common way notes are written: the name starts the sentence.
    @Test(arguments: [
        ("Priya is my sister.", ["Priya"]),
        ("Sam loves lemon cake.", ["Sam"]),
        ("Gym at 6. Ana works nights, so text after 9.", ["Ana"]),
        ("Dentist is at 3. Lunch with the team.", []),
        ("Meeting moved to Monday. Prefers tea.", []),
    ])
    func findsNamesThatStartASentence(note: String, expected: [String]) {
        #expect(Redactor.names(in: [MemoryNote(text: note, source: .toldMe)]) == expected)
    }

    @Test func findsNamesWithCapitalsInside() {
        let notes = [MemoryNote(text: "Dinner with Liam O'Brien, Ronan McDonald and DeShawn. Call Anne-Marie.", source: .toldMe)]
        #expect(Redactor.names(in: notes) == ["Liam", "O'Brien", "Ronan", "McDonald", "DeShawn", "Anne-Marie"])
        let out = Redactor(memory: notes).redact("Tell o\u{2019}brien and mcdonald I said hi.")
        #expect(out.text == "Tell [name] and [name] I said hi.")
    }

    @Test func findsLowercaseNamesAfterAFamilyWordOrNamed() {
        let notes = [
            MemoryNote(text: "lunch with my sister priya on sundays", source: .toldMe),
            MemoryNote(text: "our neighbour jo waters the plants", source: .toldMe),
            MemoryNote(text: "a dog named biscuit", source: .toldMe),
            MemoryNote(text: "my friend is coming over", source: .toldMe),
        ]
        #expect(Redactor.names(in: notes) == ["priya", "jo", "biscuit"])
        #expect(Redactor(memory: notes).redact("Ask Priya if Jo can walk Biscuit.").text
            == "Ask [name] if [name] can walk [name].")
    }

    @Test func capitalsThatAreNotNamesStay() {
        let notes = [MemoryNote(text: "I'm off. NASA launch is at 9. I'll watch.", source: .toldMe)]
        #expect(Redactor.names(in: notes).isEmpty)
    }

    @Test func curlyAndStraightApostrophesMatchEachOther() {
        let curlyNote = [MemoryNote(text: "Sam\u{2019}s birthday is May 14.", source: .toldMe)]
        #expect(Redactor.names(in: curlyNote) == ["Sam"])
        #expect(Redactor(memory: curlyNote).redact("Sam's party").text == "[name]'s party")
        let straight = Redactor(privateWords: ["Sam's place"])
        #expect(straight.redact("Meet at Sam\u{2019}s place").text == "Meet at [private]")
        let curly = Redactor(privateWords: ["Sam\u{2019}s place"])
        #expect(curly.redact("Meet at Sam's place").text == "Meet at [private]")
    }

    @Test func aNameInsideAnotherWordStays() {
        let out = Redactor(names: ["Ana"]).redact("Bananas and Anastasia's analysis.")
        #expect(out.text == "Bananas and Anastasia's analysis.")
        #expect(out.isUnchanged)
    }

    // MARK: Emails

    @Test(arguments: [
        ("Write to jo.lee@example.com today", "Write to [email] today"),
        ("Mine is SAM+notes@mail.example.co.uk.", "Mine is [email]."),
    ])
    func hidesEmails(input: String, expected: String) {
        let out = Redactor().redact(input)
        #expect(out.text == expected)
        #expect(out.hidden == [.email: 1])
    }

    // MARK: Phone numbers

    @Test(arguments: [
        ("Call 416-555-0199 tonight", "Call [phone number] tonight"),
        ("Call (416) 555-0199 tonight", "Call [phone number] tonight"),
        ("Call 416 555 0199 tonight", "Call [phone number] tonight"),
        ("Call 4165550199 tonight", "Call [phone number] tonight"),
        ("Call 1-800-555-0199 tonight", "Call [phone number] tonight"),
        ("Call +44 20 7946 0958 tonight", "Call [phone number] tonight"),
        ("Call 555-0199 tonight", "Call [phone number] tonight"),
        // Numbers written at home outside North America, without a plus.
        ("Call 020 7946 0958 tonight", "Call [phone number] tonight"),
        ("Call 07700 900123 tonight", "Call [phone number] tonight"),
        ("Call (020) 7946 0958 tonight", "Call [phone number] tonight"),
        ("Call 01 23 45 67 89 tonight", "Call [phone number] tonight"),
        ("Call 0412 345 678 tonight", "Call [phone number] tonight"),
    ])
    func hidesPhoneNumbers(input: String, expected: String) {
        let out = Redactor().redact(input)
        #expect(out.text == expected)
        #expect(out.hidden == [.phone: 1])
    }

    // MARK: Addresses

    @Test(arguments: [
        ("The party moved to 42 Maple Street.", "The party moved to [address]."),
        ("Send it to 1600 Pennsylvania Ave, please", "Send it to [address], please"),
        ("I live at 12 old mill rd apt 4", "I live at [address]"),
        ("My postal code is M5V 2T6", "My postal code is [address]"),
        ("my postal code is m5v 2t6", "my postal code is [address]"),
        ("It goes to sw1a 1aa today", "It goes to [address] today"),
        ("Mail it to ZIP 10001-1234 please", "Mail it to ZIP [address] please"),
        ("Ship to New York, NY 10001", "Ship to New York, [address]"),
        ("I work at 1 Avenue of the Americas.", "I work at [address]."),
        ("We're at 10 Lord of the Isles Road now", "We're at [address] now"),
        ("Dinner at 12 Rue de la Paix", "Dinner at [address]"),
    ])
    func hidesAddresses(input: String, expected: String) {
        let out = Redactor().redact(input)
        #expect(out.text == expected)
        #expect(out.hidden == [.address: 1])
    }

    @Test(arguments: [
        "Walk 5 blocks down the road, then 2 miles along the river drive.",
        "Take 3 of the main roads home.",
        "Meet b4 1pm, we're in room a1 2nd floor.",
        "Today is 01.02.2026 and the code is 0123.",
    ])
    func distancesTimesAndDatesAreNotAddressesOrPhones(line: String) {
        #expect(Redactor().redact(line).text == line)
    }

    // MARK: Card numbers

    @Test(arguments: [
        ("My card is 4111 1111 1111 1111 ok", "My card is [card number] ok"),
        ("My card is 4111-1111-1111-1111 ok", "My card is [card number] ok"),
        ("My card is 378282246310005 ok", "My card is [card number] ok"),
    ])
    func hidesCardLikeNumbers(input: String, expected: String) {
        let out = Redactor().redact(input)
        #expect(out.text == expected)
        #expect(out.hidden == [.card: 1])
    }

    // MARK: Private words

    @Test func hidesWordsThePersonMarkedPrivateInAnyCase() {
        let redactor = Redactor(privateWords: ["lemon cake", "Riverside Clinic"])
        let out = redactor.redact("Don't mention the Lemon Cake or my visit to riverside clinic.")
        #expect(out.text == "Don't mention the [private] or my visit to [private].")
        #expect(out.hidden == [.privateWord: 2])
    }

    @Test func aPrivateWordWinsOverAName() {
        let out = Redactor(names: ["Sam"], privateWords: ["Sam Lee"]).redact("Ask Sam Lee and Sam.")
        #expect(out.text == "Ask [private] and [name].")
    }

    // MARK: Everything at once

    @Test func hidesEveryKindInOneLine() {
        let redactor = Redactor(memory: Self.notes, privateWords: ["lemon cake"])
        let out = redactor.redact(
            "Tell Sam the party is at 42 Maple Street, call 416-555-0199 or write jo.lee@example.com, "
            + "pay with 4111 1111 1111 1111, and skip the lemon cake."
        )
        #expect(out.text == "Tell [name] the party is at [address], call [phone number] or write [email], "
            + "pay with [card number], and skip the [private].")
        #expect(out.hidden == [.name: 1, .address: 1, .phone: 1, .email: 1, .card: 1, .privateWord: 1])
    }

    // MARK: No false positives

    @Test(arguments: [
        "Help me plan my morning.",
        "Gym at 8:00, then groceries for $14.50 and 2 croissants.",
        "I ran 10 km in 52 minutes on May 14, 2026.",
        "Meet at 3 on Thursday, room 204, floor 12.",
        "The years 2025 and 2026 were busy. Order 66 shipped in 3 days.",
        "Will you mark the rose garden as done? I hope so.",
        "I'm reading chapter 7, pages 120 to 145.",
        "Turn the volume to 11 and set a timer for 25 minutes.",
        "My score went from 1200 to 1350.",
        "Email the team and phone the shop.",
    ])
    func ordinaryWordsAndNumbersStay(line: String) {
        let out = Redactor(memory: Self.notes, privateWords: ["lemon cake"]).redact(line)
        #expect(out.text == line)
        #expect(out.isUnchanged)
    }

    @Test func blankPrivateWordsAndDuplicatesAreIgnored() {
        let redactor = Redactor(names: ["Sam", "sam", " "], privateWords: ["", "  "])
        #expect(redactor.names == ["Sam"])
        #expect(redactor.privateWords.isEmpty)
        #expect(redactor.redact("Nothing to hide").isUnchanged)
    }
}
