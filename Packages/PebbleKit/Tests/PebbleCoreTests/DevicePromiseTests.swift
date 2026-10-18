import Foundation
import GuardScan
import PebbleCore
import SourceScan
import Testing

/// What counts as a promise about the device or privacy, in one place.
/// docs/VOICE.md: say it only when `PrivacyPlace` says so. The phrases and
/// the source rules live in GuardScan (`PromisePhrases`, `PromiseRules`),
/// read through SwiftSyntax; the lines allowed by a written reason live here.
enum DevicePromise {
    static var phrases: [String] { PromisePhrases.phrases }

    /// The phrases in `line`, if any. The words of a phrase may be apart by
    /// any white space, line breaks included.
    static func found(in line: String) -> [String] {
        PromisePhrases.found(in: line)
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
        /// When set, the literal must be an element of the array literal
        /// bound to this name, so a short word is allowed only where it is
        /// written for its reason and not as a `Text` elsewhere in the file.
        var inList: String? = nil
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
                inList: "symbols"),
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

    /// True when the chain written `text` in `file` is an allowed line,
    /// word for word, and in the list its entry names, if it names one.
    static func isAllowed(_ text: String, in file: String, first: SyntaxSource.Literal, source: SyntaxSource) -> Bool {
        allowed.contains { entry in
            entry.file == file && entry.literal == text
                && entry.inList.map { PromiseRules.listName(holding: first) == $0 } ?? true
        }
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

    /// Every promise rule on one file, the words and the place alike: what
    /// the sweeps below record, and what the wrong-case suite asks of.
    static func findings(in source: SyntaxSource, file: String) -> [Finding] {
        PromiseRules.ungated(in: source, file: file, allows: { isAllowed($0, in: $1, first: $2, source: $3) })
            + PromiseRules.placeProblems(in: source, file: file)
            + PromiseRules.modelProblems(in: source, file: file)
            + (PromiseRules.modelMakers.contains(file) ? PromiseRules.makerKindProblems(in: source, file: file) : [])
            + PromiseRules.placeExtensionProblems(in: source, file: file)
            + PromiseRules.placeMemberProblems(in: source, file: file)
    }
}

/// PERMANENT GUARD. No word a person sees promises the device or privacy
/// unless `PrivacyPlace` decides it, or it is allowed below with a written
/// reason. Two sweeps: every string literal in the package sources and the
/// app, and every line in the copy lists the other tests keep. What each
/// rule must catch is in `GuardWrongCaseTests`.
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
        files.flatMap { file in
            PromiseRules.ungated(in: SyntaxSource.shared(file.text), file: file.name) {
                DevicePromise.isAllowed($0, in: $1, first: $2, source: $3)
            }.map { $0.report(in: file.name) }
        }
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
            let source = file.map { SyntaxSource.shared($0.text) }
            let literals = source?.chains.map { $0.map(\.written).joined() } ?? []
            #expect(literals.contains(entry.literal), "no longer in \(entry.file): \(entry.literal)")
            if let list = entry.inList {
                #expect(source?.literals.contains { $0.written == entry.literal && PromiseRules.listName(holding: $0) == list }
                            == true, "no longer in \(list): \(entry.literal)")
            }
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

    /// How a line is read for phrases: case, line breaks, curly apostrophes
    /// and invisible characters aside.
    @Test func phrasesAreReadAsAPersonReadsThem() {
        #expect(DevicePromise.found(in: "only one").isEmpty)
        #expect(!DevicePromise.found(in: "Kept ONLY on this device").isEmpty)
        #expect(DevicePromise.found(in: "Kept on this\n    device") == ["this device", "on this device"])
        #expect(DevicePromise.found(in: #"never\u{0020}leaves"#) == ["never leaves"])
        #expect(DevicePromise.found(in: "It doesn\u{2019}t leave") == ["doesn't leave"])
        #expect(DevicePromise.found(in: "never\u{200B}leaves") == ["never leaves"])
        #expect(DevicePromise.found(in: "never\u{2060}leaves") == ["never leaves"])
        #expect(DevicePromise.found(in: "pri\u{200B}vate") == ["private"])
        #expect(DevicePromise.found(in: "on\u{2011}device") == ["on-device"])
    }

    /// PERMANENT GUARD. The gate trusts `.staysOnDevice`, so only
    /// `PrivacyPlace` declares it, a place is only made by the model, and no
    /// Bool called `onDevice` is passed around that isn't `.staysOnDevice`
    /// itself.
    @Test func everyPlaceIsAPrivacyPlace() throws {
        for file in try Self.sources() {
            for problem in PromiseRules.placeProblems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }

    /// PERMANENT GUARD. Only the files in `modelMakers` make a type a
    /// `ModelClient`, so no screen has a model of its own that claims the
    /// device.
    @Test func onlyTheModelLayerMakesAModel() throws {
        let files = try Self.sources()
        for file in files {
            for problem in PromiseRules.modelProblems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
        for maker in PromiseRules.modelMakers {
            #expect(files.contains { $0.name == maker }, "no longer there: \(maker)")
        }
    }

    /// PERMANENT GUARD. Every model a maker file makes is a struct, enum,
    /// actor or final class, so no subclass elsewhere inherits its
    /// `runsOnDevice`, and no protocol there refines `ModelClient`.
    @Test func everyModelIsClosedToSubclasses() throws {
        let files = try Self.sources()
        var made: [String] = []
        for file in files where PromiseRules.modelMakers.contains(file.name) {
            let source = SyntaxSource.shared(file.text)
            made += PromiseRules.modelTypes(in: source)
            for problem in PromiseRules.makerKindProblems(in: source, file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
        #expect(made.contains("LocalStubModel"))
        #expect(made.contains("CloudModel"))
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
        let source = SyntaxSource.shared(file.text)
        #expect(PromiseRules.placeConformances(in: source) == ["Sendable", "Hashable"])
        for other in files {
            for problem in PromiseRules.placeExtensionProblems(in: SyntaxSource.shared(other.text), file: other.name) {
                Issue.record(Comment(rawValue: problem.report(in: other.name)))
            }
        }
        // Its own file declares only the pinned members.
        for problem in PromiseRules.placeMemberProblems(in: source, file: file.name) {
            Issue.record(Comment(rawValue: problem.report(in: file.name)))
        }
        #expect(Set(PromiseRules.declarations(in: source).map(\.name)) == PromiseRules.placeMembers,
                "every pinned member is still there")
        // The check reads what it is meant to.
        for wrong in ["public enum PrivacyPlace: String, Sendable, Hashable {}", "public enum PrivacyPlace: Sendable, Hashable, CaseIterable {}",
                      "public enum PrivacyPlace: Sendable, Hashable, Codable {}", "public enum PrivacyPlace: Int {}"] {
            #expect(PromiseRules.placeConformances(in: SyntaxSource(wrong)) != ["Sendable", "Hashable"], "missed: \(wrong)")
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
            let source = SyntaxSource.shared(file.text)
            #expect(!DevicePromise.found(in: line).isEmpty, "something for the guard to check: \(line)")
            let literal = try #require(source.literals.first { $0.value == line }, "the sweep sees: \(line)")
            #expect(!PromiseRules.isGated(literal, in: source), "passes by its entry, not the flag: \(line)")
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
        // Split with +, the whole joined line is what must match.
        let joined = "static let x = \"These are examples for now. \" + \"Nothing was sent or bought.\""
        #expect(Self.ungated(in: [(entry.file, joined)]).isEmpty)
        // A short word is allowed only in the list its reason names.
        let view = "PebbleUI/CloudHelpView.swift"
        #expect(Self.ungated(in: [(view, #"private static let symbols = ["cloud", "eye"]"#)]).isEmpty)
        #expect(Self.ungated(in: [(view, #"private static let symbols = ["eye", "cloud"]"#)]).isEmpty)
        #expect(!Self.ungated(in: [(view, #"Text("cloud")"#)]).isEmpty, "the symbol's word shown as words")
        #expect(!Self.ungated(in: [(view, #"private static let shown = ["cloud"]"#)]).isEmpty, "another list")
        #expect(!Self.ungated(in: [(view, #"private static let symbols = [Text("cloud")]"#)]).isEmpty, "not the list's own")
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
