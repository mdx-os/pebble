#if os(macOS)
import Foundation
import SourceScan
import Testing

/// `make private-check` finds a planted private word and a planted
/// hostname, says where, and never prints either. Each test works in a
/// scratch repository of its own, with a hash file `make
/// hash-private-words` made there from a plain list, so the owner's real
/// list can change without touching these tests. The planted things are
/// put together at run time, so this file never holds them whole.
struct PrivateCheckTests {
    /// The made up word the committed placeholder list was built from.
    static let word = "zorble" + "frump"

    /// Made up like `word`, with an e acute: one scalar (U+00E9), or e and
    /// a combining acute (U+0301) when `decomposed`.
    static func accented(decomposed: Bool) -> String {
        "zorbl" + (decomposed ? "e\u{301}" : "\u{E9}") + "frump"
    }

    /// A scratch repository that ignores the plain list, holding `listed`
    /// in it and a hash file made from it.
    final class Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString)")

        init(listed: String = PrivateCheckTests.word.capitalized) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try git("init", "-q")
            try write(".gitignore", "Config/private-words.local.txt\n")
            try write("Config/private-words.local.txt", "# made up\n\(listed)\n")
            let made = try run("hash")
            #expect(made.status == 0, "\(made.output)")
            try write("README.md", "Nothing to see here.\n")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Like `write`, but through the POSIX calls, which keep each
        /// name's Unicode spelling. Foundation makes them decomposed.
        func writeKeepingNames(_ path: String, _ text: String) throws {
            var folder = root.path
            for segment in path.split(separator: "/").dropLast() {
                folder += "/" + segment
                guard mkdir(folder, 0o755) == 0 || errno == EEXIST else { throw POSIXError(.EIO) }
            }
            let file = open(root.path + "/" + path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
            guard file >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(file) }
            let bytes = Array(text.utf8)
            guard Darwin.write(file, bytes, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
        }

        func git(_ arguments: String...) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        /// Runs the script in `mode` on this repository.
        func run(_ mode: String = "check") throws -> (status: Int32, output: String) {
            let script = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("scripts/private-check.swift")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", script.path, mode, root.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }


    @Test(arguments: [false, true], [false, true])
    func review2UTF32IsChecked(bigEndian: Bool, host: Bool) throws {
        let scratch = try Scratch()
        let planted = host ? "relay.corp" + ".internal" : Self.word
        let kind = host ? "a .internal or .local host" : "a private word"
        try scratch.write("docs/SETUP.md", "")
        var data = Data(bigEndian ? [0x00, 0x00, 0xfe, 0xff] : [0xff, 0xfe, 0x00, 0x00])
        data.append(try #require("First line.\n\(planted)\n".data(using: bigEndian ? .utf32BigEndian : .utf32LittleEndian)))
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: \(kind)"))
        #expect(!result.output.contains(planted))
    }

    @Test(arguments: [false, true], [false, true])
    func review3UTF32WithoutBOMIsChecked(bigEndian: Bool, host: Bool) throws {
        let scratch = try Scratch()
        let planted = host ? "relay.corp" + ".internal" : Self.word
        let kind = host ? "a .internal or .local host" : "a private word"
        let data = try #require("First line.\n\(planted)\n".data(using: bigEndian ? .utf32BigEndian : .utf32LittleEndian))
        #expect(!data.starts(with: [0xff, 0xfe]) && !data.starts(with: [0x00, 0x00, 0xfe, 0xff]))
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: \(kind)"), "\(result.output)")
        #expect(!result.output.contains(planted))
    }

    /// A UTF-16 BOM followed by UTF-8 text decodes as nonsense, not as an
    /// error, so the lossy UTF-8 is scanned beside it.
    @Test func review3UTF8AfterABOMIsChecked() throws {
        let scratch = try Scratch()
        var data = Data([0xff, 0xfe])
        data.append(Data("First line.\n\(Self.word)\n".utf8))
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"), "\(result.output)")
        #expect(!result.output.lowercased().contains(Self.word))
    }

    /// Text after a BOM that ends in a unit that isn't a scalar (an unpaired
    /// surrogate in UTF-16, past U+10FFFF in UTF-32) is still scanned.
    @Test(arguments: [2, 4], [false, true])
    func review3BrokenBOMTextIsChecked(width: Int, bigEndian: Bool) throws {
        let scratch = try Scratch()
        let encodings: [String.Encoding] = width == 2 ? [.utf16LittleEndian, .utf16BigEndian] : [.utf32LittleEndian, .utf32BigEndian]
        let bom: [UInt8] = width == 2 ? [0xfe, 0xff] : [0x00, 0x00, 0xfe, 0xff]
        let bad: [UInt8] = width == 2 ? [0xd8, 0x00] : [0x00, 0x11, 0x00, 0x00]
        var data = Data(bigEndian ? bom : bom.reversed())
        data.append(try #require("First line.\n\(Self.word)\n".data(using: encodings[bigEndian ? 1 : 0])))
        data.append(contentsOf: bigEndian ? bad : bad.reversed())
        #expect(String(data: data.dropFirst(width), encoding: encodings[bigEndian ? 1 : 0]) == nil)
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"), "\(result.output)")
        #expect(!result.output.lowercased().contains(Self.word))
    }

    /// FF FE 00 00 starts UTF-32 LE text, or UTF-16 LE text whose first
    /// character is NUL, so both readings are scanned.
    @Test(arguments: [false, true])
    func review4BOMFittingTwoReadingsIsChecked(host: Bool) throws {
        let scratch = try Scratch()
        let planted = host ? "relay.corp" + ".internal" : Self.word
        let kind = host ? "a .internal or .local host" : "a private word"
        var data = Data([0xff, 0xfe])
        data.append(try #require("\0First line.\n\(planted)\n".data(using: .utf16LittleEndian)))
        #expect(data.starts(with: [0xff, 0xfe, 0x00, 0x00]))
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: \(kind)"), "\(result.output)")
        // A failed expectation prints its values, so only a bool is checked.
        let named = result.output.lowercased().contains(planted)
        #expect(!named, "the output names what was planted")
    }

    /// UTF-16 BE text without a BOM that starts with NUL and U+FEFF begins
    /// 00 00 FE FF, the UTF-32 BE BOM. A BOM that fits never stops the other
    /// readings, so the UTF-16 BE one is scanned too.
    @Test func review5BOMNeverStopsTheOtherReadings() throws {
        let scratch = try Scratch()
        let host = "relay.corp" + ".internal"
        let data = try #require("\0\u{FEFF}First line.\n\(Self.word)\n\(host)\n".data(using: .utf16BigEndian))
        #expect(data.starts(with: [0x00, 0x00, 0xfe, 0xff]))
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: a private word"), "\(result.output)")
        #expect(result.output.contains("docs/SETUP.md:3: a .internal or .local host"), "\(result.output)")
        // A failed expectation prints its values, so only a bool is checked.
        let named = result.output.lowercased().contains(Self.word) || result.output.contains(host)
        #expect(!named, "the output names what was planted")
    }

    /// Without a BOM, UTF-16 and UTF-32 in either byte order are read
    /// lossily too: a unit that isn't a scalar, or a stray byte at the end,
    /// keeps every whole unit before it.
    @Test(arguments: [2, 4], [(false, false), (false, true), (true, false), (true, true)])
    func review4BrokenTextWithoutBOMIsChecked(width: Int, ending: (bigEndian: Bool, strayByte: Bool)) throws {
        let (bigEndian, strayByte) = ending
        let scratch = try Scratch()
        let host = "relay.corp" + ".internal"
        let encoding: String.Encoding = width == 2
            ? (bigEndian ? .utf16BigEndian : .utf16LittleEndian)
            : (bigEndian ? .utf32BigEndian : .utf32LittleEndian)
        let bad: [UInt8] = width == 2 ? [0xd8, 0x00] : [0x00, 0x11, 0x00, 0x00]
        var data = try #require("First line.\n\(Self.word)\n\(host)\n".data(using: encoding))
        #expect(![[0xff, 0xfe], [0xfe, 0xff], [0x00, 0x00, 0xfe, 0xff]].contains { data.starts(with: $0) })
        data.append(contentsOf: strayByte ? [0x20] : bigEndian ? bad : bad.reversed())
        if strayByte {
            #expect(!data.count.isMultiple(of: width))
        } else {
            #expect(String(data: data, encoding: encoding) == nil)
        }
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: a private word"), "\(result.output)")
        #expect(result.output.contains("docs/SETUP.md:3: a .internal or .local host"), "\(result.output)")
        // A failed expectation prints its values, so only a bool is checked.
        let named = result.output.lowercased().contains(Self.word) || result.output.contains(host)
        #expect(!named, "the output names what was planted")
    }

    @Test(arguments: [false, true])
    func review2SymlinkTargetsAreChecked(host: Bool) throws {
        let scratch = try Scratch()
        let planted = host ? "relay.corp" + ".internal" : Self.word
        let kind = host ? "a .internal or .local host" : "a private word"
        let path = "docs/\(planted)/link"
        try scratch.write("docs/\(planted)/README.md", "Safe.")
        // A dangling target is still committed text. Sensitive link paths are redacted too.
        try FileManager.default.createSymbolicLink(atPath: scratch.root.appendingPathComponent(path).path,
                                                   withDestinationPath: "../\(planted)/missing")
        #expect(try scratch.git("add", path) == 0)
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/[redacted]/link:1: \(kind)"))
        #expect(!result.output.contains(planted))
    }

    @Test func review2SymlinkDestinationIsNotRead() throws {
        let scratch = try Scratch()
        try scratch.write(".gitignore", "Config/private-words.local.txt\nignored.txt\n")
        try scratch.write("ignored.txt", Self.word)
        try FileManager.default.createSymbolicLink(atPath: scratch.root.appendingPathComponent("link.txt").path,
                                                   withDestinationPath: "ignored.txt")
        #expect(try scratch.git("add", "link.txt") == 0)
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }

    @Test(arguments: ["2001:db8:" + ":", ":" + ":1", "2001:db8:" + ":1"])
    func review2CompressedIPv6IsChecked(address: String) throws {
        let scratch = try Scratch()
        try scratch.write("docs/SETUP.md", "First line.\nAddress: \(address)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: an IPv6 address"))
        #expect(!result.output.contains(address))
    }

    @Test(arguments: [false, true])
    func review2LossyUTF8IsChecked(even: Bool) throws {
        let scratch = try Scratch()
        var data = Data("First line.\n".utf8)
        data.append(0xe9)
        data.append(Data(" \(Self.word)\n".utf8))
        if data.count.isMultiple(of: 2) != even { data.append(0x20) }
        #expect(data.count.isMultiple(of: 2) == even)
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"))
        #expect(!result.output.contains(Self.word))
    }

    @Test(arguments: [false, true], [false, true])
    func reviewUTF16PrivateWordsAreChecked(bigEndian: Bool, bom: Bool) throws {
        let scratch = try Scratch()
        let encoding: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        var data = bom ? Data(bigEndian ? [0xfe, 0xff] : [0xff, 0xfe]) : Data()
        data.append(try #require("First line.\nAsk \(Self.word).\n".data(using: encoding)))
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"))
        #expect(!result.output.lowercased().contains(Self.word))
    }

    @Test(arguments: [false, true], [false, true])
    func reviewUTF16HostsAreChecked(bigEndian: Bool, bom: Bool) throws {
        let scratch = try Scratch()
        try scratch.write("docs/SETUP.md", "")
        let host = "relay.corp" + ".internal"
        let encoding: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        var data = bom ? Data(bigEndian ? [0xfe, 0xff] : [0xff, 0xfe]) : Data()
        data.append(try #require("First line.\n\(host)\n".data(using: encoding)))
        try data.write(to: scratch.root.appendingPathComponent("docs/SETUP.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:2: a .internal or .local host"))
        #expect(!result.output.contains(host))
    }


    @Test func reviewUTF8NULDoesNotHideWords() throws {
        let scratch = try Scratch()
        try scratch.write("README.md", "\0\n\(Self.word)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"))
        #expect(!result.output.lowercased().contains(Self.word))
    }


    @Test(arguments: [false, true])
    func reviewUTF16NULDoesNotHideWords(bigEndian: Bool) throws {
        let scratch = try Scratch()
        let encoding: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        let data = try #require("First line.\0\n\(Self.word)\n".data(using: encoding))
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("README.md:2: a private word"))
        #expect(!result.output.lowercased().contains(Self.word))
    }

    @Test func reviewBinaryFilesAreSkipped() throws {
        let scratch = try Scratch()
        try Data([0xff, 0x00, 0x80]).write(to: scratch.root.appendingPathComponent("image.bin"))
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }


    @Test func reviewFixedDiagnosticPathsAreRedacted() throws {
        let scratch = try Scratch()
        // Even a fixed configuration path must be redacted if a segment is listed.
        try scratch.write("Config/private-words.local.txt", "Config\n")
        let made = try scratch.run("hash")
        #expect(made.status == 0)
        #expect(!made.output.contains("Config"))
        #expect(made.output.contains("[redacted]/private-words.sha256"))
        #expect(try scratch.git("add", "-f", "Config/private-words.local.txt") == 0)
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(!result.output.contains("Config"))
        #expect(result.output.contains("[redacted]/private-words.local.txt is tracked"))
    }

    @Test func reviewSensitivePathsAreRedacted() throws {
        let scratch = try Scratch()
        let host = "relay.corp" + ".internal"
        try scratch.write("docs/\(Self.word)/\(host)/Open\(Self.word.capitalized)Relay.md",
                          "\(Self.word)\n\(host)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/[redacted]/[redacted]/[redacted]:1: a private word"))
        #expect(result.output.contains("docs/[redacted]/[redacted]/[redacted]:2: a .internal or .local host"))
        #expect(!result.output.lowercased().contains(Self.word))
        #expect(!result.output.contains(host))
    }

    @Test func aCleanRepositoryPassesAndThePlainListIsNeverRead() throws {
        let scratch = try Scratch()
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
        let hashes = try String(contentsOf: scratch.root.appendingPathComponent("Config/private-words.sha256"), encoding: .utf8)
        #expect(!hashes.lowercased().contains(Self.word))
    }

    @Test func aPlantedWordFailsWithItsPlaceButNotTheWord() throws {
        let scratch = try Scratch()
        try scratch.write("notes/plan.md", "First line.\nSecond line.\nAsk \(Self.word.uppercased()) about it.\n")
        try scratch.write("Sources/Relay.swift", "struct Open\(Self.word.capitalized)Relay {}\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("notes/plan.md:3: a private word"), "\(result.output)")
        #expect(result.output.contains("Sources/Relay.swift:1: a private word"), "\(result.output)")
        #expect(!result.output.lowercased().contains(Self.word))
    }

    /// A word written in capitals inside a camel case name ends where the
    /// next part starts, before the last capital of the run: the R of
    /// OpenFOORelay.
    @Test(arguments: ["Open%Relay", "%Relay", "open%Relay", "Open2%Relay"])
    func review6CapitalizedWordInACamelCaseNameIsFound(name: String) throws {
        let scratch = try Scratch()
        let planted = name.replacingOccurrences(of: "%", with: Self.word.uppercased())
        try scratch.write("Sources/Relay.swift", "First line.\nstruct \(planted) {}\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Sources/Relay.swift:2: a private word"), "\(result.output)")
        // A failed expectation prints its values, so only a bool is checked.
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// The split never makes a word out of part of one: a capitalized run
    /// that only starts with the word is still another word.
    @Test func review6CapitalizedRunsAreStillWholeWords() throws {
        let scratch = try Scratch()
        try scratch.write("Sources/Relay.swift", "struct Open\(Self.word.uppercased())SRelay {}\n")
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func review6CapitalizedWordInAPathIsRedacted() throws {
        let scratch = try Scratch()
        try scratch.write("docs/Open\(Self.word.uppercased())Relay/notes.md", "First line.\n\(Self.word)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/[redacted]/notes.md:2: a private word"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// Two readings of a file can decode the same line, here UTF-16 LE after
    /// its BOM and the whole file with the BOM as U+FEFF. It is one problem.
    @Test func review6ALineFoundInTwoReadingsIsReportedOnce() throws {
        let scratch = try Scratch()
        var data = Data([0xff, 0xfe])
        data.append(try #require("\(Self.word)\n".data(using: .utf16LittleEndian)))
        try data.write(to: scratch.root.appendingPathComponent("README.md"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.components(separatedBy: "README.md:1: a private word").count == 2, "\(result.output)")
        #expect(result.output.contains("1 found."), "\(result.output)")
    }

    /// Whether the output holds the accented word in either spelling. Only
    /// a bool is checked, since a failed expectation prints its values.
    static func namesAccented(_ output: String) -> Bool {
        let text = Data(output.lowercased().precomposedStringWithCanonicalMapping.utf8)
        return text.range(of: Data(accented(decomposed: false).utf8)) != nil
    }

    /// A listed word and the same word written in the other Unicode
    /// spelling are one word: precomposed in the list and decomposed in the
    /// file, and the other way round.
    @Test(arguments: [false, true])
    func review7EitherSpellingOfAWordIsFound(listDecomposed: Bool) throws {
        let listed = Self.accented(decomposed: listDecomposed)
        let written = Self.accented(decomposed: !listDecomposed)
        #expect(Array(listed.utf8) != Array(written.utf8))
        let scratch = try Scratch(listed: listed.capitalized)
        try scratch.write("notes/plan.md", "First line.\nAsk \(written) about it.\nstruct Open\(written.capitalized)Relay {}\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("notes/plan.md:2: a private word"), "\(result.output)")
        #expect(result.output.contains("notes/plan.md:3: a private word"), "\(result.output)")
        let named = Self.namesAccented(result.output)
        #expect(!named, "the output names what was planted")
    }

    /// A path segment in the other Unicode spelling of a listed word is
    /// redacted too. Git on a Mac makes file names precomposed unless told
    /// not to, so the scratch repository keeps them as written.
    @Test(arguments: [false, true])
    func review7EitherSpellingOfAWordInAPathIsRedacted(listDecomposed: Bool) throws {
        let listed = Self.accented(decomposed: listDecomposed)
        let written = Self.accented(decomposed: !listDecomposed)
        let scratch = try Scratch(listed: listed.capitalized)
        #expect(try scratch.git("config", "core.precomposeunicode", "false") == 0)
        let host = "relay.corp" + ".internal"
        try scratch.writeKeepingNames("docs/\(written)/Open\(written.capitalized)Relay.md", "First line.\n\(host)\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path + "/docs")
        #expect(names.map { Array($0.utf8) } == [Array(written.utf8)], "the folder name kept its spelling")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/[redacted]/[redacted]:2: a .internal or .local host"), "\(result.output)")
        let named = Self.namesAccented(result.output)
        #expect(!named, "the output names what was planted")
    }

    /// The split at the end of a capital run only adds parts: the part the
    /// split before it made is still read, so a listed word written as an
    /// acronym joined to a word after a prefix is found.
    @Test func review7CapitalRunSplitOnlyAddsParts() throws {
        let scratch = try Scratch()
        let name = "use" + Self.word.prefix(6).uppercased() + Self.word.dropFirst(6).capitalized
        try scratch.write("Sources/Relay.swift", "First line.\nlet \(name) = true\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Sources/Relay.swift:2: a private word"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// A capital run with one small s after it is a plural: FOOs, OpenFOOs
    /// and FOOsRelay all hold FOO.
    @Test(arguments: ["%s", "Open%s", "%sRelay"])
    func review7PluralOfACapitalRunIsFound(name: String) throws {
        let scratch = try Scratch()
        let planted = name.replacingOccurrences(of: "%", with: Self.word.uppercased())
        try scratch.write("Sources/Relay.swift", "First line.\nlet \(planted) = 2\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Sources/Relay.swift:2: a private word"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// The listed word written as two camel case parts, each capitalized,
    /// in place of the % in `name`.
    static func inParts(_ name: String) -> String {
        name.replacingOccurrences(of: "%", with: word.prefix(6).capitalized + word.dropFirst(6).capitalized)
    }

    /// Parts next to each other in one name are joined, so a listed word
    /// written in parts is found.
    @Test(arguments: ["Open%Relay", "%", "open%", "make%RelayAgainNow"])
    func review8AWordInPartsIsFound(name: String) throws {
        let scratch = try Scratch()
        try scratch.write("Sources/Relay.swift", "First line.\nstruct \(Self.inParts(name)) {}\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Sources/Relay.swift:2: a private word"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    @Test(arguments: ["Open%Relay", "%"])
    func review8AWordInPartsInAPathIsRedacted(name: String) throws {
        let scratch = try Scratch()
        try scratch.write("docs/\(Self.inParts(name))/notes.md", "First line.\n\(Self.word)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/[redacted]/notes.md:2: a private word"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// Parts of different names never join: zorble_frump is two names, as
    /// it was before parts were joined, in a file and in a path.
    @Test func review8PartsOfDifferentNamesNeverJoin() throws {
        let scratch = try Scratch()
        let apart = Self.word.prefix(6) + "_" + Self.word.dropFirst(6)
        let host = "relay.corp" + ".internal"
        try scratch.write("Sources/Relay.swift", "let \(apart) = 1\nlet a = \(Self.word.prefix(6)) \(Self.word.dropFirst(6))\n")
        try scratch.write("docs/\(apart)/notes.md", "First line.\n\(host)\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(!result.output.contains("Sources/Relay.swift"), "\(result.output)")
        #expect(result.output.contains("docs/\(apart)/notes.md:2: a .internal or .local host"), "\(result.output)")
        #expect(result.output.contains("1 found."), "\(result.output)")
    }

    /// A listed word in a path is a problem on its own, whatever the file
    /// holds, since git publishes the name: a file named with the word,
    /// empty or clean, a folder named with it, and the word in camel case
    /// parts inside a file name. The path is printed redacted.
    @Test(arguments: [
        ("docs/%.md", "", "docs/[redacted]"),
        ("docs/%.md", "Nothing to see here.\n", "docs/[redacted]"),
        ("docs/%/notes.md", "Nothing to see here.\n", "docs/[redacted]/notes.md"),
        ("Sources/Open#Relay.swift", "struct Plain {}\n", "Sources/[redacted]"),
        ("Sources/#.swift", "", "Sources/[redacted]"),
    ])
    func review9AWordInAPathFailsWhateverTheFileHolds(name: String, contents: String, shown: String) throws {
        let scratch = try Scratch()
        let path = name.replacingOccurrences(of: "%", with: Self.word)
            .replacingOccurrences(of: "#", with: Self.inParts("%"))
        try scratch.write(path, contents)
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("private-check: \(shown): a private word in its path"), "\(result.output)")
        #expect(result.output.contains("1 found."), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// A file a listed word names is a problem even when its contents are
    /// never read: binary, or a link that goes nowhere.
    @Test(arguments: [false, true])
    func review9AWordInAPathFailsWhenTheFileIsNotRead(link: Bool) throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("docs/\(Self.word).bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if link {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "missing")
        } else {
            try Data([0xff, 0x00, 0x80]).write(to: url)
        }
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("private-check: docs/[redacted]: a private word in its path"), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word)
        #expect(!named, "the output names what was planted")
    }

    /// A name in the other Unicode spelling of a listed word is found too,
    /// in a folder and in a file name. Git on a Mac makes file names
    /// precomposed unless told not to, so the scratch repository keeps them
    /// as written.
    @Test(arguments: [false, true])
    func review9EitherSpellingOfAWordInAPathFails(listDecomposed: Bool) throws {
        let listed = Self.accented(decomposed: listDecomposed)
        let written = Self.accented(decomposed: !listDecomposed)
        let scratch = try Scratch(listed: listed.capitalized)
        #expect(try scratch.git("config", "core.precomposeunicode", "false") == 0)
        try scratch.writeKeepingNames("docs/\(written)/notes.md", "")
        try scratch.writeKeepingNames("notes/Open\(written.capitalized)Relay.md", "")
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path + "/docs")
        #expect(names.map { Array($0.utf8) } == [Array(written.utf8)], "the folder name kept its spelling")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("private-check: docs/[redacted]/notes.md: a private word in its path"), "\(result.output)")
        #expect(result.output.contains("private-check: notes/[redacted]: a private word in its path"), "\(result.output)")
        #expect(result.output.contains("2 found."), "\(result.output)")
        let named = Self.namesAccented(result.output)
        #expect(!named, "the output names what was planted")
    }

    /// Ordinary names pass: a name that only starts or ends with the word,
    /// or holds its parts apart, is another name, and so are everyday ones.
    @Test func review9OrdinaryPathsPass() throws {
        let scratch = try Scratch()
        let apart = Self.word.prefix(6) + "_" + Self.word.dropFirst(6)
        try scratch.write("docs/\(apart)/notes.md", "")
        try scratch.write("docs/\(Self.word)s2.md", "Nothing to see here.\n")
        try scratch.write("Sources/Open\(Self.word.uppercased())SRelay.swift", "")
        try scratch.write("Sources/PebbleCore/RelayTests.swift", "struct RelayTests {}\n")
        try scratch.write("Config/Brand.xcconfig", "")
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }

    /// A listed word right after a whitespace escape in a string, as JSON
    /// and Swift write a new line or a tab, is found: the escape is a break,
    /// never the first letter of the word. So is one written with a doubled
    /// backslash, as source holds an escape it passes on, and one in
    /// capitals.
    @Test(arguments: [
        ("docs/example.json", "{\"note\":\"%\"}\n"),
        ("Sources/Note.swift", "let note = \"%\"\n"),
    ], [#"\n"#, #"\t"#, #"\r"#, #"\\n"#, #"\\t"#])
    func review10AWordAfterAWhitespaceEscapeIsFound(file: (path: String, text: String), escape: String) throws {
        for word in [Self.word, Self.word.capitalized] {
            let scratch = try Scratch()
            try scratch.write(file.path, "First line.\n" + file.text.replacingOccurrences(of: "%", with: "Hello" + escape + word))
            let result = try scratch.run()
            #expect(result.status != 0, "\(file.path) \(escape)")
            #expect(result.output.contains("\(file.path):2: a private word"), "\(result.output)")
            let named = result.output.lowercased().contains(Self.word)
            #expect(!named, "the output names what was planted")
        }
    }

    /// The escape reading only adds words. A listed word that starts with
    /// the letter of an escape, written after a backslash as in a Windows
    /// path, is still found as written, and a host right after an escape
    /// is found too.
    @Test func review10TheTextAsWrittenIsStillRead() throws {
        let listed = "t" + Self.word
        let scratch = try Scratch(listed: listed.capitalized)
        let host = "10.20" + ".30.40"
        try scratch.write("docs/paths.md", "First line.\nKept in C:\\Users\\\(listed)\\notes.\n")
        try scratch.write("docs/hosts.json", "{\"relay\":\"\\n\(host)\"}\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/paths.md:2: a private word"), "\(result.output)")
        #expect(result.output.contains("docs/hosts.json:1: an IPv4 address"), "\(result.output)")
        #expect(result.output.contains("2 found."), "\(result.output)")
        let named = result.output.lowercased().contains(Self.word) || result.output.contains(host)
        #expect(!named, "the output names what was planted")
    }

    /// Ordinary escapes pass: a word the escape's letter starts is not
    /// listed once the letter is a break, so everyday code stays clean.
    @Test func review10OrdinaryEscapesPass() throws {
        let scratch = try Scratch()
        try scratch.write("Sources/Note.swift", "let a = \"one\\ntwo\\tthree\\r\\nfour\"\nlet b = \"\\\\name\"\n")
        try scratch.write("docs/example.json", "{\"note\":\"line\\nnext\"}\n")
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }

    @Test(arguments: [
        ("relay.example" + ".herokuapp.com", "a hosting provider's hostname"),
        ("https://run-" + "abc.fly" + ".dev/v1", "a hosting provider's hostname"),
        ("relay.corp" + ".internal", "a .internal or .local host"),
        ("relay-box" + ".local:8080", "a .internal or .local host"),
        ("10.20" + ".30.40", "an IPv4 address"),
        ("[fd00:" + ":1]:443", "an IPv6 address"),
    ])
    func aPlantedHostFailsWithItsPlaceButNotTheHost(host: String, kind: String) throws {
        let scratch = try Scratch()
        try scratch.write("docs/SETUP.md", "# Setup\n\nThe relay lives at \(host) for now.\n")
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("docs/SETUP.md:3: \(kind)"), "\(result.output)")
        #expect(!result.output.contains(host))
    }

    /// Hosts are looked for in docs/, Config/ and Packages/ only, and a
    /// file name with .local in the middle is not a host.
    @Test func hostsAreLookedForWhereTheyCouldShip() throws {
        let scratch = try Scratch()
        try scratch.write("scripts/notes.txt", "relay.example" + ".herokuapp.com\n")
        try scratch.write("Config/README.md", "Put it in Config/Cloud.local.xcconfig, version 1.2.3.\n")
        let result = try scratch.run()
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func aTrackedPlainListFails() throws {
        let scratch = try Scratch()
        #expect(try scratch.git("add", "-f", "Config/private-words.local.txt") == 0)
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Config/private-words.local.txt is tracked by git"), "\(result.output)")
    }

    @Test func aMissingHashFileFails() throws {
        let scratch = try Scratch()
        try FileManager.default.removeItem(at: scratch.root.appendingPathComponent("Config/private-words.sha256"))
        let result = try scratch.run()
        #expect(result.status != 0)
        #expect(result.output.contains("private-words.sha256 is missing"), "\(result.output)")
    }

    /// The committed hash file is one the check reads: a salt line, then
    /// hashes only.
    @Test func theCommittedHashFileIsWellFormed() throws {
        let text = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("Config/private-words.sha256"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let hex = { (line: Substring) in line.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
        #expect(lines.first.map { $0.hasPrefix("salt ") && $0.count >= 37 && hex($0.dropFirst(5)) } == true)
        #expect(lines.count >= 2)
        #expect(lines.dropFirst().allSatisfy { $0.count == 64 && hex($0) })
    }
}
#endif
