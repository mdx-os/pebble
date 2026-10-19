// The private words check, and the maker of its hash file.
// Usage: swift scripts/private-check.swift check [repo]
//        swift scripts/private-check.swift hash [repo]
//
// check: fails on any file in git (tracked, or new and not ignored) with a
// word whose salted hash is in Config/private-words.sha256. It prints the
// file and line, never the word. A listed word in a folder or file name is
// a problem too, whatever the file holds, and its path is printed with
// that name redacted. In docs/, Config/ and Packages/ it also
// fails on a hosting provider's hostname, a .internal or .local host and
// an IP address, printing what kind of thing it found, never the thing.
// It fails too if the plain list, Config/private-words.local.txt, is
// tracked by git.
//
// hash: makes Config/private-words.sha256 from the plain list, which git
// ignores and only the owner's machines have. It keeps the salt already in
// the file, so the same list makes the same file.
//
// A word is a run of letters and digits, compared in lowercase and in
// Unicode NFC, so a letter written as one scalar (U+00E9) or as a base
// letter and a combining mark (e and U+0301) is the same word. A word
// written in camel case is also read in its parts, so a listed word inside
// a name such as fooBarRelay, FOORelay or FOOs is found, and so are runs of
// up to 8 of its parts joined, so a listed foobar in OpenFooBarRelay is
// found too. A join only counts when it is itself a listed word, and parts
// of different names (foo_bar, foo bar) never join. So, by design, a
// listed foobar written with a separator (foo_bar, foo-bar, Foo Bar) or
// inside a run with no case change (openfoobarrelay) is not found. Where
// that matters, list each part, or each run it can hide in, as a word of
// its own. Text is read as written and again with each string or regex
// escape as a break, after one backslash or more: any ASCII letter (\n,
// \t, \b, \d, \w and the rest), \0 with up to two more octal digits, \xHH,
// \x{H...}, \uHHHH and \u{H...}. So "\nfoo" in a string gives foo as well
// as nfoo, and #"\bfoo\b"# gives foo as well as bfoo. A word encoded
// another way, as %0A in a URL or &#10; in HTML, is not read. Each line of the
// hash file after the salt is the lowercase hex SHA-256 of "<salt>:<word>",
// the word in lowercase NFC.
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

/// A word as it is compared and hashed: in lowercase, then in Unicode NFC.
/// The plain list, file contents and paths all go through this one function,
/// so the same word in either spelling makes the same hash.
func key(_ word: some StringProtocol) -> String {
    word.lowercased().precomposedStringWithCanonicalMapping
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

/// The most camel case parts joined into one word. A name in more parts
/// than this is still read whole, and in every run of up to this many.
let maxJoined = 8

/// The words of a line, each as `key` makes it: each run of letters and
/// digits, the parts of one written in camel case, and runs of up to
/// `maxJoined` of those parts joined.
func words(_ line: Substring) -> Set<String> {
    var found: Set<String> = []
    var run = ""
    func end() {
        guard !run.isEmpty else { return }
        found.insert(key(run))
        let characters = Array(run)
        // A part starts at a capital after a small letter or a digit
        // (fooBar, v2Bar). The second reading also starts one at the last
        // capital of a run of them followed by a small letter (the R of
        // FOORelay). Both are kept, so the second only ever adds words:
        // useACMECorp still gives acmecorp.
        for capitalRuns in [false, true] {
            var parts: [String] = []
            var part = ""
            for (index, character) in characters.enumerated() {
                if index > 0, character.isUppercase {
                    let before = characters[index - 1]
                    let after = index + 1 < characters.count ? characters[index + 1] : nil
                    if before.isLowercase || before.isNumber || capitalRuns && before.isUppercase && after?.isLowercase == true {
                        parts.append(part)
                        part = ""
                    }
                }
                part.append(character)
            }
            parts.append(part)
            // Each part, and each run of 2 to `maxJoined` parts next to each
            // other in this reading, joined: a listed word written in parts
            // (OpenFooBarRelay gives foobar) is found. Only parts of one run
            // of letters and digits join, so foo_bar never gives foobar.
            for start in parts.indices {
                for end in start..<min(start + maxJoined, parts.count) {
                    found.insert(key(parts[start...end].joined()))
                }
            }
        }
        // A run of two or more capitals with one small s after it, at the
        // end or before the next part, is also read without the s: FOOs,
        // OpenFOOs and FOOsRelay give foo.
        for (index, character) in characters.enumerated()
        where character == "s" && index >= 2 && characters[index - 1].isUppercase && characters[index - 2].isUppercase
            && (index + 1 == characters.count || !characters[index + 1].isLowercase) {
            var start = index - 2
            while start > 0, characters[start - 1].isUppercase { start -= 1 }
            found.insert(key(String(characters[start..<index])))
        }
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
/// is in it: text decoded with the wrong one is still "valid" nonsense, and
/// text without a BOM can start with the bytes of one (UTF-16 BE of NUL and
/// U+FEFF starts 00 00 FE FF). So scan every reading, never guessing one and
/// hiding a word: after each BOM the start fits, the rest in its encoding,
/// and always the whole data as UTF-8, and UTF-16 and UTF-32 in both byte
/// orders. Each is lossy, so one bad unit or a stray byte at the end never
/// drops a whole reading. Valid UTF-8 is scanned even if it contains NUL.
func decodedTexts(_ data: Data) -> [String] {
    var texts: [String] = []
    func add(_ text: String?) {
        if let text, !texts.contains(text) { texts.append(text) }
    }
    // FF FE 00 00 is the UTF-32 LE BOM, and also the UTF-16 LE one before a
    // NUL, so scan every reading whose BOM the start fits.
    let boms: [(bytes: [UInt8], encoding: String.Encoding, width: Int, bigEndian: Bool)] = [
        ([0xff, 0xfe, 0x00, 0x00], .utf32LittleEndian, 4, false),
        ([0x00, 0x00, 0xfe, 0xff], .utf32BigEndian, 4, true),
        ([0xff, 0xfe], .utf16LittleEndian, 2, false),
        ([0xfe, 0xff], .utf16BigEndian, 2, true),
    ]
    let fitting = boms.filter { data.starts(with: $0.bytes) }
    for bom in fitting {
        let rest = data.dropFirst(bom.bytes.count)
        add(String(data: rest, encoding: bom.encoding) ?? lossyText(rest, width: bom.width, bigEndian: bom.bigEndian))
    }
    // A stray non-UTF-8 byte must not hide otherwise readable words.
    add(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
    for (width, encodings) in [(2, [(String.Encoding.utf16LittleEndian, false), (.utf16BigEndian, true)]),
                               (4, [(.utf32LittleEndian, false), (.utf32BigEndian, true)])] {
        for (encoding, bigEndian) in encodings {
            add(String(data: data, encoding: encoding) ?? lossyText(data, width: width, bigEndian: bigEndian))
        }
    }
    return texts
}

/// A string or regex escape as source writes it, after one backslash or
/// more, so the doubled one source writes to pass an escape on counts too:
/// a character by its number (\u{H...}, \uHHHH, \x{H...}, \xHH), \0 with up
/// to two more octal digits, or any one ASCII letter (\n, \t, \b, \d, \w
/// and the rest).
let escape = try! NSRegularExpression(
    pattern: #"\\+(?:u\{[0-9A-Fa-f]+\}|u[0-9A-Fa-f]{4}|x\{[0-9A-Fa-f]+\}|x[0-9A-Fa-f]{2}|0[0-7]{0,2}|[A-Za-z])"#)

/// Every reading of `data` to scan: each decoded text as written, and again
/// with each escape read as a space. As written, "\nfoo" reads as the word
/// nfoo and #"\bfoo\b"# as bfoo, never foo, so the second reading finds a
/// listed word right after an escape. It only adds words, and a space never
/// adds a line, so line numbers stay the same.
func readings(_ data: Data) -> [String] {
    let texts = decodedTexts(data)
    let broken = texts.filter { $0.contains("\\") }.map { text in
        escape.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    return texts + broken.filter { !texts.contains($0) }
}

/// Whether one segment of a path holds a listed word, read as a line of
/// text is: either Unicode spelling, camel case parts and their joins.
func holdsPrivateWord(_ segment: Substring, salt: String, hashes: Set<String>) -> Bool {
    words(segment).contains { hashes.contains(hash(salt, $0)) }
}

/// Redact the whole segment, including extensions and camel-case names.
/// Host rules apply here even outside the folders whose contents we scan.
func diagnosticPath(_ path: String, salt: String, hashes: Set<String>) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
        let text = String(segment)
        let privateWord = holdsPrivateWord(segment, salt: salt, hashes: hashes)
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
        let path = diagnosticPath(file, salt: salt, hashes: hashes)
        // Git publishes a file's path as much as what it holds, so a listed
        // word in any folder or file name is a problem, whatever the file
        // holds: empty, binary, or not read at all.
        if file.split(separator: "/").contains(where: { holdsPrivateWord($0, salt: salt, hashes: hashes) }) {
            print("private-check: \(path): a private word in its path")
            problems += 1
        }
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
        let checkHosts = hostFolders.contains { file.hasPrefix($0) }
        // Two readings can decode the same line. It is one problem.
        var reported: Set<String> = []
        func report(_ line: Int, _ kind: String) {
            guard reported.insert("\(line): \(kind)").inserted else { return }
            print("private-check: \(path):\(line): \(kind)")
            problems += 1
        }
        for text in readings(data) {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for word in words(line) {
                    let listed = seen[word] ?? hashes.contains(hash(salt, word))
                    seen[word] = listed
                    if listed {
                        report(index + 1, "a private word")
                        break
                    }
                }
                guard checkHosts else { continue }
                let string = String(line)
                let range = NSRange(string.startIndex..., in: string)
                for (kind, rule) in hostRules where rule.firstMatch(in: string, range: range) != nil {
                    report(index + 1, kind)
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
        hashes.insert(hash(salt, key(line)))
    }
    let head = """
        # The private words check (make private-check) fails on any file in git
        # with a word whose hash is below. The words themselves live only in
        # \(plainList), which git ignores. Make this file again
        # with make hash-private-words. Each line after the salt is the SHA-256
        # of "<salt>:<word>", the word in lowercase and then Unicode NFC.
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
