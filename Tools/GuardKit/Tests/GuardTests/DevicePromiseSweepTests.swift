import Foundation
import GuardScan
import PebbleCore
import PromiseWords
import SourceScan
import Testing

extension DevicePromise {
    /// True when the chain written `text` in `file` is an allowed line,
    /// word for word, and in the list its entry names, if it names one.
    static func isAllowed(_ text: String, in file: String, first: SyntaxSource.Literal, source: SyntaxSource) -> Bool {
        allowed.contains { entry in
            entry.file == file && entry.literal == text
                && entry.inList.map { PromiseRules.listName(holding: first) == $0 } ?? true
        }
    }

    /// Every promise rule on one file, the words and the place alike: what
    /// the sweeps below record, and what the wrong-case suite asks of.
    static func findings(in source: SyntaxSource, file: String) -> [Finding] {
        PromiseRules.findings(in: source, file: file) { isAllowed($0, in: $1, first: $2, source: $3) }
    }
}

/// PERMANENT GUARD. No word a person sees promises the device or privacy
/// unless `PrivacyPlace` decides it, or it is allowed in `DevicePromise`
/// with a written reason: every string literal in the package sources and
/// the app. PebbleKit's `DevicePromiseTests` sweeps the copy lists, and
/// what each rule must catch is in `GuardWrongCaseTests`.
struct DevicePromiseSweepTests {
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

    /// Every rule at once over every file: what the wrong-case suite runs,
    /// on the real sources. Each rule above is swept on its own too, so a
    /// failure there says which.
    @Test func everyPromiseRuleHoldsOverTheSources() throws {
        for file in try Self.sources() {
            for problem in DevicePromise.findings(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
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
}
