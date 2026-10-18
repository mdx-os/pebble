import Foundation
import PebbleCore
import SourceScan
import Testing

/// What counts as a promise about the device or privacy, in one place.
/// docs/VOICE.md: say it only when `PrivacyPlace` says so.
enum DevicePromise {
    /// Every phrase that promises where words go or that they stay private.
    /// Matched without regard to case, on word boundaries, so "only on"
    /// never matches "only one".
    static let phrases = [
        "this device", "on this device", "your device", "on device", "on-device",
        "on your phone", "on this Mac", "on this iPhone", "on this iPad", "your Mac", "your iPhone", "your iPad",
        "stays here", "stay here", "stays on", "stay on", "kept only", "never leaves", "never leave",
        "doesn't leave", "won't leave", "nothing leaves", "only on", "private", "privately", "privacy",
        "nothing was sent", "nothing is sent anywhere", "not sent", "isn't sent", "never sent", "locally", "offline",
        "only you", "no one else", "encrypted", "secure",
        "cloud", "server", "servers", "upload", "uploads", "uploaded",
    ]

    /// `line` as a person reads it: a `\n`, `\t` or `\r` escape, a `\` that
    /// joins two lines of a multi-line literal, and every run of white space
    /// or line breaks become one space. So a phrase wrapped across the lines
    /// of a `"""` literal, or split by an escape, is still one phrase.
    static func folded(_ line: String) -> String {
        line.replacingOccurrences(of: #"\\(?:[ntr]|\n)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The phrases in `line`, if any. The words of a phrase may be apart by
    /// any white space, line breaks included.
    static func found(in line: String) -> [String] {
        let text = folded(line)
        return phrases.filter { phrase in
            let words = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A line the guard lets by without the flag, and why. Each one is a
    /// promise that is true whatever the model is.
    struct Allowed {
        /// The source file, from `Packages/PebbleKit/Sources` or `App`.
        let file: String
        /// The whole literal, exactly as written between its quotes, escapes
        /// and interpolations included. Matched by equality, so words added
        /// to an allowed line later need a reason of their own.
        let literal: String
        let reason: String
    }

    static let allowed: [Allowed] = [
        Allowed(file: "PebbleCore/Memory.swift",
                literal: "This removes every note and every task from this device, and stops any task still going. It can't be undone.",
                reason: "MemoryWords.forgetEverythingDetail is about where the notes and tasks are, not where the chat goes. "
                    + "Notes live only in MemoryStore's local file and tasks only in the engine in this process, "
                    + "whatever the model is, so it is true with a cloud model too."),
        Allowed(file: "PebbleCore/Tasks.swift",
                literal: "This stops any task still going, and removes every task and what you told me for it from this device. It can't be undone. Your notes aren't touched.",
                reason: "TaskWords.forgetTasksDetail names where the tasks are erased from, not that nothing left. "
                    + "\"From this device\" is the honest limit: without it, a cloud model's copy would seem erased too."),
        Allowed(file: "PebbleModel/LocalStubModel.swift",
                literal: "Thanks for telling me. I'm a small helper that runs only on this device, so I can't do everything yet. I'm good at morning plans, saying a detail back, and talking things through. Want to start with one of those?",
                reason: "LocalStubModel.fallback is only ever said by the on-device stub, which always runs here."),
        Allowed(file: "PebbleModel/LocalStubModel.swift",
                literal: #"Here's what I heard: \"\(clean)\". If that's right, add it in What I remember and I'll keep it on this device."#,
                reason: "The stub's remember result. Only the on-device stub says it, and notes stay in the local file."),
        Allowed(file: "PebbleModel/LocalStubModel.swift",
                literal: "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.",
                reason: "The stub's remember opener. Only the on-device stub says it."),
        Allowed(file: "PebbleCore/PulseNotice.swift", literal: "Privacy: 0. Adapt this idea or leave it.",
                reason: "The competitor watch's note to the founder, never shown in the app. \"Privacy\" names the idea's "
                    + "privacy fit score, a number about someone else's product, and promises nothing about this one."),
        Allowed(file: "PebbleCore/PulseNotice.swift", literal: #"Privacy: \(fit.privacy)."#,
                reason: "The same privacy fit score in the competitor watch's note to the founder, not app copy."),
        Allowed(file: "PebbleCore/PulseNotice.swift",
                literal: #"\(privacy) Local models: \(fit.localFirst). Open weights: \(fit.openWeights)."#,
                reason: "The competitor watch's fit line, which only names its `privacy` score. A note to the founder, "
                    + "not app copy."),
        Allowed(file: "PebbleCore/Feed.swift", literal: "These are examples for now. Nothing was sent or bought.",
                reason: "FeedWords.sampleNote off the device. \"Nothing was sent\" is about the example cards' actions, "
                    + "which never ran, not about where words go, so it is true with any model."),
    ] + cloud + ideaFitKeywords.map { keyword in
        Allowed(file: "PebbleCore/IdeaDraft.swift", literal: keyword,
                reason: "A keyword IdeaDraft.fit looks for in a competitor's own words, to score how private that "
                    + "product is. Matched with `contains`, never shown to anyone, and promises nothing about this app.")
    }

    /// "Private words" is the name of the person's own list in the cloud
    /// setting, the words `Redactor` always takes out. It names the list;
    /// it promises nothing about where a chat goes.
    static let privateWordsName = "\"Private words\" names the list of words the person asked to hide (CloudHelp's private "
        + "words, `Redaction.Kind.privateWord`). It names that list and promises nothing about where a chat goes, so it "
        + "is true with the cloud on or off."

    /// "Help from the cloud" is the name of the setting that sends words
    /// off the device. Naming it says words may leave, the opposite of a
    /// device promise.
    static let cloudSettingName = "\"Cloud\" names the setting that sends a new chat to a cloud model, or that model. "
        + "Naming it says words may leave, never that they stay."

    /// The cloud setting's lines. Each is shown whatever the open chat's
    /// place, and each is true with the cloud on and off.
    static let cloud: [Allowed] = [
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "On for new chats. Before anything from a chat leaves this device, I show you exactly what goes, and you decide.",
                reason: "CloudWords.onDetail, shown only while the cloud is on. It says words do leave, the opposite of a "
                    + "device promise, and the preview it describes gates every cloud request (CloudReview)."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "There's no cloud model set up for this device yet, so this stays off.",
                reason: "CloudWords.unavailable. \"This device\" names the install that has no cloud address, and \"stays "
                    + "off\" is the setting; neither says where a chat goes."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I can't open the place I keep this setting and your private words, so it stays off for now. Closing and reopening the app may help.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your next new chat will use a bigger model on a computer somewhere else, not on this device.",
                reason: "The first point before turning the cloud on. It says new chats run off the device, a disclosure, "
                    + "not a promise that anything stays."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "I try to take out names from your notes, emails, phone numbers, addresses, card numbers and your private words first. Check what I show you, since I can miss things.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "If that computer needs me to sign in, I do it right after your yes. Signing in never carries your chats, notes or private words.",
                reason: privateWordsName + " That sign in carries none of them is CloudAuth.signIn's contract."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your notes themselves never leave this device.",
                reason: "True even with the cloud on: the notes file is only read on the device, by Redactor, to find what "
                    + "to take out. A cloud request carries the chat, never the notes themselves."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Like any website, the computer it goes to can see this device's internet address.",
                reason: "A disclosure before turning the cloud on: it says what the cloud does see. \"This device\" names "
                    + "whose address it is, and promises nothing stays."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Anything here is taken out before anything is sent. These words are kept only on this device, and Forget everything erases them too.",
                reason: "CloudWords.privateDetail is about where the private words are kept, CloudHelpFileStore beside the "
                    + "notes, and Redactor takes them out of every request, so they never leave even with the cloud on."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "A word or name to keep private",
                reason: "The private words field's placeholder. Redactor takes every one out of every cloud request before "
                    + "it is sent, and with the cloud off nothing is sent, so it is kept out either way."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I can't read your private words just now, so I've left them as they are. If the device is locked, unlock it and try again.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I couldn't save that just now, so your private words are as they were. Please try again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I couldn't save that. Help from the cloud is off, and to make sure it stays off I cleared the cloud setting, along with your private words. You can add them again anytime.",
                reason: privateWordsName + " \"Stays off\" is the setting."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "Here is exactly what leaves your device",
                reason: "The cloud preview's title, shown only over a cloud request about to go. It says words leave, the "
                    + "opposite of a device promise."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "This is the whole request for this message: where it goes, the labels sent with it, and the words. I took out the personal details I found. Earlier messages in this chat go again with each new one. Like any website, the computer it goes to also sees this device's internet address.",
                reason: "The cloud preview's detail, shown only over a cloud request. \"This device\" names whose address "
                    + "the cloud sees, a disclosure, not a promise."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Part of this chat has to stay on this device, so I won't send any of it. A new chat starts fresh, and I can help there.",
                reason: "CloudWords.staysHere, said as CloudModel refuses to send a chat that promised the device. Nothing "
                    + "of that chat is sent, so it is true; it explains a refusal, not where other chats go."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I can't read your notes or private words just now, so I can't tell what to take out. I didn't send anything. If the device is locked, unlock it and try again.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "This removes every note, every task and every word you asked me to hide from this device, and stops any task still going. It can't be undone.",
                reason: "CloudWords.forgetEverythingDetail, like MemoryWords.forgetEverythingDetail: it names where the "
                    + "notes, tasks and private words are erased from, all local files, whatever the model is."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your notes are gone, but I couldn't erase your private words just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your notes and tasks are gone, but I couldn't erase your private words just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your private words are gone, but I couldn't erase your notes just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your tasks and private words are gone, but I couldn't erase your notes just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your tasks are gone, but I couldn't erase your notes or private words just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Gone. I no longer have it. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. You can turn it on again anytime.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your private words are gone. To be sure of that I cleared the cloud setting too, so help from the cloud is off. I couldn't erase your notes just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your tasks and private words are gone. To be sure of that I cleared the cloud setting too, so help from the cloud is off. I couldn't erase your notes just now. Please try Forget everything again in a moment.",
                reason: privateWordsName),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "This stops any task still going, and removes every task, what you told me for it and any words you asked me to hide from this device. It can't be undone. Your notes aren't touched.",
                reason: "CloudWords.forgetTasksAndWordsDetail, like TaskWords.forgetTasksDetail: \"from this device\" is "
                    + "the honest limit of what is erased, local files only, whatever the model is."),
        // "Cloud" in the lines below names the setting or the model it
        // turns on. Each says where words may go, or that the setting is
        // off, and never that a chat is kept from the cloud.
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "Help from the cloud",
                reason: cloudSettingName + " CloudWords.title and rowTitle, the setting's name on its screen and row."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "Use a cloud model",
                reason: cloudSettingName + " CloudWords.toggleTitle, the switch that turns it on."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "Turn on help from the cloud?",
                reason: cloudSettingName + " CloudWords.askQuestion, asked before it turns on, so it says words will go."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I couldn't save that. Help from the cloud is off until you close the app, but it may be on again when you come back, so please check here then.",
                reason: cloudSettingName + " CloudWords.offForNow says the setting may read as on again, the honest "
                    + "limit, and promises nothing about where words go."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Sorry, I couldn't save that, so help from the cloud is still off. Please try again in a moment.",
                reason: cloudSettingName + " CloudWords.onNotSaved: the setting stayed off, which is what the person sees."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Help from the cloud is off now, so I didn't send that. A new chat won't use the cloud.",
                reason: cloudSettingName + " CloudWords.turnedOff is said only as the setting turns off, so the next new "
                    + "chat does not get the cloud model. It promises nothing about the device, since where that chat "
                    + "answers is the local model's place, which this line can't see."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your tasks are forgotten, and so are any words you asked me to hide. To be sure of that I cleared the cloud setting too, so help from the cloud is off.",
                reason: cloudSettingName + " CloudWords.tasksAndWordsAndCloudForgotten: the setting was erased, so it reads "
                    + "as off, which is what it says."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "cloud-help.json",
                reason: "The name of the file the cloud setting is kept in, beside the notes. Never shown to anyone."),
        Allowed(file: "PebbleUI/CloudHelpView.swift", literal: "cloud.fill",
                reason: "An SF Symbol name for the setting's icon. VoiceOver never reads it and nobody sees the word."),
        Allowed(file: "PebbleUI/CloudHelpView.swift", literal: "cloud",
                reason: "An SF Symbol name in the list the cloud question's icons are checked against. Never shown."),
        Allowed(file: "PebbleUI/ShowcaseScene.swift", literal: "https://cloud.example.com",
                reason: "The showcase's made up cloud address on a domain kept for examples. Its transport refuses every "
                    + "request, and the showcase is Debug only."),
        Allowed(file: "PebbleCore/Redactor.swift", literal: "[private]",
                reason: "The mask that replaces a private word in the text that leaves. " + privateWordsName),
        Allowed(file: "PebbleCore/Redactor.swift", literal: "hidden private word",
                reason: "What VoiceOver says for the [private] mask. " + privateWordsName),
        Allowed(file: "PebbleCore/Redactor.swift", literal: "private word",
                reason: "The preview's count of hidden private words, one. " + privateWordsName),
        Allowed(file: "PebbleCore/Redactor.swift", literal: "private words",
                reason: "The preview's count of hidden private words, many. " + privateWordsName),
    ]

    /// The words the competitor watch's fit score looks for.
    static let ideaFitKeywords = ["upload", "cloud data storage", "on our servers", "requires cloud", "cloud only"]

    /// True when `text` in `file` is an allowed line, word for word.
    static func isAllowed(_ text: String, in file: String) -> Bool {
        allowed.contains { $0.file == file && $0.literal == text }
    }

    /// The literals in `source`, with those written one after another with
    /// only `+` between them (`"never " + "leaves"`) kept together, in order.
    ///
    /// A heuristic, not airtight: only white space may come between the
    /// literals and the `+`, so `"never " + ("leaves")` or
    /// `["never", "leaves"].joined(separator: " ")` are still read as two
    /// lines. It catches the usual way copy is wrapped, and review catches
    /// the rest.
    static func joined(_ source: SwiftSource) -> [[SwiftSource.Literal]] {
        var chains: [[SwiftSource.Literal]] = []
        for literal in source.literals {
            if let last = chains.last?.last, last.end <= literal.offset {
                let between = String(source.code[last.end..<literal.offset])
                if between.range(of: #"^\s*\+\s*$"#, options: .regularExpression) != nil {
                    chains[chains.count - 1].append(literal)
                    continue
                }
            }
            chains.append([literal])
        }
        return chains
    }

    /// Lines the copy lists hold that the guard lets by, each with its
    /// entry in `allowed` for the reason.
    static let allowedLines: [String] = [
        MemoryWords.forgetEverythingDetail,
        TaskWords.forgetTasksDetail,
        FeedWords.sampleNote(.mayLeaveDevice),
        CloudWords.title,
        CloudWords.toggleTitle,
        CloudWords.rowTitle,
        CloudWords.askQuestion,
        CloudWords.offForNow,
        CloudWords.onNotSaved,
        CloudWords.turnedOff,
        CloudWords.tasksAndWordsAndCloudForgotten,
        CloudWords.onDetail,
        CloudWords.unavailable,
        CloudWords.couldNotOpen,
        CloudWords.privateDetail,
        CloudWords.privatePlaceholder,
        CloudWords.privateUnreadable,
        CloudWords.privateNotSaved,
        CloudWords.offButCleared,
        CloudWords.previewTitle,
        CloudWords.previewDetail,
        CloudWords.staysHere,
        CloudWords.notesUnreadable,
        CloudWords.forgetEverythingDetail,
        CloudWords.forgotNotesNotWords,
        CloudWords.forgotNotesAndTasksNotWords,
        CloudWords.forgotWordsNotNotes,
        CloudWords.forgotTasksAndWordsNotNotes,
        CloudWords.forgotTasksNotNotesOrWords,
        CloudWords.forgotAndCloudOff,
        CloudWords.forgotWordsAndCloudNotNotes,
        CloudWords.forgotTasksAndWordsAndCloudNotNotes,
        CloudWords.forgetTasksAndWordsDetail,
        Redaction.Kind.privateWord.mask,
        Redaction.Kind.privateWord.spoken,
    ] + CloudWords.askPoints.filter { !found(in: $0).isEmpty }

    /// Lines built at run time around an allowed literal, each with the
    /// literal it is built from. What is built around it adds no phrase.
    static let allowedBuiltLines: [(line: String, literal: String)] = [
        (Redaction.Kind.privateWord.counted(1), "private word"),
        (Redaction.Kind.privateWord.counted(2), "private words"),
    ]

    /// A literal is gated when it is the true branch of a ternary whose
    /// whole condition is `.staysOnDevice` read inline from a
    /// `PrivacyPlace`: `place.staysOnDevice ? "..."`,
    /// `self.place.staysOnDevice ? "..."`,
    /// `privacyPlace.staysOnDevice ? "..."` or
    /// `model.privacyPlace.staysOnDevice ? "..."`, on one line or across
    /// several. The false branch comes after `:` and is never gated.
    ///
    /// It must be read from one of those receivers and no other, so a call
    /// result (`flipped().staysOnDevice`) or some other value never gates.
    /// `everyPlaceIsAPrivacyPlace` keeps `staysOnDevice` declared on
    /// `PrivacyPlace` alone, so only a `PrivacyPlace` can have it, and keeps
    /// `.onDevice` from being written anywhere but where the model decides
    /// it, so a place is always the model's. A Bool of
    /// its own, whatever it is called (`onDevice`, `staysOnDevice`), never
    /// gates, since nothing ties it to the flag: `let onDevice =
    /// !place.staysOnDevice` would turn the promise around.
    ///
    /// The flag must be all of the condition, so nothing but an opening
    /// paren may come between it and what starts the expression: `=`,
    /// `return`, `(`, `[`, `{`, `,`, `:` or the start of the file. A
    /// negated flag (`!place.staysOnDevice ?`) or one inside a compound
    /// condition (`isRemote || place.staysOnDevice ?`) is not gated.
    static func isGated(_ literal: SwiftSource.Literal, in source: SwiftSource) -> Bool {
        // All the code before it, so a condition that starts many lines up
        // is still seen whole.
        let before = String(source.code[..<literal.offset])
        let receiver = #"(?:self\s*\.\s*place|place|model\s*\.\s*privacyPlace|privacyPlace)"#
        let pattern = #"(?:\A|[(\[{,:]|(?<![=!<>])=|\breturn)\s*(?:\(\s*)*"# + receiver
            + #"\s*\.\s*staysOnDevice\s*(?:\)\s*)*\?\s*\z"#
        return before.range(of: pattern, options: .regularExpression) != nil
    }

    /// What would let the gate trust something other than the flag, in
    /// `source`.
    ///
    /// - `staysOnDevice` is declared only in `PrivacyPlace.swift`, so a
    ///   `place.staysOnDevice` that compiles is read from a `PrivacyPlace`.
    ///   Elsewhere the word is only ever a member read or the
    ///   `PrivacyPlace(staysOnDevice:` label.
    /// - `.onDevice` and `.mayLeaveDevice` are written only in
    ///   `PrivacyPlace.swift` and `ModelClient.swift`, so every place comes
    ///   from the model. A parameter may default to `.mayLeaveDevice`, and
    ///   `CloudModel.swift`, a model itself, may say `.mayLeaveDevice` of
    ///   its own words, never `.onDevice`.
    /// - `PrivacyPlace(staysOnDevice:` is made only in `ModelClient.swift`,
    ///   from `runsOnDevice`, so a place is never built from a turned Bool.
    /// - A Bool named `onDevice`, as a `let`/`var` or as an argument, must
    ///   come straight from `.staysOnDevice`, with no `!`.
    static func placeProblems(in source: SwiftSource, file: String) -> [String] {
        let code = String(source.code)
        var problems: [String] = []
        func each(_ pattern: String, _ check: (NSTextCheckingResult, NSString) -> String?) {
            let ns = code as NSString
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                if let problem = check(match, ns) {
                    problems.append("\(file):\(source.line(at: match.range.location)): \(problem)")
                }
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        }
        // Anything else called staysOnDevice: a property, function, case
        // (`case a, staysOnDevice` too), parameter or tuple label. Outside
        // PrivacyPlace.swift the word may only be read as `.staysOnDevice`
        // or be the label of `PrivacyPlace(staysOnDevice:`.
        if file != "PebbleCore/PrivacyPlace.swift" {
            each(#"(?<!\w)(?<!\.\s{0,40})(?<!\bPrivacyPlace\s{0,10}\(\s{0,40})staysOnDevice\b"#) { _, _ in
                "staysOnDevice is declared only on PrivacyPlace, so the gate can trust it"
            }
        }
        // The place itself, written out. Only the model decides it, so a
        // screen never says `.onDevice` of its own accord, as in
        // `let place: PrivacyPlace = .onDevice` or `isRemote ? .onDevice :
        // .mayLeaveDevice`. A parameter may default to `.mayLeaveDevice`,
        // which promises nothing.
        if !["PebbleCore/PrivacyPlace.swift", "PebbleModel/ModelClient.swift"].contains(file) {
            each(#"(?:\b(?:PrivacyPlace|Self)\s*|(?<![\w)\]]))\.\s*(onDevice|mayLeaveDevice)\b(?!\s*\()"#) { match, ns in
                let start = match.range.location
                let lead = ns.substring(to: start)
                if group(match, 1, ns) == "mayLeaveDevice",
                   lead.range(of: #":\s*PrivacyPlace\s*=\s*\z"#, options: .regularExpression) != nil {
                    return nil
                }
                // The cloud adapter is a model, and says where its own words
                // go: they may leave. It may never say `.onDevice`.
                if file == "PebbleModel/CloudModel.swift", group(match, 1, ns) == "mayLeaveDevice" {
                    return nil
                }
                return "\(ns.substring(with: match.range)) is decided only by the model, as model.privacyPlace"
            }
        }
        for call in source.calls(named: ["PrivacyPlace"]) where call.arguments.contains("staysOnDevice:") {
            if file != "PebbleModel/ModelClient.swift" || call.arguments != "staysOnDevice: runsOnDevice" {
                problems.append("\(file):\(call.line): PrivacyPlace(\(call.arguments)) is made only by ModelClient, from runsOnDevice")
            }
        }
        // A Bool called onDevice, kept or passed on.
        // `.onDevice :` in a ternary is the enum case, not a label.
        each(#"(?:\b(?:let|var)\s+onDevice\s*(?::\s*\w+\s*)?=|(?<![.\w])onDevice\s*:)\s*([^,)\n]*)"#) { match, ns in
            let value = group(match, 1, ns) ?? ""
            let straight = #"^(?:\w+\s*\.\s*)*staysOnDevice$"#
            return value.range(of: straight, options: .regularExpression) != nil ? nil
                : "onDevice gets \"\(value)\", not .staysOnDevice straight from a PrivacyPlace"
        }
        return problems
    }
}

/// PERMANENT GUARD. No word a person sees promises the device or privacy
/// unless `PrivacyPlace` decides it, or it is allowed below with a written
/// reason. Two sweeps: every string literal in the package sources and the
/// app, and every line in the copy lists the other tests keep.
struct DevicePromiseTests {
    /// Every Swift file under `Packages/PebbleKit/Sources` and `App`.
    static func sources() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let package = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App"))
        return package + app.map { ("App/\($0.name)", $0.text) }
    }

    /// The literals that promise the device, and are neither gated nor allowed.
    /// Literals joined with `+` are read as one, so `"never " + "leaves"` is
    /// still the phrase. A joined line is gated by its first literal, and
    /// allowed only as the whole joined text.
    static func ungated(in files: [(name: String, text: String)]) -> [String] {
        var problems: [String] = []
        for file in files {
            let source = SwiftSource(file.text)
            for chain in DevicePromise.joined(source) {
                let text = chain.map(\.text).joined()
                guard !DevicePromise.found(in: text).isEmpty, let first = chain.first else { continue }
                if DevicePromise.isGated(first, in: source) { continue }
                if DevicePromise.isAllowed(text, in: file.name) { continue }
                problems.append("\(file.name):\(first.line): \"\(text)\" promises "
                                + "\(DevicePromise.found(in: text)) without PrivacyPlace")
            }
        }
        return problems
    }

    @Test func everyDevicePromiseInTheSourceIsGatedOrAllowed() throws {
        let files = try Self.sources()
        #expect(files.count > 20)
        #expect(files.contains { $0.name.hasPrefix("App/") }, "the app's own sources are swept too")
        for problem in Self.ungated(in: files) {
            Issue.record(Comment(rawValue: problem))
        }
    }

    /// Every allowed entry still finds its line and says why, so the list
    /// never keeps a stale pass.
    @Test func everyAllowedLineIsStillThereWithAReason() throws {
        let files = try Self.sources()
        for entry in DevicePromise.allowed {
            #expect(entry.reason.count > 40, "\(entry.file): say why")
            let file = files.first { $0.name == entry.file }
            let literals = file.map { SwiftSource($0.text).literals } ?? []
            #expect(literals.contains { $0.text == entry.literal }, "no longer in \(entry.file): \(entry.literal)")
        }
        for line in DevicePromise.allowedLines {
            #expect(DevicePromise.allowed.contains { line == $0.literal }, "no reason given for: \(line)")
        }
        for built in DevicePromise.allowedBuiltLines {
            #expect(DevicePromise.allowed.contains { built.literal == $0.literal }, "no reason given for: \(built.literal)")
            #expect(built.line.contains(built.literal), "\(built.line) is not built from \(built.literal)")
            let added = built.line.replacingOccurrences(of: built.literal, with: "")
            #expect(DevicePromise.found(in: added).isEmpty, "\(built.line) adds a promise of its own")
        }
    }

    /// Every line the copy lists hold: the gated lines on the device, the
    /// allowed ones, and nothing else, may promise the device.
    @Test func everyCopyListLineIsGatedOrAllowed() {
        let gated = Set(PrivacyPlaceTests.deviceLines(.onDevice))
        let lines = CopyDashTests.copy + FeedWords.all + PrivacyPlaceTests.deviceLines(.onDevice)
            + PrivacyPlaceTests.deviceLines(.mayLeaveDevice) + Self.sampleFeedWords
        #expect(lines.count > 100)
        for line in lines where !DevicePromise.found(in: line).isEmpty {
            #expect(gated.contains(line) || DevicePromise.allowedLines.contains(line)
                        || DevicePromise.allowedBuiltLines.contains { $0.line == line },
                    "promises \(DevicePromise.found(in: line)) without PrivacyPlace: \(line)")
        }
    }

    /// Off the device, no gated line promises anything but what is allowed.
    @Test func offTheDeviceTheGatedLinesPromiseNothing() {
        for line in PrivacyPlaceTests.deviceLines(.mayLeaveDevice) {
            #expect(DevicePromise.found(in: line).isEmpty || DevicePromise.allowedLines.contains(line),
                    "promises \(DevicePromise.found(in: line)): \(line)")
        }
    }

    static var sampleFeedWords: [String] {
        SampleFeedSource().items(now: Date()).flatMap { item -> [String] in
            var words = [item.title, item.body]
            if case .open(let text) = item.action { words.append(text) }
            if case .talk(let text) = item.action { words.append(text) }
            return words
        }
    }

    /// The line said when the cloud was turned off mid chat can't read the
    /// next chat's place, so it promises nothing about the device. Its one
    /// phrase is the setting's name, allowed with that reason.
    @Test func theTurnedOffLinePromisesNothing() {
        #expect(DevicePromise.found(in: CloudWords.turnedOff) == ["cloud"])
        let entry = DevicePromise.allowed.first { $0.literal == CloudWords.turnedOff }
        #expect(entry?.reason.hasPrefix(DevicePromise.cloudSettingName) == true)
    }

    /// The guard catches what it is for, and lets the right things by.
    @Test func theGuardCatchesAnUngatedPromise() {
        let wrong = [
            #"public static let note = "Your notes stay on this device.""#,
            #"let line = onDevice ? "Here with you." : "Kept only on this device.""#,
            "let detail = \"\"\"\n    Everything here is private.\n    \"\"\"",
            #"Text("Nothing was sent.")"#,
            #"static let x = "It never leaves your phone.""#,
            // The flag turned around, or only part of the condition.
            #"let line = !place.staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = (!place.staysOnDevice) ? "It stays on this device." : "Hi.""#,
            #"let line = isRemote && place.staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = wasLocal == place.staysOnDevice ? "It stays on this device." : "Hi.""#,
            "let line = isRemote ||\n    place.staysOnDevice\n    ? \"It stays on this device.\"\n    : \"Hi.\"",
            // A Bool of its own never gates, whatever it is called, since
            // nothing ties it to the flag.
            "let onDevice = !place.staysOnDevice\nlet line = onDevice ? \"It stays on this device.\" : \"Hi.\"",
            #"let line = onDevice ? "It stays on this device." : "Hi.""#,
            #"let line = (onDevice) ? "It stays on this device." : "Hi.""#,
            #"let line = staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = !staysOnDevice ? "It stays on this device." : "Hi.""#,
            // Only the place's own receivers gate: never a call's result or
            // some other value's flag.
            #"let line = flipped().staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = other.place.staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = settings.staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = PrivacyPlace.onDevice.staysOnDevice ? "It stays on this device." : "Hi.""#,
            // The newer phrases.
            #"Text("Your privacy comes first.")"#,
            #"static let x = "It's all on this Mac.""#,
            #"static let x = "Only you can read this.""#,
            #"static let x = "Your words are encrypted and secure.""#,
            #"static let x = "It works offline, and what you say isn't sent.""#,
            #"static let x = "Your words are never sent anywhere.""#,
            #"static let x = "Nothing leaves your iPhone.""#,
            #"static let x = "It all stays with your iPad.""#,
            #"static let x = "No cloud, no server, no upload.""#,
            #"static let x = "Your notes are uploaded to our servers.""#,
            // Wrapped over the lines of a multi-line literal, or split by
            // an escape, a phrase is still one phrase.
            "let detail = \"\"\"\n    What you say never\n    leaves your phone.\n    \"\"\"",
            "let detail = \"\"\"\n    It's all kept on this\n        Mac.\n    \"\"\"",
            "let detail = \"\"\"\n    Your words stay \\\n    on your Mac.\n    \"\"\"",
            #"static let x = "Only\nyou can read it.""#,
            #"static let x = "It runs on this\ndevice.""#,
            #"static let x = "Nothing\tleaves.""#,
            // Split into literals joined with +, a phrase is still one phrase.
            #"static let x = "It never " + "leaves.""#,
            "static let x = \"Your words stay on this \"\n    + \"device.\"",
            #"static let x = "Kept on " + /* here */ "this Mac.""#,
        ]
        for text in wrong {
            #expect(!Self.ungated(in: [("PebbleCore/Wrong.swift", text)]).isEmpty, "missed: \(text)")
        }
        let right = [
            #"place.staysOnDevice ? "Saved. It stays on this device." : "Saved.""#,
            "place.staysOnDevice\n    ? \"I run on this device.\"\n    : \"Hi.\"",
            #"return (place.staysOnDevice) ? "I run on this device." : "Hi.""#,
            #"return model.privacyPlace.staysOnDevice ? "I run on this device." : "Hi.""#,
            #"return privacyPlace.staysOnDevice ? "I run on this device." : "Hi.""#,
            #"Text(place.staysOnDevice ? "Kept only on this device." : "Kept.")"#,
            "func f() -> String {\n    self.place.staysOnDevice\n        ? \"It stays on this device.\"\n        : \"Hi.\"\n}",
            #"// Says "on this device" only when the flag says so."#,
            "/* \"stays on this device\" */",
            #"static let x = "Only one note at a time.""#,
            #"place.staysOnDevice ? "It stays on " + "this device." : "Hi.""#,
            #"let x = "Only " + name + " leaves.""#,
        ]
        for text in right {
            #expect(Self.ungated(in: [("PebbleCore/Right.swift", text)]).isEmpty, "flagged: \(text)")
        }
        #expect(DevicePromise.found(in: "only one").isEmpty)
        #expect(!DevicePromise.found(in: "Kept ONLY on this device").isEmpty)
        #expect(DevicePromise.found(in: "Kept on this\n    device") == ["this device", "on this device"])
    }

    /// PERMANENT GUARD. The gate trusts `.staysOnDevice`, so only
    /// `PrivacyPlace` declares it, a place is only made by the model, and no
    /// Bool called `onDevice` is passed around that isn't `.staysOnDevice`
    /// itself.
    @Test func everyPlaceIsAPrivacyPlace() throws {
        let files = try Self.sources()
        for file in files {
            for problem in DevicePromise.placeProblems(in: SwiftSource(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
        let wrong = [
            // Any type with a staysOnDevice of its own would pass the gate.
            "struct Identity { let staysOnDevice: Bool }",
            "extension Settings { var staysOnDevice: Bool { true } }",
            "struct Wrapper { func staysOnDevice() -> Bool { false } }",
            "let place = PrivacyPlace(staysOnDevice: !model.runsOnDevice)",
            "let onDevice = !place.staysOnDevice",
            "let onDevice = true",
            "f(onDevice: !place.staysOnDevice)",
            "f(onDevice: model.runsOnDevice)",
            "init(onDevice: Bool = false) {}",
            // A case or label called staysOnDevice is a staysOnDevice too.
            "enum Where { case a, staysOnDevice }",
            "enum Where {\n    case here,\n        staysOnDevice\n}",
            "let identity: (kind: String, staysOnDevice: Bool)",
            "func f(staysOnDevice: Bool) {}",
            "let (name, staysOnDevice) = pair",
            "let place: PrivacyPlace = .init(staysOnDevice: true)",
            // The place written out, rather than taken from the model.
            "let place: PrivacyPlace = .onDevice",
            "let place = PrivacyPlace.onDevice",
            "let x = flag ? .onDevice : .mayLeaveDevice",
            "let x = flag ? PrivacyPlace.mayLeaveDevice : .onDevice",
            "f(place: .onDevice)",
            "f(place: isRemote ? .mayLeaveDevice : model.privacyPlace)",
            "switch place { case .onDevice: return true default: return false }",
        ]
        for text in wrong {
            #expect(!DevicePromise.placeProblems(in: SwiftSource(text), file: "PebbleUI/Wrong.swift").isEmpty, "missed: \(text)")
        }
        let right = [
            "let place: PrivacyPlace",
            "let place = model.privacyPlace",
            "f(place: model.privacyPlace, onDevice: model.privacyPlace.staysOnDevice)",
            "// var staysOnDevice: Bool, in a comment",
            "let note = \"staysOnDevice and .onDevice, in words\"",
            "if place.staysOnDevice && !model.privacyPlace.staysOnDevice { throw Oops.leaves }",
            "let x = place\n    .staysOnDevice",
            "public init(turns: [ChatTurn], place: PrivacyPlace = .mayLeaveDevice) {}",
            "let store = try? MemoryStore.onDevice()",
        ]
        for text in right {
            #expect(DevicePromise.placeProblems(in: SwiftSource(text), file: "PebbleUI/Right.swift").isEmpty, "flagged: \(text)")
        }
        let model = "var privacyPlace: PrivacyPlace { PrivacyPlace(staysOnDevice: runsOnDevice) }"
        #expect(DevicePromise.placeProblems(in: SwiftSource(model), file: "PebbleModel/ModelClient.swift").isEmpty)
        #expect(!DevicePromise.placeProblems(in: SwiftSource(model), file: "PebbleUI/Other.swift").isEmpty)
        let cloudPlace = "public static let place = PrivacyPlace.mayLeaveDevice"
        #expect(DevicePromise.placeProblems(in: SwiftSource(cloudPlace), file: "PebbleModel/CloudModel.swift").isEmpty)
        #expect(!DevicePromise.placeProblems(in: SwiftSource(cloudPlace), file: "PebbleUI/Other.swift").isEmpty)
        let cloudPromise = "public static let place = PrivacyPlace.onDevice"
        #expect(!DevicePromise.placeProblems(in: SwiftSource(cloudPromise), file: "PebbleModel/CloudModel.swift").isEmpty)
        let flag = "public var staysOnDevice: Bool { self == .onDevice }"
        #expect(DevicePromise.placeProblems(in: SwiftSource(flag), file: "PebbleCore/PrivacyPlace.swift").isEmpty)
        #expect(!DevicePromise.placeProblems(in: SwiftSource(flag), file: "PebbleCore/Other.swift").isEmpty)
    }

    /// An allowed line passes only word for word. Anything added to it,
    /// even after the allowed words, needs its own reason.
    @Test func theAllowListMatchesTheWholeLine() throws {
        let entry = try #require(DevicePromise.allowed.first { $0.file == "PebbleCore/Feed.swift" })
        let exact = "static let x = \"\(entry.literal)\""
        #expect(Self.ungated(in: [(entry.file, exact)]).isEmpty)
        let longer = "static let x = \"\(entry.literal) Nothing ever leaves.\""
        #expect(!Self.ungated(in: [(entry.file, longer)]).isEmpty, "a longer line passed under the old reason")
        let shorter = "static let x = \"Nothing was sent or bought.\""
        #expect(!Self.ungated(in: [(entry.file, shorter)]).isEmpty, "part of an allowed line passed")
        #expect(!Self.ungated(in: [("PebbleCore/Other.swift", exact)]).isEmpty, "allowed in one file only")
    }

    // MARK: Words outside Swift

    /// A line in the app's Info.plist, project.yml's info for it, or a
    /// strings catalog, where usage descriptions such as "stays on your
    /// device" usually live, that the guard lets by, and why.
    struct AllowedResource {
        let file: String
        let text: String
        let reason: String
    }

    /// Each is a promise true whatever the model is, or no words a person
    /// sees.
    static let allowedResources: [AllowedResource] = [
        AllowedResource(file: "project.yml",
                        text: "        # Empty unless set in Config/Cloud.xcconfig. Empty means no cloud model.",
                        reason: "A YAML comment beside the cloud address setting. It never reaches the plist or "
                            + "the screen, and it says when there is no cloud model, not where words go."),
    ]

    /// Every word a person can see that lives outside Swift: each string in
    /// `App/Info.plist`, each line of project.yml (its `info:` properties
    /// and `INFOPLIST_KEY_` settings become the plist), and each line of a
    /// `.strings`, `.stringsdict` or `.xcstrings` file in the app or the
    /// package sources.
    static func resourceLines() throws -> [(file: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        var lines: [(String, String)] = []
        let plist = try Data(contentsOf: root.appendingPathComponent("App/Info.plist"))
        lines += try plistStrings(plist).map { ("App/Info.plist", $0) }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        lines += project.split(separator: "\n").map { ("project.yml", String($0)) }
        for folder in ["App", "Packages/PebbleKit/Sources"] {
            let base = root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where ["strings", "stringsdict", "xcstrings"].contains(url.pathExtension) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = folder + "/" + url.lastPathComponent
                lines += text.split(separator: "\n").map { (name, String($0)) }
            }
        }
        return lines
    }

    /// Every string value in a property list, nested ones too.
    static func plistStrings(_ data: Data) throws -> [String] {
        func strings(in value: Any) -> [String] {
            switch value {
            case let text as String: return [text]
            case let list as [Any]: return list.flatMap(strings)
            case let table as [String: Any]: return table.keys.sorted().flatMap { strings(in: table[$0]!) }
            default: return []
            }
        }
        return strings(in: try PropertyListSerialization.propertyList(from: data, format: nil))
    }

    @Test func noWordsOutsideSwiftPromiseTheDevice() throws {
        let lines = try Self.resourceLines()
        #expect(lines.contains { $0.file == "App/Info.plist" }, "the app's Info.plist is read")
        #expect(lines.contains { $0.file == "project.yml" }, "project.yml is read")
        for line in lines where !DevicePromise.found(in: line.text).isEmpty {
            let allowed = Self.allowedResources.contains { $0.file == line.file && $0.text == line.text }
            #expect(allowed, "\(line.file): \"\(line.text)\" promises \(DevicePromise.found(in: line.text)) without PrivacyPlace")
        }
        for entry in Self.allowedResources {
            #expect(entry.reason.count > 40, "\(entry.file): say why")
            #expect(lines.contains { $0.file == entry.file && $0.text == entry.text }, "no longer in \(entry.file): \(entry.text)")
        }
    }

    /// The sweep sees a usage description, the place such a promise
    /// usually hides.
    @Test func theResourceSweepWouldCatchAUsageDescription() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>NSMicrophoneUsageDescription</key><string>Your voice stays on this device.</string>
            <key>Nested</key><dict><key>NSSpeechRecognitionUsageDescription</key><string>Nothing is sent anywhere.</string></dict>
            </dict></plist>
            """
        let found = try Self.plistStrings(Data(plist.utf8)).filter { !DevicePromise.found(in: $0).isEmpty }
        #expect(found.count == 2)
    }
}
