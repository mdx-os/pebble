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
