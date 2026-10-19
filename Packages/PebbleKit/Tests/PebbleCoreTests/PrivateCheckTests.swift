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

    /// A scratch repository that ignores the plain list, holding `word` in
    /// it and a hash file made from it.
    final class Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString)")

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try git("init", "-q")
            try write(".gitignore", "Config/private-words.local.txt\n")
            try write("Config/private-words.local.txt", "# made up\n\(PrivateCheckTests.word.capitalized)\n")
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
