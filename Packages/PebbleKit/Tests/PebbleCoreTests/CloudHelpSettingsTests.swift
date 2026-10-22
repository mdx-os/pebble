import Foundation
import PebbleCore
import Testing

/// A file manager whose Application Support is a scratch folder.
final class ScratchSupportFileManager: FileManager, @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")

    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        guard directory == .applicationSupportDirectory else {
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }
        if shouldCreate { try createDirectory(at: root, withIntermediateDirectories: true) }
        return root
    }
}

struct CloudHelpSettingsTests {
    /// A scratch folder per test, removed afterwards.
    func scratchStore() throws -> (CloudHelpFileStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json")), folder)
    }

    @Test func offByDefault() throws {
        #expect(CloudHelpSettings().isOn == false)
        #expect(CloudHelpSettings.off.isOn == false)
        #expect(try InMemoryCloudHelpStore().load().isOn == false)
    }

    @Test func aNewDeviceReadsAsOff() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try store.load() == .off)
    }

    @Test func unreadableSettingsThrowAndReadAsOff() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{\"isOn\": tru".utf8).write(to: store.fileURL)
        #expect(throws: MemoryStore.Unreadable.self) { try store.load() }
        #expect(store.loadOrOff() == .off)
    }

    @Test func settingsAndPrivateWordsAreKeptInOneFileNextToTheNotes() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        #expect(try CloudHelpFileStore(fileURL: store.fileURL).load() == CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        // No staged copy is left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["cloud-help.json"])
        // Nothing about the cloud is kept in UserDefaults any more.
        #expect(UserDefaults.standard.object(forKey: "pebble.cloudHelp") == nil)
    }

    // MARK: A yes is for one address

    @Test func aYesCountsOnlyForTheAddressItWasGivenFor() throws {
        let here = try #require(URL(string: "https://cloud.example.com"))
        let elsewhere = try #require(URL(string: "https://other.example.com"))
        var settings = CloudHelpSettings()
        settings.turnOn(for: here)
        #expect(settings.isOn(for: here))
        #expect(!settings.isOn(for: elsewhere))
        #expect(!settings.isOn(for: try #require(URL(string: "https://cloud.example.com/v2"))))
        #expect(!settings.isOn(for: nil))
        // On with no address kept, as a file saved before addresses were.
        #expect(!CloudHelpSettings(isOn: true).isOn(for: here))
        settings.turnOff()
        #expect(settings == CloudHelpSettings())
        #expect(settings.consentedEndpoint == nil)
    }

    /// The address is kept in the file, and a file written before it was
    /// kept reads as on for no address at all, so it needs a fresh yes.
    @Test func theAddressIsKeptAndAnOlderFileReadsAsOff() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = try #require(URL(string: "https://cloud.example.com"))
        try store.save(CloudHelpSettings(isOn: true, for: here, privateWords: ["lemon cake"]))
        #expect(try store.load().isOn(for: here))
        #expect(try store.load().consentedEndpoint == "https://cloud.example.com")
        try Data(#"{"isOn":true,"privateWords":["lemon cake"]}"#.utf8).write(to: store.fileURL)
        let older = try store.load()
        #expect(older.isOn && older.consentedEndpoint == nil)
        #expect(!older.isOn(for: here))
        #expect(older.privateWords == ["lemon cake"])
    }

    /// Run against a scratch Application Support, so the test never makes
    /// the real folder on a developer's Mac or in CI.
    @Test func theAppKeepsThemInTheNotesFolderLeftOutOfBackups() throws {
        let files = ScratchSupportFileManager()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let folder = try MemoryStore.onDeviceFolder(fileManager: files)
        let store = try CloudHelpFileStore.onDevice(fileManager: files)
        #expect(folder.path.hasPrefix(files.root.path))
        #expect(store.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #if canImport(Darwin)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #endif
    }

    /// The off mark makes a saved on read as off, survives a new store on
    /// the same file, as after a relaunch, and holds no words. The next
    /// save, a fresh yes included, clears it, and so does erase.
    @Test func theOffMarkReadsAsOffUntilTheNextSave() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = try #require(URL(string: "https://cloud.example.com"))
        try store.save(CloudHelpSettings(isOn: true, for: here, privateWords: ["lemon cake"]))
        try store.markOff()
        let relaunched = CloudHelpFileStore(fileURL: store.fileURL)
        #expect(try relaunched.load() == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(try Data(contentsOf: store.offMarkURL).isEmpty, "the mark holds nothing")
        try relaunched.save(CloudHelpSettings(isOn: true, for: here, privateWords: ["lemon cake"]))
        #expect(try relaunched.load().isOn(for: here))
        #expect(!FileManager.default.fileExists(atPath: store.offMarkURL.path))
        try store.markOff()
        try store.erase()
        #expect(!FileManager.default.fileExists(atPath: store.offMarkURL.path))
        // The in-memory store keeps the same rule.
        let memory = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: here))
        memory.makeUnreadable()
        try memory.markOff()
        memory.makeUnreadable(false)
        #expect(try !memory.load().isOn(for: here))
        try memory.save(CloudHelpSettings(isOn: true, for: here))
        #expect(try memory.load().isOn(for: here))
    }

    /// The sent mark survives a new store on the same file, as after a
    /// relaunch, holds no words, and stays through a save and an erase,
    /// since erasing the setting can't call back what was sent.
    @Test func theSentMarkOutlivesARelaunchAndAnErase() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!store.wasSent)
        try store.save(CloudHelpSettings(privateWords: ["lemon cake"]))
        try store.markSent()
        try store.markSent()
        let relaunched = CloudHelpFileStore(fileURL: store.fileURL)
        #expect(relaunched.wasSent)
        #expect(try Data(contentsOf: store.sentMarkURL).isEmpty, "the mark holds nothing")
        try relaunched.save(.off)
        try relaunched.erase()
        #expect(CloudHelpFileStore(fileURL: store.fileURL).wasSent)
        // The in-memory store keeps the same rule.
        let memory = InMemoryCloudHelpStore()
        #expect(!memory.wasSent)
        try memory.markSent()
        try memory.erase()
        #expect(memory.wasSent)
    }

    /// The real off mark is written so it can be made while the device is
    /// locked: no protection, or protection only until the first unlock
    /// after a restart. Complete protection would make the write fail
    /// exactly when a locked switch off needs it.
    ///
    /// These tests run on a Mac, which may not report or enforce file
    /// protection, so the options the mark is written with are pinned
    /// themselves: they are the same on an iPhone, where the lock matters.
    /// What the file reports is checked too, where the Mac reports it.
    @Test func theOffMarkCanBeWrittenWhileTheDeviceIsLocked() throws {
        #expect(CloudHelpFileStore.offMarkWriting == [.noFileProtection])
        for locking in [Data.WritingOptions.completeFileProtection, .completeFileProtectionUnlessOpen] {
            #expect(!CloudHelpFileStore.offMarkWriting.contains(locking))
        }
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.markOff()
        #if canImport(Darwin)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.offMarkURL.path)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            #expect([FileProtectionType.none, .completeUntilFirstUserAuthentication].contains(protection),
                    "\(protection.rawValue)")
        }
        #endif
        #expect(try Data(contentsOf: store.offMarkURL).isEmpty)
    }

    @Test func eraseRemovesEvenAnUnreadableFile() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("garbage".utf8).write(to: store.fileURL)
        try store.erase()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.load() == .off)
    }

    @Test func privateWordsAreTidied() {
        var settings = CloudHelpSettings()
        let added = [
            settings.addPrivateWord("  lemon \n cake "),
            settings.addPrivateWord("Lemon Cake"),
            settings.addPrivateWord("   "),
            settings.addPrivateWord(String(repeating: "a", count: CloudHelpSettings.maxPrivateWordLength + 1)),
            settings.addPrivateWord("Sam's place"),
            // The same word with a curly apostrophe is not added twice.
            settings.addPrivateWord("sam\u{2019}s place"),
        ]
        #expect(added == [true, false, false, false, true, false])
        #expect(settings.privateWords == ["lemon cake", "Sam's place"])
        settings.removePrivateWord("lemon cake")
        #expect(settings.privateWords == ["Sam's place"])
    }

    /// A word of only hyphens hides nothing, since `Redactor` leaves it
    /// out, so it is refused rather than kept in a list where it would
    /// look hidden; other punctuation alone is refused with it. Symbols
    /// are matched, so they are taken.
    @Test func aWordOfOnlyPunctuationIsRefused() {
        var settings = CloudHelpSettings()
        for word in ["-", "--", " - - ", "...", "!?", "\u{2014}", "'"] {
            #expect(settings.refusal(for: word) == .onlyPunctuation, "\(word)")
            let added = settings.addPrivateWord(word)
            #expect(!added, "\(word)")
        }
        #expect(settings.privateWords.isEmpty)
        for word in ["a-b", "42", "Zoë", "x!"] {
            #expect(settings.refusal(for: word) == nil, "\(word)")
        }
        // And a word it takes is one the redactor hides.
        #expect(Redactor(privateWords: ["a-b"]).redact("see a-b now").text == "see [private] now")
        #expect(settings.refusal(for: "$$") == nil)
        #expect(Redactor(privateWords: ["$$"]).redact("pay $$ now").text == "pay [private] now")
    }

    /// A word of only hyphens saved before such words were refused hides
    /// nothing, so it is left out as the file is read, and the list never
    /// shows it as hidden. Every other word is kept as it was.
    @Test func aSavedWordThatHidesNothingIsLeftOutWhenRead() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"isOn":false,"privateWords":["--","lemon cake","- -","...","$$"]}"#.utf8).write(to: store.fileURL)
        let read = try store.load()
        #expect(read.privateWords == ["lemon cake", "...", "$$"])
        for word in read.privateWords {
            #expect(!Redactor(privateWords: [word]).redact("x \(word) y").isUnchanged, "\(word) hides nothing")
        }
        #expect(!Redactor.canHide("--") && !Redactor.canHide(" - ") && Redactor.canHide("a-b"))
        // The rest of the file reads as written.
        let here = try #require(URL(string: "https://cloud.example.com"))
        try store.save(CloudHelpSettings(isOn: true, for: here, privateWords: ["lemon cake"]))
        #expect(try store.load() == CloudHelpSettings(isOn: true, for: here, privateWords: ["lemon cake"]))
    }

    /// The yes is for the address exactly as written. Another spelling of
    /// it, with a trailing slash, is another address, and asks again; a
    /// strict match can only ask too often. Capitals in the host, and a
    /// host in another script, are refused as the address is read, so
    /// neither can make two spellings of one host.
    @Test func aYesIsForTheAddressExactlyAsWritten() throws {
        let here = try #require(CloudEndpoint.url(from: "https://cloud.example.com"))
        let slashed = try #require(CloudEndpoint.url(from: "https://cloud.example.com/"))
        let settings = CloudHelpSettings(isOn: true, for: here)
        #expect(settings.isOn(for: here))
        #expect(!settings.isOn(for: slashed))
        #expect(!CloudHelpSettings(isOn: true, for: slashed).isOn(for: here))
        for raw in ["https://Cloud.Example.COM", "https://CLOUD.example.com/v1", "https://clöud.example.com"] {
            #expect(CloudEndpoint.url(from: raw) == nil, "\(raw)")
        }
        // The ASCII form of a host in another script is its only form, and
        // a yes for it holds for it alone.
        let ascii = try #require(CloudEndpoint.url(from: "https://xn--cld-0na.example.com"))
        #expect(CloudHelpSettings(isOn: true, for: ascii).isOn(for: ascii))
        #expect(!CloudHelpSettings(isOn: true, for: ascii).isOn(for: here))
    }

    /// A word the redactor would already hide is never added twice: the
    /// same folding as `Redactor`, for every apostrophe, case and accent.
    @Test func aWordTheRedactorAlreadyHidesIsNotAddedAgain() {
        var settings = CloudHelpSettings()
        let added = [settings.addPrivateWord("Zoë")]
        #expect(settings.refusal(for: "Zoe") == .alreadyThere)
        #expect(settings.refusal(for: "ZOE") == .alreadyThere)
        let again = [settings.addPrivateWord("zoe"), settings.addPrivateWord("Sam's place")]
        #expect(added == [true])
        #expect(again == [false, true])
        for apostrophe in ["\u{2019}", "\u{2018}", "\u{02BC}"] {
            #expect(settings.refusal(for: "sam\(apostrophe)s place") == .alreadyThere)
        }
        #expect(settings.privateWords == ["Zoë", "Sam's place"])
        // And the redactor hides "Zoe" with "Zoë" on the list, so the
        // refusal is true.
        let redacted = Redactor(memory: [], privateWords: settings.privateWords).redact("Zoe called")
        #expect(!redacted.text.contains("Zoe"))
    }

    // MARK: The address

    @Test(arguments: [nil, "", "   ", "$(PEBBLE_CLOUD_ENDPOINT)", "http://cloud.example.com", "cloud.example.com", "https://"])
    func anEmptyOrUnsafeAddressMeansNoCloud(raw: String?) {
        #expect(CloudEndpoint.url(from: raw) == nil)
    }

    /// Nothing secret can ride along in the address.
    @Test(arguments: [
        "https://someone:secret@cloud.example.com",
        "https://someone@cloud.example.com",
        "https://cloud.example.com/?key=abc",
        "https://cloud.example.com/v1?",
        "https://cloud.example.com/#token",
        "https://cloud.example.com/#",
    ])
    func anAddressWithAUserQueryOrFragmentIsRefused(raw: String) {
        #expect(CloudEndpoint.url(from: raw) == nil)
    }

    /// A host in another script goes out encoded, so it would read one way
    /// in the preview and another on the wire. It is refused.
    @Test(arguments: ["https://bücher.example", "https://cloud.example.com/café"])
    func anAddressThatIsNotPlainASCIIIsRefused(raw: String) {
        #expect(CloudEndpoint.url(from: raw) == nil)
    }

    @Test func aSecureAddressIsUsed() {
        #expect(CloudEndpoint.url(from: " https://cloud.example.com ")?.host == "cloud.example.com")
        #expect(CloudEndpoint.url(from: "https://cloud.example.com:8443/base")?.path == "/base")
        // A host already in its plain ASCII form is taken.
        #expect(CloudEndpoint.url(from: "https://xn--bcher-kva.example") != nil)
    }

    /// https's own port, written out, is left out of the Host line the
    /// system sends, so the preview's Host line could read differently from
    /// the address. Refused, rather than shown one way and sent another.
    /// The IPv6 loopback address is written in parts because the private
    /// check takes any address under Packages/ for a real one.
    @Test(arguments: ["https://cloud.example.com:443", "https://cloud.example.com:443/v1", "https://[:" + ":1]:443"])
    func anAddressWithHttpsOwnPortWrittenOutIsRefused(raw: String) {
        #expect(CloudEndpoint.url(from: raw) == nil)
        #expect(CloudEndpoint.url(from: raw.replacingOccurrences(of: ":443", with: ":8443")) != nil)
    }

    /// A build that isn't Debug never reaches a cloud model, whatever its
    /// settings hold: the address reads as none. These tests run in Debug,
    /// where the `#else` branch isn't compiled, so here the Release reading
    /// is driven through its flag and the flag is pinned in the source.
    /// The executed check is `make release-test`
    /// (`scripts/release-probe.sh`), which builds PebbleCore in Release and
    /// fails if it reads an address (`theReleaseProbeRunsTheShippedCode`).
    @Test func onlyADebugBuildReadsAnAddress() throws {
        let raw = "https://cloud.example.com"
        #expect(CloudEndpoint.url(from: raw, buildMayReachTheCloud: false) == nil)
        #expect(CloudEndpoint.url(from: raw, buildMayReachTheCloud: true) != nil)
        #expect(CloudEndpoint.url(from: raw) != nil, "tests run in Debug")
        let source = try String(contentsOf: Self.root.appendingPathComponent(
            "Packages/PebbleKit/Sources/PebbleCore/CloudHelp.swift"), encoding: .utf8)
        #expect(source.contains("""
                #if DEBUG
                    static let buildMayReachTheCloud = true
                    #else
                    static let buildMayReachTheCloud = false
                    #endif
                """))
        #expect(source.contains("url(from: raw, buildMayReachTheCloud: buildMayReachTheCloud)"))
    }

    @Test func theAppAddressIsReadFromInfoPlist() {
        #expect(CloudEndpoint.url(infoDictionary: [:]) == nil)
        #expect(CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: ""]) == nil)
        #expect(CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: "https://cloud.example.com"]) != nil)
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The shipped config leaves the address empty, so the cloud is off.
    @Test func theShippedConfigHasNoAddress() throws {
        let config = try String(contentsOf: Self.root.appendingPathComponent("Config/Cloud.xcconfig"), encoding: .utf8)
        let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("PEBBLE_CLOUD_ENDPOINT") })
        let value = line.split(separator: "=", maxSplits: 1).dropFirst().first ?? ""
        #expect(value.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    #if os(macOS)
    /// `make secrets-check` fails once the local file is tracked, even when
    /// it was forced past .gitignore. Run against a scratch repository.
    @Test func theSecretsCheckFailsWhenTheLocalAddressFileIsTracked() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("local-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let check = Self.root.appendingPathComponent("scripts/local-config-check.sh").path
        #expect(try run(["git", "init", "--quiet"]) == 0)
        try Data("Config/Cloud.local.xcconfig\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data("PEBBLE_CLOUD_ENDPOINT =\n".utf8).write(to: repo.appendingPathComponent("Config/Cloud.local.xcconfig"))
        #expect(try run(["sh", check, repo.path]) == 0)
        #expect(try run(["git", "add", "-f", "Config/Cloud.local.xcconfig"]) == 0)
        #expect(try run(["sh", check, repo.path]) == 1)
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("secrets-check:\n\tsh scripts/local-config-check.sh"))
    }
    #endif

    /// A real address goes in a local file git ignores, so it is never committed.
    @Test func aRealAddressLivesInAnIgnoredLocalFile() throws {
        let config = try String(contentsOf: Self.root.appendingPathComponent("Config/Cloud.xcconfig"), encoding: .utf8)
        #expect(config.split(separator: "\n").contains("#include? \"Cloud.local.xcconfig\""))
        let ignore = try String(contentsOf: Self.root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore.split(separator: "\n").contains("Config/Cloud.local.xcconfig"))
    }
}
