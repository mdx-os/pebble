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
        "stays here", "stays on", "stay on", "kept only", "never leaves", "never leave",
        "doesn't leave", "won't leave", "only on", "private", "privately",
        "nothing was sent", "nothing is sent anywhere", "locally",
    ]

    /// The phrases in `line`, if any.
    static func found(in line: String) -> [String] {
        phrases.filter { phrase in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A line the guard lets by without the flag, and why. Each one is a
    /// promise that is true whatever the model is.
    struct Allowed {
        /// The source file, from `Packages/PebbleKit/Sources` or `App`.
        let file: String
        /// Words the literal contains, enough to find it.
        let quoting: String
        let reason: String
    }

    static let allowed: [Allowed] = [
        Allowed(file: "PebbleCore/Memory.swift", quoting: "This removes every note and every task from this device",
                reason: "MemoryWords.forgetEverythingDetail is about where the notes and tasks are, not where the chat goes. "
                    + "Notes live only in MemoryStore's local file and tasks only in the engine in this process, "
                    + "whatever the model is, so it is true with a cloud model too."),
        Allowed(file: "PebbleCore/Tasks.swift", quoting: "removes every task and what you told me for it from this device",
                reason: "TaskWords.forgetTasksDetail names where the tasks are erased from, not that nothing left. "
                    + "\"From this device\" is the honest limit: without it, a cloud model's copy would seem erased too."),
        Allowed(file: "PebbleModel/LocalStubModel.swift", quoting: "a small helper that runs only on this device",
                reason: "LocalStubModel.fallback is only ever said by the on-device stub, which always runs here."),
        Allowed(file: "PebbleModel/LocalStubModel.swift", quoting: "I'll keep it on this device",
                reason: "The stub's remember result. Only the on-device stub says it, and notes stay in the local file."),
        Allowed(file: "PebbleModel/LocalStubModel.swift", quoting: "It stays on this device.",
                reason: "The stub's remember opener. Only the on-device stub says it."),
        Allowed(file: "PebbleCore/Feed.swift", quoting: "These are examples for now. Nothing was sent or bought.",
                reason: "FeedWords.sampleNote off the device. \"Nothing was sent\" is about the example cards' actions, "
                    + "which never ran, not about where words go, so it is true with any model."),
    ]

    /// Lines the copy lists hold that the guard lets by, each with its
    /// entry in `allowed` for the reason.
    static let allowedLines: [String] = [
        MemoryWords.forgetEverythingDetail,
        TaskWords.forgetTasksDetail,
        FeedWords.sampleNote(.mayLeaveDevice),
    ]

    /// A literal is gated when it is the true branch of a ternary on the
    /// flag: `place.staysOnDevice ? "..."` or `onDevice ? "..."`, on one
    /// line or across two. The false branch comes after `:` and is never
    /// gated.
    static func isGated(_ literal: SwiftSource.Literal, in source: SwiftSource) -> Bool {
        let before = source.code(before: literal.offset, lines: 2)
        return before.range(of: #"\b(staysOnDevice|onDevice)\s*\?\s*$"#, options: .regularExpression) != nil
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
    static func ungated(in files: [(name: String, text: String)]) -> [String] {
        var problems: [String] = []
        for file in files {
            let source = SwiftSource(file.text)
            for literal in source.literals where !DevicePromise.found(in: literal.text).isEmpty {
                if DevicePromise.isGated(literal, in: source) { continue }
                if DevicePromise.allowed.contains(where: { $0.file == file.name && literal.text.contains($0.quoting) }) {
                    continue
                }
                problems.append("\(file.name):\(literal.line): \"\(literal.text)\" promises "
                                + "\(DevicePromise.found(in: literal.text)) without PrivacyPlace")
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
            #expect(literals.contains { $0.text.contains(entry.quoting) }, "no longer in \(entry.file): \(entry.quoting)")
        }
        for line in DevicePromise.allowedLines {
            #expect(DevicePromise.allowed.contains { line.contains($0.quoting) }, "no reason given for: \(line)")
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
        ]
        for text in wrong {
            #expect(!Self.ungated(in: [("PebbleCore/Wrong.swift", text)]).isEmpty, "missed: \(text)")
        }
        let right = [
            #"place.staysOnDevice ? "Saved. It stays on this device." : "Saved.""#,
            "onDevice\n    ? \"I run on this device.\"\n    : \"Hi.\"",
            #"// Says "on this device" only when the flag says so."#,
            "/* \"stays on this device\" */",
            #"static let x = "Only one note at a time.""#,
        ]
        for text in right {
            #expect(Self.ungated(in: [("PebbleCore/Right.swift", text)]).isEmpty, "flagged: \(text)")
        }
        #expect(DevicePromise.found(in: "only one").isEmpty)
        #expect(!DevicePromise.found(in: "Kept ONLY on this device").isEmpty)
    }
}
