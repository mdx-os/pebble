#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// The cloud setting and the preview say the policy in `CloudPolicy`'s
/// words, and sign-in keeps nothing once the cloud is off or Forget
/// everything has run.
@MainActor
struct CloudPolicyScreenTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let appleUser = "001234.4f1a2b3c4d5e6f708192a3b4c5d6e7f8.0123"

    func memory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("policy-memory-\(UUID().uuidString).json")
        return MemoryStore(fileURL: url)
    }

    func signedIn(_ keychain: InMemoryCloudKeychain) throws -> AppleCloudAuth {
        let auth = AppleCloudAuth(keychain: keychain)
        try auth.accept(appleUser: appleUser)
        #expect(auth.signIn(for: endpoint) != nil)
        #expect(keychain.all[AppleCloudAuth.deviceKeyAccount] != nil, "the key is made on the device")
        return auth
    }

    static let viewSource: String = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift"),
                            encoding: .utf8)) ?? ""
    }()

    /// The setting shows a card of the policy's lines, and the preview the
    /// policy's line under where it goes, both read from `CloudPolicy`.
    @Test func theSettingAndThePreviewShowThePolicy() {
        #expect(CloudHelpView.policyLines == CloudPolicy.current.lines)
        #expect(CloudPreviewSheet.policyLine == CloudPolicy.current.previewLine)
        let source = Self.viewSource
        #expect(source.contains("switchCard\n                    policyCard\n                    privateWordsCard\n"))
        #expect(source.contains("ForEach(Array(Self.policyLines.enumerated()), id: \\.offset)"))
        #expect(source.contains("Text(CloudWords.policyTitle)"))
        #expect(source.contains("Label(Self.policyLine, systemImage: \"building.2\")"))
    }

    /// Turning the cloud off removes Apple's ID and the device key.
    @Test func turningTheCloudOffRemovesTheDeviceKey() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = try signedIn(keychain)
        let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)),
                             endpoint: endpoint, memory: memory(), auth: auth)
        #expect(help.usesCloudForNewChats)
        // With the cloud on, a new chat may leave the device.
        #expect(help.privacyPlace(local: LocalStubModel()) == .mayLeaveDevice)
        help.turnOff()
        #expect(keychain.all.isEmpty)
        #expect(auth.signIn(for: endpoint) == nil)
    }

    /// Forget everything removes them too, on or off.
    @Test func forgetEverythingRemovesTheDeviceKey() throws {
        for on in [true, false] {
            let keychain = InMemoryCloudKeychain()
            let auth = try signedIn(keychain)
            let help = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: on, for: endpoint)),
                                 endpoint: endpoint, memory: memory(), auth: auth)
            try help.forgetPrivateWords()
            #expect(keychain.all.isEmpty, "on: \(on)")
        }
        // And when the setting couldn't be opened at launch.
        let keychain = InMemoryCloudKeychain()
        let auth = try signedIn(keychain)
        try CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory(), auth: auth).forgetPrivateWords()
        #expect(keychain.all.isEmpty)
    }

    /// An empty address, even with the policy named, means the cloud can't
    /// be turned on.
    @Test func anEmptyAddressCantBeTurnedOn() {
        let read = CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: "",
                                                      CloudEndpoint.policyKey: CloudPolicy.currentVersion])
        #expect(read == nil)
        let help = CloudHelp(store: InMemoryCloudHelpStore(), endpoint: read, memory: memory())
        #expect(!help.isAvailable)
        #expect(!help.setOn(true))
        help.confirmTurnOn()
        #expect(!help.usesCloudForNewChats)
        #expect(help.privacyPlace(local: LocalStubModel()) == .onDevice)
    }
}
#endif
