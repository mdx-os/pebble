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
    ] + ideaFitKeywords.map { keyword in
        Allowed(file: "PebbleCore/IdeaDraft.swift", literal: keyword,
                reason: "A keyword IdeaDraft.fit looks for in a competitor's own words, to score how private that "
                    + "product is. Matched with `contains`, never shown to anyone, and promises nothing about this app.")
    }

    /// The words the competitor watch's fit score looks for.
    static let ideaFitKeywords = ["upload", "cloud data storage", "on our servers", "requires cloud", "cloud only"]

    /// True when `text` in `file` is an allowed line, word for word.
    static func isAllowed(_ text: String, in file: String) -> Bool {
        allowed.contains { $0.file == file && $0.literal == text }
    }

    /// The literals in `source`, with those written one after another with
    /// only `+` between them (`"never " + "leaves"`) kept together, in order.
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
    ///   from the model. A parameter may default to `.mayLeaveDevice`.
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
    }

    /// Every line the copy lists hold: the gated lines on the device, the
    /// allowed ones, and nothing else, may promise the device.
    @Test func everyCopyListLineIsGatedOrAllowed() {
        let gated = Set(PrivacyPlaceTests.deviceLines(.onDevice))
        let lines = CopyDashTests.copy + FeedWords.all + PrivacyPlaceTests.deviceLines(.onDevice)
            + PrivacyPlaceTests.deviceLines(.mayLeaveDevice) + Self.sampleFeedWords
        #expect(lines.count > 100)
        for line in lines where !DevicePromise.found(in: line).isEmpty {
            #expect(gated.contains(line) || DevicePromise.allowedLines.contains(line),
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

    /// None yet. Each would be a promise true whatever the model is.
    static let allowedResources: [AllowedResource] = []

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
