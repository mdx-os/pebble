import PebbleCore

/// What counts as a promise about the device or privacy, in one place.
/// docs/VOICE.md: say it only when `PrivacyPlace` says so. The phrases
/// (`PromisePhrases`) and the lines allowed by a written reason live here,
/// in plain Swift, so the package's own tests read them. The source rules
/// that read Swift live in Tools/GuardKit, which reads these too.
public enum DevicePromise {
    public static var phrases: [String] { PromisePhrases.phrases }

    /// The phrases in `line`, if any. The words of a phrase may be apart by
    /// any white space, line breaks included.
    public static func found(in line: String) -> [String] {
        PromisePhrases.found(in: line)
    }

    /// A line the guard lets by without the flag, and why. Each one is a
    /// promise that is true whatever the model is.
    public struct Allowed: Sendable {
        /// The source file, from `Packages/PebbleKit/Sources` or `App`.
        public let file: String
        /// The whole literal, exactly as written between its quotes, escapes
        /// and interpolations included. Matched by equality, so words added
        /// to an allowed line later need a reason of their own.
        public let literal: String
        public let reason: String
        /// When set, the literal must be an element of the array literal
        /// bound to this name, so a short word is allowed only where it is
        /// written for its reason and not as a `Text` elsewhere in the file.
        public var inList: String? = nil

        init(file: String, literal: String, reason: String, inList: String? = nil) {
            self.file = file
            self.literal = literal
            self.reason = reason
            self.inList = inList
        }
    }

    public static let allowed: [Allowed] = [
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
                literal: "This stops any task still going, and removes every task and what you told me for it from this device. It can't be undone. Your notes aren't touched, and your choice about nudges stays as it is. Anything you've allowed until tonight or always stays allowed.",
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
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift", literal: "On-device model",
                reason: onDeviceModelName + " OnDeviceModelWords.title, the row's heading."),
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift", literal: "Download on-device model, about ",
                reason: onDeviceModelName + " The download button, built with the download's size after it."),
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift",
                literal: "Sorry, I can't really answer that yet. My on-device model isn't downloaded. To get it, open What I remember and choose Download on-device model. Until then I can plan a morning, say a detail back, or help you talk something through.",
                reason: onDeviceModelName + " Only the placeholder says it, in place of an answer, while nothing is "
                    + "downloaded; it names the button that gets the model."),
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift",
                literal: "Sorry, I can't really answer that yet. Some of my on-device model's files are missing. Open What I remember to download it again.",
                reason: onDeviceModelName + " Only the placeholder says it, while the downloaded folder isn't whole."),
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift",
                literal: "Sorry, I can't really answer that yet. My on-device model's files didn't open. Open What I remember to download it again.",
                reason: onDeviceModelName + " Only the placeholder says it, after the model's folder failed to load."),
        Allowed(file: "PebbleCore/OnDeviceModelWords.swift",
                literal: "Sorry, I can't really answer that here. There isn't enough memory free for my on-device model.",
                reason: onDeviceModelName + " Only the placeholder says it, when the weights are too big for the memory "
                    + "here."),
        Allowed(file: "PebbleModel/MLXChatModel.swift",
                literal: "You are the person's agent on this device. Reply in plain words. Stay with what they asked. Nothing from this conversation leaves the device.",
                reason: "OnDeviceTranscript.instructions, the system line the model reads, never a person. Only "
                    + "MLXChatModel sends it, to the weights it runs here (runsOnDevice is true), so the chat it "
                    + "opens never leaves the device."),
        Allowed(file: "PebbleCore/PulseNotice.swift", literal: "Privacy: 0. Adapt this idea or leave it.",
                reason: "The public source watch's note to the founder, never shown in the app. \"Privacy\" names the idea's "
                    + "privacy fit score, a number about someone else's product, and promises nothing about this one."),
        Allowed(file: "PebbleCore/PulseNotice.swift", literal: #"Privacy: \(fit.privacy)."#,
                reason: "The same privacy fit score in the public source watch's note to the founder, not app copy."),
        Allowed(file: "PebbleCore/PulseNotice.swift",
                literal: #"\(privacy) Local models: \(fit.localFirst). Open weights: \(fit.openWeights)."#,
                reason: "The public source watch's fit line, which only names its `privacy` score. A note to the founder, "
                    + "not app copy."),
        Allowed(file: "PebbleCore/Feed.swift", literal: "These are examples for now. Nothing was sent or bought.",
                reason: "FeedWords.sampleNote off the device. \"Nothing was sent\" is about the example cards' actions, "
                    + "which never ran, not about where words go, so it is true with any model."),
    ] + cloud + recon + ideaFitKeywords.map { keyword in
        Allowed(file: "PebbleCore/IdeaDraft.swift", literal: keyword,
                reason: "A keyword IdeaDraft.fit looks for in a product's own words, to score how private that "
                    + "product is. Matched with `contains`, never shown to anyone, and promises nothing about this app.")
    }

    /// "Private words" is the name of the person's own list in the cloud
    /// setting, the words `Redactor` always takes out. It names the list;
    /// it promises nothing about where a chat goes.
    public static let privateWordsName = "\"Private words\" names the list of words the person asked to hide (CloudHelp's private "
        + "words, `Redaction.Kind.privateWord`). It names that list and promises nothing about where a chat goes, so it "
        + "is true with the cloud on or off."

    /// "Help from the cloud" is the name of the setting that sends words
    /// off the device. Naming it says words may leave, the opposite of a
    /// device promise.
    public static let cloudSettingName = "\"Cloud\" names the setting that sends a new chat to a cloud model, or that model. "
        + "Naming it says words may leave, never that they stay."

    public static let onDeviceModelName = "\"On-device model\" names the model the person downloads to run here, as its "
        + "button and its row on the memory screen call it. It says where the model runs, never where a chat goes, "
        + "so it is true with the cloud on or off."

    /// Each form of `CloudWords.forgotAndCloudOffNotSummaries`.
    public static let cloudSummariesStayed = "CloudWords.forgotAndCloudOffNotSummaries, a Forget everything status line, in "
        + "the form for what went. Its phrases are \"private words\", the name of the person's list in the cloud "
        + "setting, which it says went, and \"cloud\", the name of that setting, which it says is off. The summaries "
        + "clause says what stayed, BackgroundStore's local file, and promises nothing about where a chat goes, so it "
        + "is true with the cloud on or off."

    /// The cloud setting's lines. Each is shown whatever the open chat's
    /// place, and each is true with the cloud on and off.
    public static let cloud: [Allowed] = [
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
                literal: "This stops any task still going, and removes every task, what you told me for it and any words you asked me to hide from this device. It can't be undone. Your notes aren't touched, and your choice about nudges stays as it is. Anything you've allowed until tonight or always stays allowed.",
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

    /// A summary's cloud note says what the cloud did or didn't do for it.
    public static let reconCloudNote = "A note on a summary the cloud was asked for (CloudReconSummarizer), shown only after "
        + "the cloud was chosen for it. \"Cloud\" names that model. \"Without the cloud\" says which helper wasn't "
        + "used, never that words stayed on the device, so it is true with the cloud on or off."

    /// The lines of looking into something that name the cloud.
    public static let recon: [Allowed] = [
        Allowed(file: "PebbleCore/CloudHelp.swift",
                literal: "Nothing went to the cloud. What you wrote is still here.",
                reason: "CloudWords.withdrawn, said when a cloud chat's preview was taken away before any answer, "
                    + "so CloudModel sent nothing (CloudModelError.withdrawn). It is about that one message, which "
                    + "is back in the composer, and promises nothing about where the next one goes."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "You chose not to send it, so I put this together without the cloud.",
                reason: reconCloudNote + " ReconWords.declinedCloud follows a Don't send."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "I couldn't use the answer from the cloud, so I put this together without it.",
                reason: reconCloudNote + " ReconWords.cloudUnreadable: the request may have gone, and it says so."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "I couldn't reach the cloud just now, so I put this together without it.",
                reason: reconCloudNote + " ReconWords.cloudUnavailable never says nothing went."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "Nothing went to the cloud, so I put this together without it.",
                reason: reconCloudNote + " ReconWords.cloudWithdrawn follows a preview taken away with no answer, "
                    + "so CloudModel never sent that request."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "Help from the cloud was off by then, so I put this together without it.",
                reason: cloudSettingName + " ReconWords.cloudOff names the setting, which was off."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "It was stopped after you said send, so some of what I read may already have gone to the cloud. I put this together without it.",
                reason: reconCloudNote + " ReconWords.cloudStopped follows a Stop after a yes, and says plainly "
                    + "that words may have left."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "I stopped, as you asked. You'd already said send, so some of what I read may already have gone to the cloud, and that can't be called back.",
                reason: reconCloudNote + " ReconWords.stoppedAfterSend is a stopped card's step once a yes let a "
                    + "request go (ReconRunner.sentToCloud), and says plainly that words may have left."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "Some of what I read touches on hard things, so I didn't send any of it and put this together without the cloud.",
                reason: reconCloudNote + " ReconWords.keptForCare: CareCheck kept that request from going."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "Put into words in the cloud, from these sources. Open sources to read what each one says.",
                reason: reconCloudNote + " ReconWords.wordedInCloud says words went, the opposite of a device promise."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "Sources for a summary may already have gone to the cloud, and that can't be called back.",
                reason: reconCloudNote + " ReconWords.forgotWhileInCloud says words may have left, never that they stayed."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "I'm already on that one. Today started it with the cloud on, so its summary may be put into words there, only with your yes. Its card is in Today.",
                reason: reconCloudNote + " ReconWords.alreadyOnWithCloud tells a chat that stays here that the "
                    + "summary already going may leave, so the chat's own promise stays true."),
        Allowed(file: "PebbleCore/Recon.swift",
                literal: "(put into words in the cloud, from the sources it was given)",
                reason: reconCloudNote + " ReconWords.wordedInCloudMark, in a kept note, says the words went to the cloud."),
    ]

    /// The words the public source watch's fit score looks for.
    public static let ideaFitKeywords = ["upload", "cloud data storage", "on our servers", "requires cloud", "cloud only"]

    /// Lines the copy lists hold that the guard lets by, each with its
    /// entry in `allowed` for the reason.
    public static let allowedLines: [String] = [
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
        CloudWords.withdrawn,
        ReconWords.declinedCloud,
        ReconWords.cloudUnreadable,
        ReconWords.cloudUnavailable,
        ReconWords.cloudWithdrawn,
        ReconWords.cloudOff,
        ReconWords.cloudStopped,
        ReconWords.stoppedAfterSend,
        ReconWords.keptForCare,
        ReconWords.wordedInCloud,
        ReconWords.forgotWhileInCloud,
        ReconWords.alreadyOnWithCloud,
        ReconWords.wordedInCloudMark,
        OnDeviceModelWords.title,
    ] + OnDeviceModelNotReady.allCases.map(OnDeviceModelWords.notReadyReply)
      + CloudWords.forgotAndCloudOffNotSummariesLines + CloudWords.askPoints.filter { !found(in: $0).isEmpty }

    /// Lines built at run time around an allowed literal, each with the
    /// literal it is built from. What is built around it adds no phrase.
    public static let allowedBuiltLines: [(line: String, literal: String)] = [
        (Redaction.Kind.privateWord.counted(1), "private word"),
        (Redaction.Kind.privateWord.counted(2), "private words"),
        (OnDeviceModelWords.downloadTitle(bytes: 2_274_455_727), "Download on-device model, about "),
    ] + ReconWords.all.filter { $0.contains(ReconWords.wordedInCloudMark) && $0 != ReconWords.wordedInCloudMark }
        .map { ($0, ReconWords.wordedInCloudMark) }
}
