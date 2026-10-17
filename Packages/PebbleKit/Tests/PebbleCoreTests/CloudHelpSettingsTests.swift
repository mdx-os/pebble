import Foundation
import PebbleCore
import Testing

struct CloudHelpSettingsTests {
    @Test func offByDefault() {
        #expect(CloudHelpSettings().isOn == false)
        #expect(CloudHelpSettings.off.isOn == false)
        #expect(InMemoryCloudHelpStore().load().isOn == false)
    }

    @Test func aNewDeviceReadsAsOff() throws {
        let suite = "pebble.tests.cloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UserDefaultsCloudHelpStore(defaults: defaults).load() == .off)
    }

    @Test func unreadableSettingsReadAsOff() throws {
        let suite = "pebble.tests.cloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"isOn\": tru".utf8), forKey: UserDefaultsCloudHelpStore.key)
        #expect(UserDefaultsCloudHelpStore(defaults: defaults).load() == .off)
    }

    @Test func settingsAreKept() throws {
        let suite = "pebble.tests.cloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCloudHelpStore(defaults: defaults)
        store.save(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        #expect(UserDefaultsCloudHelpStore(defaults: defaults).load() == CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
    }

    @Test func privateWordsAreTidied() {
        var settings = CloudHelpSettings()
        let added = [
            settings.addPrivateWord("  lemon \n cake "),
            settings.addPrivateWord("Lemon Cake"),
            settings.addPrivateWord("   "),
            settings.addPrivateWord(String(repeating: "a", count: CloudHelpSettings.maxPrivateWordLength + 1)),
        ]
        #expect(added == [true, false, false, false])
        #expect(settings.privateWords == ["lemon cake"])
        settings.removePrivateWord("lemon cake")
        #expect(settings.privateWords.isEmpty)
    }

    // MARK: The address

    @Test(arguments: [nil, "", "   ", "$(PEBBLE_CLOUD_ENDPOINT)", "http://cloud.example.com", "cloud.example.com", "https://"])
    func anEmptyOrUnsafeAddressMeansNoCloud(raw: String?) {
        #expect(CloudEndpoint.url(from: raw) == nil)
    }

    @Test func aSecureAddressIsUsed() {
        #expect(CloudEndpoint.url(from: " https://cloud.example.com ")?.host == "cloud.example.com")
    }

    @Test func theAppAddressIsReadFromInfoPlist() {
        #expect(CloudEndpoint.url(infoDictionary: [:]) == nil)
        #expect(CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: ""]) == nil)
        #expect(CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: "https://cloud.example.com"]) != nil)
    }

    /// The shipped config leaves the address empty, so the cloud is off.
    @Test func theShippedConfigHasNoAddress() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let config = try String(contentsOf: root.appendingPathComponent("Config/Cloud.xcconfig"), encoding: .utf8)
        let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("PEBBLE_CLOUD_ENDPOINT") })
        let value = line.split(separator: "=", maxSplits: 1).dropFirst().first ?? ""
        #expect(value.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
