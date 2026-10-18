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

    @Test func aSecureAddressIsUsed() {
        #expect(CloudEndpoint.url(from: " https://cloud.example.com ")?.host == "cloud.example.com")
        #expect(CloudEndpoint.url(from: "https://cloud.example.com:8443/base")?.path == "/base")
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
