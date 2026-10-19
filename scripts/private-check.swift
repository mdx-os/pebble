// The private words check, and the maker of its hash file.
// Usage: swift scripts/private-check.swift check [repo]
//        swift scripts/private-check.swift hash [repo]
//
// check: fails on any file in git (tracked, or new and not ignored) with a
// word whose salted hash is in Config/private-words.sha256. It prints the
// file and line, never the word. In docs/, Config/ and Packages/ it also
// fails on a hosting provider's hostname, a .internal or .local host and
// an IP address, printing what kind of thing it found, never the thing.
// It fails too if the plain list, Config/private-words.local.txt, is
// tracked by git.
//
// hash: makes Config/private-words.sha256 from the plain list, which git
// ignores and only the owner's machines have. It keeps the salt already in
// the file, so the same list makes the same file.
//
// A word is a run of letters and digits, compared in lowercase. A word
// written in camel case is also read in its parts, so a listed word inside
// a name such as fooBarRelay is found. Each line of the hash file after the
// salt is the lowercase hex SHA-256 of "<salt>:<word>".
import CryptoKit
import Foundation

let hashFile = "Config/private-words.sha256"
let plainList = "Config/private-words.local.txt"
let hostFolders = ["docs/", "Config/", "Packages/"]

/// Hostname endings of hosting providers: a server under one is somebody's
/// real address. Any number of labels before them counts, none included.
let providers = [
    "amazonaws.com", "cloudfront.net", "elasticbeanstalk.com", "awsapprunner.com", "on.aws",
    "azurewebsites.net", "azurecontainerapps.io", "azureedge.net", "azurefd.net", "cloudapp.net",
    "cloudapp.azure.com", "appspot.com", "run.app", "cloudfunctions.net", "firebaseapp.com", "web.app",
    "herokuapp.com", "herokudns.com", "vercel.app", "now.sh", "netlify.app", "fly.dev", "onrender.com",
    "railway.app", "workers.dev", "pages.dev", "trycloudflare.com", "ngrok.io", "ngrok.app",
    "ngrok-free.app", "ondigitalocean.app", "digitaloceanspaces.com", "linodeobjects.com", "supabase.co",
    "deno.dev", "glitch.me", "repl.co", "replit.app", "modal.run", "github.io", "gitlab.io",
    "pythonanywhere.com", "scw.cloud", "your-server.de", "vultrobjects.com", "oraclecloud.com",
]

func pattern(_ text: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
}

let hostRules: [(String, NSRegularExpression)] = [
    ("a hosting provider's hostname", pattern(
        #"(?<![\w.-])(?:[a-z0-9-]+\.)*(?:"#
            + providers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + #")(?![\w-]|\.[a-z0-9])"#)),
    ("a .internal or .local host", pattern(
        #"(?<![\w.-])(?:[a-z0-9-]+\.)+(?:internal|local)(?![\w-]|\.[a-z0-9])"#)),
    ("an IPv4 address", pattern(
        #"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w]|\.[0-9])"#)),
    ("an IPv6 address", pattern(
        #"\[(?=[0-9a-f:.]*[0-9a-f])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f.]*\]"#
            + #"|(?<![\w:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![\w:])"#
            + #"|(?<![\w:])(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?(?![\w:])(?<=[0-9a-f]|[0-9a-f]::)"#)),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("private-check: \(message)\n".utf8))
    exit(1)
}

func git(_ repo: URL, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    // Git can echo the repository path on failure. Do not forward it.
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("couldn't run git") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("git \(arguments.first ?? "") failed") }
    return String(decoding: data, as: UTF8.self)
}

func hash(_ salt: String, _ word: String) -> String {
    SHA256.hash(data: Data("\(salt):\(word)".utf8)).map { String(format: "%02x", $0) }.joined()
}

func isHex(_ text: Substring, count: Int? = nil) -> Bool {
    (count.map { text.count == $0 } ?? (text.count >= 32))
        && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

/// The salt and the hashes, or nil when there is no hash file.
func readHashes(_ repo: URL) -> (salt: String, hashes: Set<String>)? {
    guard let text = try? String(contentsOf: repo.appendingPathComponent(hashFile), encoding: .utf8) else { return nil }
    var salt: String?
    var hashes: Set<String> = []
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if salt == nil {
            guard line.hasPrefix("salt "), isHex(line.dropFirst(5)) else {
                fail("\(diagnosticPath(hashFile, in: repo)):\(index + 1): the first line must be \"salt\" and at least 32 hex digits")
            }
            salt = String(line.dropFirst(5))
        } else {
            guard isHex(Substring(line), count: 64) else { fail("\(diagnosticPath(hashFile, in: repo)):\(index + 1): not a SHA-256 in lowercase hex") }
            hashes.insert(line)
        }
    }
    guard let salt else { fail("\(diagnosticPath(hashFile, in: repo)) has no salt line") }
    return (salt, hashes)
}

/// The words of a line: each run of letters and digits in lowercase, and
/// the parts of one written in camel case.
func words(_ line: Substring) -> Set<String> {
    var found: Set<String> = []
    var run = ""
    func end() {
        guard !run.isEmpty else { return }
        found.insert(run.lowercased())
        var part = ""
        var previous: Character?
        for character in run {
            if let before = previous, character.isUppercase, before.isLowercase || before.isNumber {
                found.insert(part.lowercased())
                part = ""
            }
            part.append(character)
            previous = character
        }
        found.insert(part.lowercased())
        run = ""
    }
    for character in line {
        if character.isLetter || character.isNumber { run.append(character) } else { end() }
    }
    end()
    return found
}

/// UTF-16 or UTF-32 code units of `width` bytes, read in the given byte
/// order, with anything that isn't a scalar replaced instead of dropping the
/// whole text. Trailing bytes short of a unit are left out.
func lossyText(_ data: Data, width: Int, bigEndian: Bool) -> String {
    let bytes = [UInt8](data)
    let units = stride(from: 0, to: bytes.count - width + 1, by: width).map { offset in
        (0..<width).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + (bigEndian ? $1 : width - 1 - $1)]) }
    }
    return width == 2 ? String(decoding: units.map { UInt16($0) }, as: UTF16.self) : String(decoding: units, as: UTF32.self)
}

/// A BOM names the UTF-16 or UTF-32 byte order, but it can't prove the rest
/// is in it: text decoded with the wrong one is still "valid" nonsense. So
/// with a BOM scan its decoding, lossy if it doesn't decode, and the lossy
/// UTF-8 too. Without a BOM the encoding can be ambiguous, so scan every
/// valid text interpretation rather than guessing wrong and hiding a word.
/// Valid UTF-8 is scanned even if it contains NUL.
func decodedTexts(_ data: Data) -> [String] {
    var texts: [String] = []
    func add(_ text: String?) {
        if let text, !texts.contains(text) { texts.append(text) }
    }
    // UTF-32 LE shares UTF-16 LE's first two BOM bytes, so check it first.
    let boms: [(bytes: [UInt8], encoding: String.Encoding, width: Int, bigEndian: Bool)] = [
        ([0xff, 0xfe, 0x00, 0x00], .utf32LittleEndian, 4, false),
        ([0x00, 0x00, 0xfe, 0xff], .utf32BigEndian, 4, true),
        ([0xff, 0xfe], .utf16LittleEndian, 2, false),
        ([0xfe, 0xff], .utf16BigEndian, 2, true),
    ]
    if let bom = boms.first(where: { data.starts(with: $0.bytes) }) {
        let rest = data.dropFirst(bom.bytes.count)
        add(String(data: rest, encoding: bom.encoding) ?? lossyText(rest, width: bom.width, bigEndian: bom.bigEndian))
        add(String(decoding: data, as: UTF8.self))
        return texts
    }
    // A stray non-UTF-8 byte must not hide otherwise readable words.
    add(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
    for (width, encodings) in [(2, [String.Encoding.utf16LittleEndian, .utf16BigEndian]),
                               (4, [.utf32LittleEndian, .utf32BigEndian])] where data.count.isMultiple(of: width) {
        for encoding in encodings { add(String(data: data, encoding: encoding)) }
    }
    return texts
}

/// Redact the whole segment, including extensions and camel-case names.
/// Host rules apply here even outside the folders whose contents we scan.
func diagnosticPath(_ path: String, salt: String, hashes: Set<String>) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
        let text = String(segment)
        let privateWord = words(segment).contains { hashes.contains(hash(salt, $0)) }
        let host = hostRules.contains { $0.1.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        return privateWord || host ? "[redacted]" : text
    }.joined(separator: "/")
}

/// Fixed paths in setup/hash errors need the same protection as scanned
/// filenames. Read only the hash file, without issuing recursive diagnostics,
/// so even an error while validating that file can redact its path.
func diagnosticPath(_ path: String, in repo: URL) -> String {
    let text = (try? String(contentsOf: repo.appendingPathComponent(hashFile), encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let salt = lines.first.flatMap { $0.hasPrefix("salt ") ? String($0.dropFirst(5)) : nil } ?? ""
    return diagnosticPath(path, salt: salt, hashes: Set(lines.dropFirst()))
}

func check(_ repo: URL) {
    guard git(repo, ["ls-files", "--cached", "--", plainList]).isEmpty else {
        fail("\(diagnosticPath(plainList, in: repo)) is tracked by git. It holds the private words in plain text. Remove it with: git rm --cached \(diagnosticPath(plainList, in: repo))")
    }
    guard let (salt, hashes) = readHashes(repo) else { fail("\(diagnosticPath(hashFile, in: repo)) is missing. Make it with make hash-private-words") }
    let files = git(repo, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        .split(separator: "\0").map(String.init).sorted()
    var seen: [String: Bool] = [:]
    var problems = 0
    for file in files {
        let url = repo.appendingPathComponent(file)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
        let data: Data
        if values.isSymbolicLink == true {
            // Git stores the target text, not the file it points to. Never follow it.
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { continue }
            data = Data(target.utf8)
        } else {
            guard values.isRegularFile == true, let contents = try? Data(contentsOf: url) else { continue }
            data = contents
        }
        let path = diagnosticPath(file, salt: salt, hashes: hashes)
        let checkHosts = hostFolders.contains { file.hasPrefix($0) }
        for text in decodedTexts(data) {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for word in words(line) {
                    let listed = seen[word] ?? hashes.contains(hash(salt, word))
                    seen[word] = listed
                    if listed {
                        print("private-check: \(path):\(index + 1): a private word")
                        problems += 1
                        break
                    }
                }
                guard checkHosts else { continue }
                let string = String(line)
                let range = NSRange(string.startIndex..., in: string)
                for (kind, rule) in hostRules where rule.firstMatch(in: string, range: range) != nil {
                    print("private-check: \(path):\(index + 1): \(kind)")
                    problems += 1
                }
            }
        }
    }
    guard problems == 0 else {
        fail("\(problems) found. Take them out; this repository holds no private words and no real addresses")
    }
    print("private-check: ok (files: \(files.count), private words: \(hashes.count))")
}

func makeHashes(_ repo: URL) {
    guard let text = try? String(contentsOf: repo.appendingPathComponent(plainList), encoding: .utf8) else {
        fail("\(diagnosticPath(plainList, in: repo)) is missing. The owner keeps the plain list there, one word a line")
    }
    var hashes: Set<String> = []
    let salt = readHashes(repo)?.salt
        ?? (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard line.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            fail("\(diagnosticPath(plainList, in: repo)):\(index + 1) is not one word of letters and digits")
        }
        hashes.insert(hash(salt, line.lowercased()))
    }
    let head = """
        # The private words check (make private-check) fails on any file in git
        # with a word whose hash is below. The words themselves live only in
        # \(plainList), which git ignores. Make this file again
        # with make hash-private-words. Each line after the salt is the SHA-256
        # of "<salt>:<word>", the word in lowercase.
        salt \(salt)

        """
    let body = hashes.sorted().map { $0 + "\n" }.joined()
    do {
        try (head + body).write(to: repo.appendingPathComponent(hashFile), atomically: true, encoding: .utf8)
    } catch { fail("couldn't write \(diagnosticPath(hashFile, in: repo))") }
    print("private-check: wrote \(diagnosticPath(hashFile, in: repo)) (private words: \(hashes.count))")
}

let arguments = CommandLine.arguments.dropFirst()
let repo = URL(fileURLWithPath: arguments.dropFirst().first ?? ".")
switch arguments.first {
case "check": check(repo)
case "hash": makeHashes(repo)
default: fail("usage: swift scripts/private-check.swift check|hash [repo]")
}
