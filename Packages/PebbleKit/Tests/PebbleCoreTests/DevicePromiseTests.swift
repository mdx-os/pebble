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

    /// `line` as a person reads it: a `\u{...}` escape becomes its character,
    /// then a `\n`, `\t` or `\r` escape, a `\` that joins two lines of a
    /// multi-line literal, and every run of white space or line breaks
    /// become one space. So a phrase wrapped across the lines of a `"""`
    /// literal, or split by an escape, is still one phrase.
    static func folded(_ line: String) -> String {
        decodingUnicodeEscapes(line)
            .replacingOccurrences(of: #"\\(?:[ntr]|\n)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// `text` with each `\u{...}` escape replaced by the character it names.
    static func decodingUnicodeEscapes(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\\u\{([0-9a-fA-F]{1,8})\}"#)
        let ns = text as NSString
        var result = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1))
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
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
        /// When set, the code just before the literal must end with this,
        /// white space aside, so a short word is allowed only where it is
        /// written for its reason and not as a `Text` elsewhere in the file.
        var after: String? = nil
    }

    static let allowed: [Allowed] = [
        Allowed(file: "PebbleCore/Memory.swift",
                literal: "This removes every note, every task and every morning summary from this device, stops any task still going, and turns off work while you're away. It can't be undone. Your choice about nudges stays as it is.",
                reason: "MemoryWords.forgetEverythingDetail is about where the notes, tasks and summaries are, not where "
                    + "the chat goes. Notes live only in MemoryStore's local file, tasks only in the engine in this "
                    + "process, and summaries only in BackgroundStore's file beside the notes, whatever the model is, "
                    + "so it is true with a cloud model too."),
        Allowed(file: "PebbleCore/Memory.swift",
                literal: "This removes every note and every task from this device, and stops any task still going. It can't be undone. Your choice about nudges stays as it is.",
                reason: "MemoryWords.forgetEverythingDetail with no background work: where the notes and tasks are, "
                    + "not where the chat goes, so it is true with a cloud model too."),
        Allowed(file: "PebbleCore/Tasks.swift",
                literal: "This stops any task still going, and removes every task and what you told me for it from this device. It can't be undone. Your notes aren't touched, and your choice about nudges stays as it is.",
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

    /// Each form of `CloudWords.forgotAndCloudOffNotSummaries`.
    static let cloudSummariesStayed = "CloudWords.forgotAndCloudOffNotSummaries, a Forget everything status line, in "
        + "the form for what went. Its phrases are \"private words\", the name of the person's list in the cloud "
        + "setting, which it says went, and \"cloud\", the name of that setting, which it says is off. The summaries "
        + "clause says what stayed, BackgroundStore's local file, and promises nothing about where a chat goes, so it "
        + "is true with the cloud on or off."

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
                literal: "This removes every note, every task and every word you asked me to hide from this device, and stops any task still going. It can't be undone. Your choice about nudges stays as it is.",
                reason: "CloudWords.forgetEverythingDetail, like MemoryWords.forgetEverythingDetail: it names where the "
                    + "notes, tasks and private words are erased from, all local files, whatever the model is."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "This removes every note, every task, every morning summary and every word you asked me to hide from this device, stops any task still going, and turns off work while you're away. It can't be undone. Your choice about nudges stays as it is.",
                reason: "CloudWords.forgetEverythingWithSummariesDetail, like MemoryWords.forgetEverythingDetail with "
                    + "background work: it names where the notes, tasks, summaries and private words are erased from, "
                    + "all local files, whatever the model is."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "I forgot your notes and tasks, and turned off work while you're away, but I couldn't erase your morning summaries just now. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget everything again in a moment.",
                reason: cloudSummariesStayed),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "I forgot your notes and turned off work while you're away, but I couldn't erase your morning summaries just now. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget everything again in a moment.",
                reason: cloudSummariesStayed),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "I forgot your tasks and turned off work while you're away, but I couldn't erase your morning summaries just now. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget everything again in a moment.",
                reason: cloudSummariesStayed),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "I turned off work while you're away, but I couldn't erase your morning summaries just now. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget everything again in a moment.",
                reason: cloudSummariesStayed),
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
                literal: "This stops any task still going, and removes every task, what you told me for it and any words you asked me to hide from this device. It can't be undone. Your notes aren't touched, and your choice about nudges stays as it is.",
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
                literal: "Help from the cloud is off now, so I didn't send that. What you wrote is still here.",
                reason: cloudSettingName + " CloudWords.turnedOff: its only \"cloud\" is the setting's name, Help from "
                    + "the cloud, and \"still here\" is the composer, where the words go back."),
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Your tasks are forgotten, and so are any words you asked me to hide. To be sure of that I cleared the cloud setting too, so help from the cloud is off.",
                reason: cloudSettingName + " CloudWords.tasksAndWordsAndCloudForgotten: the setting was erased, so it reads "
                    + "as off, which is what it says."),
        Allowed(file: "PebbleCore/CloudHelp.swift", literal: "cloud-help.json",
                reason: "The name of the file the cloud setting is kept in, beside the notes. Never shown to anyone."),
        Allowed(file: "PebbleUI/CloudHelpView.swift", literal: "cloud.fill",
                reason: "An SF Symbol name for the setting's icon. VoiceOver never reads it and nobody sees the word."),
        Allowed(file: "PebbleUI/CloudHelpView.swift", literal: "cloud",
                reason: "An SF Symbol name in the list the cloud question's icons are checked against. Never shown.",
                after: "private static let symbols = ["),
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

    /// The only files that make a `LocalStubModel`: the app, which wires it
    /// in as the model, the Debug showcase, and the stub itself.
    static let stubMakers: Set<String> = [
        "App/Sources/PebbleApp.swift",
        "PebbleUI/ShowcaseScene.swift",
        "PebbleModel/LocalStubModel.swift",
    ]

    /// The words the competitor watch's fit score looks for.
    static let ideaFitKeywords = ["upload", "cloud data storage", "on our servers", "requires cloud", "cloud only"]

    /// True when `text` in `file` is an allowed line, word for word, with
    /// `before`, the code ahead of it, ending as the entry asks.
    static func isAllowed(_ text: String, in file: String, before: String) -> Bool {
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.contains { entry in
            entry.file == file && entry.literal == text && entry.after.map { lead.hasSuffix($0) } ?? true
        }
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
        MemoryWords.forgetEverythingDetail(background: true),
        MemoryWords.forgetEverythingDetail(background: false),
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
        CloudWords.forgetEverythingWithSummariesDetail,
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
    ] + CloudWords.forgotAndCloudOffNotSummariesLines + CloudWords.askPoints.filter { !found(in: $0).isEmpty }

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
    /// `return`, a call's `(` right after its name, `[`, `{`, `,`, `:` or
    /// the start of the file. A negated flag (`!place.staysOnDevice ?`,
    /// `!(place.staysOnDevice) ?`) or one inside a compound condition
    /// (`isRemote || (place.staysOnDevice) ?`) is not gated, since a
    /// grouping paren after `!`, `||` or `&&` starts nothing. Each `)`
    /// after the flag must close one of the grouping parens before it, so
    /// `f(place.staysOnDevice) ?` is a call's result and never gates.
    static func isGated(_ literal: SwiftSource.Literal, in source: SwiftSource) -> Bool {
        // All the code before it, so a condition that starts many lines up
        // is still seen whole.
        let before = String(source.code[..<literal.offset])
        let receiver = #"(?:self\s*\.\s*place|place|model\s*\.\s*privacyPlace|privacyPlace)"#
        let pattern = #"(?:\A|(?<=\w)\(|[\[{,:]|(?<![=!<>])=|\breturn)\s*((?:\(\s*)*)"# + receiver
            + #"\s*\.\s*staysOnDevice\s*((?:\)\s*)*)\?\s*\z"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = before as NSString
        guard let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        func parens(_ index: Int) -> Int {
            ns.substring(with: match.range(at: index)).filter { $0 == "(" || $0 == ")" }.count
        }
        return parens(2) <= parens(1)
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
    /// - `LocalStubModel()` is made only in `stubMakers` and in a
    ///   `#Preview`, so its `.onDevice` is never a screen's own promise.
    /// True when UTF-16 offset `location` of `code` is inside the braces of a
    /// `#Preview`. A preview's scope ends where its own braces close, so
    /// code after it is never inside it, however many braces open later.
    static func isInPreview(at location: Int, in code: String) -> Bool {
        let units = Array(code.utf16)
        let marker = Array("#Preview".utf16)
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
        var start = 0
        while start + marker.count <= location {
            guard Array(units[start..<start + marker.count]) == marker else {
                start += 1
                continue
            }
            // The preview's first `{`, and the `}` that brings it back to zero.
            var depth = 0, first: Int?, end = start + marker.count
            while end < units.count {
                if units[end] == open {
                    depth += 1
                    if first == nil { first = end }
                }
                if units[end] == close, first != nil {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            if let first, first < location, location < end { return true }
            start = end + 1
        }
        return false
    }

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
        // Whatever comes before the dot: a type alias of the place, its
        // metatype or `type(of:)` reach the same case.
        if !["PebbleCore/PrivacyPlace.swift", "PebbleModel/ModelClient.swift"].contains(file) {
            each(#"\.\s*(onDevice|mayLeaveDevice)\b(?!\s*\()"#) { match, ns in
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
            // Another name for the place hides it from the reads above.
            for alias in typealiases(in: code)
            where alias.target.range(of: #"\bPrivacyPlace\b"#, options: .regularExpression) != nil {
                problems.append("\(file):\(source.line(at: alias.offset)): typealias = \(alias.target) "
                    + "is another name for PrivacyPlace, so its cases could be written unseen")
            }
        }
        // `all()` of no places at all would be `.onDevice` with no model
        // behind it. Its signature needs one place; this keeps it so.
        each(#"(?:\b(?:PrivacyPlace|Self)\s*|(?<![\w)\]]))\.\s*all\s*\(\s*\)"#) { _, _ in
            "PrivacyPlace.all() of no places promises the device with no model behind it"
        }
        for call in source.calls(named: ["PrivacyPlace"]) where call.arguments.contains("staysOnDevice:") {
            if file != "PebbleModel/ModelClient.swift" || call.arguments != "staysOnDevice: runsOnDevice" {
                problems.append("\(file):\(call.line): PrivacyPlace(\(call.arguments)) is made only by ModelClient, from runsOnDevice")
            }
        }
        // A stand-in model, made anywhere, would be a model whose place is
        // `.onDevice` with no real model behind it, so a screen could make
        // the device promise from `LocalStubModel().privacyPlace`. It is made
        // only by the app's wiring and the showcase, its own file, and in a
        // `#Preview`, which no person sees.
        if !DevicePromise.stubMakers.contains(file) {
            each(#"\bLocalStubModel\s*(?:\(|\.\s*init\b)"#) { match, ns in
                if DevicePromise.isInPreview(at: match.range.location, in: code) { return nil }
                return "LocalStubModel() is made only by the app's wiring and the showcase, "
                    + "so no screen takes its place without the real model"
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

    /// What `PrivacyPlace` is declared to conform to, in order, or nil when
    /// its declaration isn't found.
    static func placeConformances(in text: String) -> [String]? {
        let code = String(SwiftSource(text).code)
        guard let found = code.range(of: #"\benum\s+PrivacyPlace\b[^{]*"#, options: .regularExpression) else {
            return nil
        }
        let header = code[found]
        guard let colon = header.firstIndex(of: ":") else { return [] }
        return header[header.index(after: colon)...].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The only files that may make a type a `ModelClient`. Any model says
    /// `runsOnDevice`, and the gate trusts the place made from it, so a
    /// screen with a model of its own could claim the device with no real
    /// model behind it. A new adapter is added here on purpose.
    static let modelMakers: Set<String> = [
        "PebbleModel/ModelClient.swift",
        "PebbleModel/LocalStubModel.swift",
        "PebbleModel/CloudModel.swift",
    ]

    /// Each type in `source` made a `ModelClient` outside `modelMakers`: a
    /// struct, class, actor, enum or protocol that lists it, an extension
    /// that adds it, or an extension of `ModelClient` itself, which could
    /// say `runsOnDevice` for every model.
    static func modelProblems(in source: SwiftSource, file: String) -> [String] {
        guard !modelMakers.contains(file) else { return [] }
        let code = String(source.code)
        let ns = code as NSString
        let patterns = [
            #"\b(?:struct|class|actor|enum|protocol|extension)\s+[\w.]+(?:\s*<[^>{]*>)?\s*:[^{]*\bModelClient\b"#,
            #"\bextension\s+(?:PebbleModel\s*\.\s*)?ModelClient\b"#,
        ]
        var problems: [String] = []
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                problems.append("\(file):\(source.line(at: match.range.location)): only "
                    + "\(modelMakers.sorted().joined(separator: ", ")) may make a ModelClient")
            }
        }
        for alias in typealiases(in: code) where alias.target.range(of: #"\bModelClient\b"#, options: .regularExpression) != nil {
            problems.append("\(file):\(source.line(at: alias.offset)): typealias = \(alias.target) names ModelClient, "
                + "so a type could conform to it without saying so")
        }
        return problems
    }

    /// Every `typealias` in `code`, with what it stands for. The right side
    /// runs on while a line ends with `&` or the next one starts with it,
    /// or a bracket is still open, so `Sendable &\n    ModelClient` and
    /// `(Int,\n    PrivacyPlace)` are read whole.
    static func typealiases(in code: String) -> [(offset: Int, target: String)] {
        let ns = code as NSString
        let regex = try! NSRegularExpression(pattern: #"\btypealias\s+\w+(?:\s*<[^>=]*>)?\s*="#)
        var found: [(Int, String)] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let rest = ns.substring(from: match.range.location + match.range.length)
            var lines = rest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var target = lines.isEmpty ? "" : lines.removeFirst()
            func open(_ opener: Character, _ closer: Character) -> Bool {
                target.filter { $0 == opener }.count > target.filter { $0 == closer }.count
            }
            while let next = lines.first,
                  target.trimmingCharacters(in: .whitespaces).hasSuffix("&")
                    || next.trimmingCharacters(in: .whitespaces).hasPrefix("&")
                    || open("(", ")") || open("[", "]") || open("<", ">") {
                target += " " + lines.removeFirst()
            }
            found.append((match.range.location, target.trimmingCharacters(in: .whitespaces)))
        }
        return found
    }

    /// Each type in a model maker's `source` that is a `ModelClient`, with
    /// what kind of type it is. A class open to subclassing would hand its
    /// conformance, and its `runsOnDevice`, to any subclass anywhere, and a
    /// protocol that refines `ModelClient` would let any type conform
    /// without naming it, so each must be a struct, enum, actor or final
    /// class, written in its own declaration.
    static func makerKindProblems(in source: SwiftSource, file: String) -> [String] {
        let code = String(source.code)
        let ns = code as NSString
        let modifier = #"(?:@[\w.]+(?:\([^)]*\))?\s+|\b(?:public|internal|package|private|fileprivate|open|final)\s+)*"#
        let regex = try! NSRegularExpression(pattern: "(" + modifier + #")\b(struct|class|actor|enum|protocol|extension)\s+([\w.]+)"#
            + #"(?:\s*<[^>{]*>)?\s*:[^{]*\bModelClient\b"#)
        var problems: [String] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let modifiers = ns.substring(with: match.range(at: 1))
            let kind = ns.substring(with: match.range(at: 2))
            let name = ns.substring(with: match.range(at: 3))
            let line = "\(file):\(source.line(at: match.range.location)): \(name)"
            switch kind {
            case "class" where modifiers.range(of: #"\bfinal\b"#, options: .regularExpression) == nil
                || modifiers.range(of: #"\bopen\b"#, options: .regularExpression) != nil:
                problems.append("\(line) is a class open to subclassing, so a subclass anywhere is a ModelClient too")
            case "protocol":
                problems.append("\(line) refines ModelClient, so a type could conform to it without saying so")
            case "extension":
                problems.append("\(line) gets ModelClient in an extension; say it where the type is declared")
            default:
                break
            }
        }
        return problems
    }

    /// The names of the `ModelClient` types `source` declares.
    static func modelTypes(in source: SwiftSource) -> [String] {
        let code = String(source.code)
        let ns = code as NSString
        let regex = try! NSRegularExpression(pattern: #"\b(?:struct|class|actor|enum)\s+(\w+)(?:\s*<[^>{]*>)?\s*:[^{]*\bModelClient\b"#)
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Each `extension PrivacyPlace` in `source`, with or without a colon,
    /// in any file, its own too. Even a plain extension could make a place
    /// with no model behind it, as in `static var here: PrivacyPlace {
    /// onDevice }`, where the case needs no dot, and the reads of `.here`
    /// elsewhere would never name a case. A conformance could build one
    /// from a raw value, a list or a decoder.
    static func placeExtensionProblems(in source: SwiftSource, file: String) -> [String] {
        let code = String(source.code)
        let ns = code as NSString
        let regex = try! NSRegularExpression(pattern: #"\bextension\s+(?:PebbleCore\s*\.\s*)?PrivacyPlace\b(\s*:)?"#)
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { match in
            let conforms = match.range(at: 1).location != NSNotFound
            return "\(file):\(source.line(at: match.range.location)): "
                + (conforms ? "adds a conformance to PrivacyPlace" : "extends PrivacyPlace, whose members are pinned")
        }
    }

    /// Everything `PrivacyPlace.swift` may declare. The file is exempt from
    /// the `.onDevice` reads above, so any other member there, a static,
    /// an init, a factory or a nested type's, could hand out a place with
    /// no model behind it under a name nothing else checks. A new one is
    /// added here on purpose, once the guard has learned its form.
    static let placeMembers: Set<String> = [
        "enum PrivacyPlace",
        "case onDevice",
        "case mayLeaveDevice",
        "init(staysOnDevice:)",
        "var staysOnDevice",
        "func all(_:_:)",
    ]

    /// Each declaration in `source`, written as in `placeMembers`: a
    /// `case` by name (`case a, b` is two), an `init` or `func` by its
    /// labels, and any other declaration by its keyword and name.
    static func declarations(in source: SwiftSource) -> [(offset: Int, name: String)] {
        let code = String(source.code)
        let ns = code as NSString
        let keyword = #"\b(case|init|func|var|let|subscript|typealias|associatedtype|struct|class|enum|actor|protocol|extension|macro)\b"#
        let regex = try! NSRegularExpression(pattern: keyword)
        func labels(_ list: String) -> String {
            list.split(separator: ",").map { parameter in
                let label = parameter.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                return label + ":"
            }.joined()
        }
        var found: [(Int, String)] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range)
            let rest = ns.substring(from: match.range.location + match.range.length)
            switch kind {
            case "case":
                let line = rest.prefix { $0 != "\n" && $0 != "{" && $0 != "=" }
                let names = String(line).replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                for name in names.split(separator: ",") {
                    found.append((match.range.location, "case " + name.trimmingCharacters(in: .whitespaces)))
                }
            case "init", "func", "subscript":
                let head = rest.range(of: #"^\s*([^\s(<]*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)"#, options: .regularExpression)
                    .map { String(rest[$0]) } ?? rest
                let name = head.range(of: #"^\s*[^\s(<]*"#, options: .regularExpression)
                    .map { head[$0].trimmingCharacters(in: .whitespaces) } ?? ""
                let list = head.range(of: #"\(([^)]*)\)"#, options: .regularExpression)
                    .map { String(head[$0].dropFirst().dropLast()) } ?? ""
                let prefix = kind == "func" ? "func \(name)" : kind + name
                found.append((match.range.location, "\(prefix)(\(labels(list)))"))
            default:
                let name = rest.range(of: #"^\s*[\w.]+"#, options: .regularExpression)
                    .map { rest[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                found.append((match.range.location, kind + " " + name))
            }
        }
        return found
    }

    /// Each declaration in `PrivacyPlace.swift` that isn't in
    /// `placeMembers`, so the only ways to a place are its cases, which the
    /// guard above keeps to the model, and `init(staysOnDevice:)`, made only
    /// by `ModelClient`.
    static func placeMemberProblems(in source: SwiftSource, file: String) -> [String] {
        guard file == "PebbleCore/PrivacyPlace.swift" else { return [] }
        return declarations(in: source).compactMap { declaration in
            placeMembers.contains(declaration.name) ? nil
                : "\(file):\(source.line(at: declaration.offset)): \(declaration.name) is not one of PrivacyPlace's "
                    + "pinned members, so it could hand out a place with no model behind it"
        }
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
                if DevicePromise.isAllowed(text, in: file.name, before: String(source.code[..<first.offset])) { continue }
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
    /// next chat's place, so it promises nothing about the device or the
    /// cloud. Its one phrase is the setting's name, allowed with that
    /// reason, and with the name taken out no phrase is left.
    @Test func theTurnedOffLinePromisesNothing() {
        #expect(DevicePromise.found(in: CloudWords.turnedOff) == ["cloud"])
        #expect(CloudWords.turnedOff.hasPrefix(CloudWords.title))
        let rest = CloudWords.turnedOff.replacingOccurrences(of: CloudWords.title, with: "")
        #expect(DevicePromise.found(in: rest).isEmpty, "more than the setting's name: \(rest)")
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
            #"let line = !(place.staysOnDevice) ? "It stays on this device." : "Hi.""#,
            #"let line = isRemote || (place.staysOnDevice) ? "It stays on this device." : "Hi.""#,
            #"let line = isRemote && (place.staysOnDevice) ? "It stays on this device." : "Hi.""#,
            #"let line = isRemote && place.staysOnDevice ? "It stays on this device." : "Hi.""#,
            #"let line = flipped(place.staysOnDevice) ? "It stays on this device." : "Hi.""#,
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
            #"static let x = "It never\u{0020}leaves.""#,
            #"static let x = "Only\u{A}you can read it.""#,
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
            #"Text((place.staysOnDevice) ? "Kept only on this device." : "Kept.")"#,
            #"let line = ((place.staysOnDevice) ? "I run on this device." : "Hi.")"#,
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
        #expect(DevicePromise.found(in: #"never\u{0020}leaves"#) == ["never leaves"])
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
            // The place under another name, or reached through its type.
            "typealias Place = PrivacyPlace\nlet place = Place.onDevice",
            "typealias Place = PebbleCore.PrivacyPlace",
            "typealias Places = [PrivacyPlace]",
            "typealias Pair = (Int,\n    PrivacyPlace)",
            "let place = type(of: model.privacyPlace).onDevice",
            "let kind = PrivacyPlace.self\nlet place = kind.onDevice",
            // A place made of no places, which would read as on the device.
            "let place = PrivacyPlace.all()",
            "let place = PrivacyPlace\n    .all( )",
            "f(place: .all())",
            // A stand-in model made by a screen, whose place reads as the device.
            "MemoryView(store: store, place: LocalStubModel().privacyPlace)",
            "init(model: any ModelClient = LocalStubModel()) {}",
            "let model = LocalStubModel\n    .init()",
            "#Preview { Text(\"a\") }\nlet model = LocalStubModel()",
            // A preview's scope ends at its own closing brace, whatever opens after it.
            "#Preview { Text(\"a\") }\nstruct Screen: View {\n    var body: some View {\n"
                + "        Text(LocalStubModel().privacyPlace.staysOnDevice ? \"a\" : \"b\")\n    }\n}",
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
            "let place = PrivacyPlace.all(chat.privacyPlace, model.privacyPlace)",
            "let lines = CloudWords.all()",
            "let reply = (try? LocalStubModel.answer(to: turns)) ?? LocalStubModel.fallback",
            "typealias RGB = Contrast.RGB",
            "typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)",
            "let store = try CloudHelpFileStore.onDevice()",
            "#Preview {\n    ChatView(brand: brand, model: LocalStubModel())\n}",
            "#Preview { Text(\"a\") }\n#Preview(\"Chat\") {\n    VStack {\n        ChatView(brand: brand, model: LocalStubModel())\n    }\n}",
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
        let stub = "HomeView(brand: brand, model: LocalStubModel())"
        for maker in DevicePromise.stubMakers {
            #expect(DevicePromise.placeProblems(in: SwiftSource(stub), file: maker).isEmpty, "\(maker)")
        }
        #expect(!DevicePromise.placeProblems(in: SwiftSource(stub), file: "PebbleUI/HomeView.swift").isEmpty)
        let flag = "public var staysOnDevice: Bool { self == .onDevice }"
        #expect(DevicePromise.placeProblems(in: SwiftSource(flag), file: "PebbleCore/PrivacyPlace.swift").isEmpty)
        #expect(!DevicePromise.placeProblems(in: SwiftSource(flag), file: "PebbleCore/Other.swift").isEmpty)
    }

    /// PERMANENT GUARD. Only the files in `modelMakers` make a type a
    /// `ModelClient`, so no screen has a model of its own that claims the
    /// device.
    @Test func onlyTheModelLayerMakesAModel() throws {
        let files = try Self.sources()
        for file in files {
            for problem in DevicePromise.modelProblems(in: SwiftSource(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
        for maker in DevicePromise.modelMakers {
            #expect(files.contains { $0.name == maker }, "no longer there: \(maker)")
        }
        let wrong = [
            "struct Here: ModelClient { var runsOnDevice: Bool { true } }",
            "final class Here: NSObject, ModelClient {\n    var runsOnDevice: Bool { true }\n}",
            "extension Settings: ModelClient { var runsOnDevice: Bool { true } }",
            "actor Here: Sendable,\n    PebbleModel.ModelClient {}",
            "struct Box<T>: ModelClient {}",
            "protocol Local: ModelClient {}",
            "extension ModelClient { var runsOnDevice: Bool { true } }",
            // The model under another name, alone or in a composition.
            "typealias Local = Sendable & ModelClient\nstruct Here: Local { var runsOnDevice: Bool { true } }",
            "typealias Local = ModelClient",
            "typealias Local = PebbleModel.ModelClient",
            "typealias Local = Sendable &\n    ModelClient",
            "typealias Local = Sendable\n    & ModelClient",
        ]
        for text in wrong {
            #expect(!DevicePromise.modelProblems(in: SwiftSource(text), file: "PebbleUI/Wrong.swift").isEmpty,
                    "missed: \(text)")
        }
        let right = [
            "let model: any ModelClient",
            "init(model: any ModelClient) {}",
            "struct Screen: View {\n    let model: any ModelClient\n}",
            "func reply<M: ModelClient>(from model: M) {}",
            "// struct Here: ModelClient, in a comment",
            "let note = \"extension Here: ModelClient\"",
            "typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)",
            "typealias Local = Sendable\nlet model: any ModelClient",
        ]
        for text in right {
            #expect(DevicePromise.modelProblems(in: SwiftSource(text), file: "PebbleUI/Right.swift").isEmpty,
                    "flagged: \(text)")
        }
        let stub = "public struct LocalStubModel: ModelClient {}"
        #expect(DevicePromise.modelProblems(in: SwiftSource(stub), file: "PebbleModel/LocalStubModel.swift").isEmpty)
        let alias = "public typealias Local = Sendable & ModelClient"
        #expect(DevicePromise.modelProblems(in: SwiftSource(alias), file: "PebbleModel/ModelClient.swift").isEmpty)
    }

    /// PERMANENT GUARD. Every model a maker file makes is a struct, enum,
    /// actor or final class, so no subclass elsewhere inherits its
    /// `runsOnDevice`, and no protocol there refines `ModelClient`.
    @Test func everyModelIsClosedToSubclasses() throws {
        let files = try Self.sources()
        var made: [String] = []
        for file in files where DevicePromise.modelMakers.contains(file.name) {
            let source = SwiftSource(file.text)
            made += DevicePromise.modelTypes(in: source)
            for problem in DevicePromise.makerKindProblems(in: source, file: file.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
        #expect(made.contains("LocalStubModel"))
        #expect(made.contains("CloudModel"))
        let wrong = [
            "public class LocalStubModel: ModelClient {}",
            "class CloudModel: @unchecked Sendable, ModelClient {}",
            "open class Base: ModelClient {}",
            "public open class Base: ModelClient {}",
            "@MainActor public class Base: ModelClient {}",
            "public protocol LocalModel: ModelClient {}",
            "extension NSObject: ModelClient {}",
        ]
        for text in wrong {
            #expect(!DevicePromise.makerKindProblems(in: SwiftSource(text), file: "PebbleModel/LocalStubModel.swift").isEmpty,
                    "missed: \(text)")
        }
        let right = [
            "public struct LocalStubModel: ModelClient {}",
            "public final class Stub: ModelClient {}",
            "@MainActor public final class Stub: Sendable, ModelClient {}",
            "final public class Stub: ModelClient {}",
            "public actor Stub: ModelClient {}",
            "enum Stub: ModelClient {}",
            "public protocol ModelClient: Sendable {}",
            "extension ModelClient { var privacyPlace: PrivacyPlace { .mayLeaveDevice } }",
        ]
        for text in right {
            #expect(DevicePromise.makerKindProblems(in: SwiftSource(text), file: "PebbleModel/LocalStubModel.swift").isEmpty,
                    "flagged: \(text)")
        }
    }

    /// A place can be had without writing `.onDevice` if `PrivacyPlace`
    /// can be built from a raw value, listed, or decoded: through
    /// `PrivacyPlace(rawValue:)`, `allCases.first`, or
    /// `decode(PrivacyPlace.self, ...)`. It conforms to none of those, so
    /// none of those forms compile. This fails the day one is added, here
    /// or in an extension anywhere, and the guard above must then learn
    /// those forms first. Nothing extends it, and its own file declares
    /// only `placeMembers`, so no other name hands out a place.
    @Test func aPlaceCanOnlyBeMadeByTheModel() throws {
        let files = try Self.sources()
        let file = try #require(files.first { $0.name == "PebbleCore/PrivacyPlace.swift" })
        #expect(DevicePromise.placeConformances(in: file.text) == ["Sendable", "Hashable"])
        for other in files {
            for problem in DevicePromise.placeExtensionProblems(in: SwiftSource(other.text), file: other.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
        let extensions = [
            "extension PrivacyPlace { static var here: PrivacyPlace { onDevice } }",
            "extension PebbleCore.PrivacyPlace {}",
            "extension PrivacyPlace: CaseIterable {}",
            "extension PrivacyPlace\n    : Codable {}",
            "public extension PrivacyPlace where Self == PrivacyPlace {}",
        ]
        for text in extensions {
            #expect(!DevicePromise.placeExtensionProblems(in: SwiftSource(text), file: "PebbleUI/Wrong.swift").isEmpty,
                    "missed: \(text)")
        }
        #expect(!DevicePromise.placeExtensionProblems(in: SwiftSource(extensions[0]), file: "PebbleCore/PrivacyPlace.swift").isEmpty,
                "not even its own file may extend it")
        #expect(!DevicePromise.placeExtensionProblems(in: SwiftSource(extensions[2]), file: "PebbleCore/PrivacyPlace.swift").isEmpty,
                "nor add a conformance there")
        // Its own file declares only the pinned members.
        let own = "PebbleCore/PrivacyPlace.swift"
        for problem in DevicePromise.placeMemberProblems(in: SwiftSource(file.text), file: own) {
            Issue.record(Comment(rawValue: problem))
        }
        #expect(Set(DevicePromise.declarations(in: SwiftSource(file.text)).map(\.name)) == DevicePromise.placeMembers,
                "every pinned member is still there")
        let enumOpen = "public enum PrivacyPlace: Sendable, Hashable {\n    case onDevice\n    case mayLeaveDevice\n"
        let minted = [
            "    public static var here: PrivacyPlace { .onDevice }\n}",
            "    public static let here = onDevice\n}",
            "    public static func make() -> Self { .onDevice }\n}",
            "    public init() { self = .onDevice }\n}",
            "    public init?(_ text: String) { self = .onDevice }\n}",
            "    public init(staysOnDevice: Bool, really: Bool) { self = .onDevice }\n}",
            "    case here\n}",
            "    case here, there\n}",
            "    public subscript(_ index: Int) -> PrivacyPlace { .onDevice }\n}",
            "}\npublic enum Places { public static let here = PrivacyPlace.onDevice }",
            "}\nextension PrivacyPlace { static var here: PrivacyPlace { onDevice } }",
        ]
        for tail in minted {
            #expect(!DevicePromise.placeMemberProblems(in: SwiftSource(enumOpen + tail), file: own).isEmpty, "missed: \(tail)")
        }
        let pinned = enumOpen + "    public init(staysOnDevice: Bool) { self = staysOnDevice ? .onDevice : .mayLeaveDevice }\n"
            + "    public var staysOnDevice: Bool { self == .onDevice }\n"
            + "    public static func all(_ first: PrivacyPlace, _ rest: PrivacyPlace...) -> PrivacyPlace { first }\n}"
        #expect(DevicePromise.placeMemberProblems(in: SwiftSource(pinned), file: own).isEmpty)
        #expect(DevicePromise.placeMemberProblems(in: SwiftSource(enumOpen + minted[0]), file: "PebbleCore/Other.swift").isEmpty,
                "pinned in its own file; elsewhere the reads above see .onDevice")
        for text in ["extension PrivacyPlaceTests {}", "// extension PrivacyPlace {}", "let place: PrivacyPlace"] {
            #expect(DevicePromise.placeExtensionProblems(in: SwiftSource(text), file: "PebbleUI/Right.swift").isEmpty,
                    "flagged: \(text)")
        }
        // The check reads what it is meant to.
        for wrong in ["public enum PrivacyPlace: String, Sendable, Hashable {", "public enum PrivacyPlace: Sendable, Hashable, CaseIterable {",
                      "public enum PrivacyPlace: Sendable, Hashable, Codable {", "public enum PrivacyPlace: Int {"] {
            #expect(DevicePromise.placeConformances(in: wrong) != ["Sendable", "Hashable"], "missed: \(wrong)")
        }
    }

    /// The Forget everything question is built by a function with one
    /// branch for background work and one without. Each branch goes
    /// through the guard on its own: the sweep sees its literal, it has its
    /// own entry by exact words, and a word added to either one is caught.
    /// The same for the cloud's two questions and the summaries status lines.
    @Test func bothForgetEverythingBranchesGoThroughTheGuard() throws {
        let files = try Self.sources()
        let lines: [(file: String, line: String)] = [
            ("PebbleCore/Memory.swift", MemoryWords.forgetEverythingDetail(background: true)),
            ("PebbleCore/Memory.swift", MemoryWords.forgetEverythingDetail(background: false)),
            ("PebbleCore/CloudHelp.swift", CloudWords.forgetEverythingDetail),
            ("PebbleCore/CloudHelp.swift", CloudWords.forgetEverythingWithSummariesDetail),
        ] + CloudWords.forgotAndCloudOffNotSummariesLines.map { (file: "PebbleCore/CloudHelp.swift", line: $0) }
        #expect(Set(CloudWords.forgotAndCloudOffNotSummariesLines).count == 4, "a form for each of what went")
        #expect(MemoryWords.forgetEverythingDetail(background: true)
                != MemoryWords.forgetEverythingDetail(background: false))
        for (name, line) in lines {
            let file = try #require(files.first { $0.name == name })
            let source = SwiftSource(file.text)
            #expect(!DevicePromise.found(in: line).isEmpty, "something for the guard to check: \(line)")
            let literal = try #require(source.literals.first { $0.text == line }, "the sweep sees: \(line)")
            #expect(!DevicePromise.isGated(literal, in: source), "passes by its entry, not the flag: \(line)")
            let entries = DevicePromise.allowed.filter { $0.literal == line }
            #expect(entries.count == 1 && entries.first?.file == name, "its own entry: \(line)")
            #expect(entries.first?.reason != DevicePromise.privateWordsName, "its own reason: \(line)")
            #expect(Self.ungated(in: [file]).isEmpty)

            let quoted = "\"" + line + "\""
            #expect(file.text.components(separatedBy: quoted).count == 2, "written once: \(line)")
            let longer = file.text.replacingOccurrences(of: quoted, with: "\"" + line + " It stays private.\"")
            #expect(Self.ungated(in: [(name, longer)]).count == 1, "a word added is caught: \(line)")
        }
        // The summaries status lines that promise nothing need no entry.
        for line in MemoryWords.couldNotForgetSummariesLines + [MemoryWords.summariesGone, MemoryWords.summariesStayed] {
            #expect(DevicePromise.found(in: line).isEmpty, "\(line)")
            #expect(!DevicePromise.allowed.contains { $0.literal == line })
        }
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
        // A short word is allowed only where its reason says it is written.
        let view = "PebbleUI/CloudHelpView.swift"
        #expect(Self.ungated(in: [(view, #"private static let symbols = ["cloud", "eye"]"#)]).isEmpty)
        #expect(!Self.ungated(in: [(view, #"Text("cloud")"#)]).isEmpty, "the symbol's word shown as words")
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
