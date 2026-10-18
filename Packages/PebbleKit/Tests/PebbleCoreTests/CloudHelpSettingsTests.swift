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

    /// The real off mark is written so it can be made while the device is
    /// locked: no protection, or protection only until the first unlock
    /// after a restart. Complete protection would make the write fail
    /// exactly when a locked switch off needs it.
    @Test func theOffMarkCanBeWrittenWhileTheDeviceIsLocked() throws {
        let (store, folder) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.markOff()
        #if canImport(Darwin)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.offMarkURL.path)
        let protection = try #require(attributes[.protectionKey] as? FileProtectionType)
        #expect([FileProtectionType.none, .completeUntilFirstUserAuthentication].contains(protection),
                "\(protection.rawValue)")
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

    /// A word of only hyphens or other punctuation hides nothing, since
    /// `Redactor` matches whole words, so it is refused rather than kept
    /// in a list where it would look hidden.
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
    @Test(arguments: ["https://cloud.example.com:443", "https://cloud.example.com:443/v1", "https://[::1]:443"])
    func anAddressWithHttpsOwnPortWrittenOutIsRefused(raw: String) {
        #expect(CloudEndpoint.url(from: raw) == nil)
        #expect(CloudEndpoint.url(from: raw.replacingOccurrences(of: ":443", with: ":8443")) != nil)
    }

    /// A build that isn't Debug never reaches a cloud model, whatever its
    /// settings hold: the address reads as none. Tests run in Debug, so
    /// the Release reading is driven through its flag, and the flag itself
    /// is pinned for each kind of build.
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
