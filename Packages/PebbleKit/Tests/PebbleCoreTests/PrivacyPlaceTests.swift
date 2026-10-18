import PebbleCore
import Testing

/// Every line that could promise the device, pinned to the one flag.
/// docs/VOICE.md: say it only when the flag says so.
struct PrivacyPlaceTests {
    /// Each device line, as the copy builds it for a place.
    static func deviceLines(_ place: PrivacyPlace) -> [String] {
        [
            MemoryWords.empty(place),
            MemoryWords.saved(place),
            MemoryWords.privacyNote(place),
            FirstConversation.presence(place),
            FirstConversation.opening(named: "Pip", onDevice: place.staysOnDevice),
            FirstRunWords.helloDetail(onDevice: place.staysOnDevice),
            FeedWords.sampleNote(place),
        ]
    }

    /// Reads the one phrase list, `DevicePromise.phrases`. A line allowed
    /// with a written reason there is not a promise about the device.
    static func promisesTheDevice(_ line: String) -> Bool {
        !DevicePromise.found(in: line).isEmpty && !DevicePromise.allowedLines.contains(line)
    }

    @Test func onDeviceEveryLineMakesThePromise() {
        for line in Self.deviceLines(.onDevice) {
            #expect(Self.promisesTheDevice(line), "no device promise in: \(line)")
        }
    }

    @Test func offDeviceNoLineMentionsTheDevice() {
        for line in Self.deviceLines(.mayLeaveDevice) {
            #expect(!Self.promisesTheDevice(line), "device promise in: \(line)")
            #expect(!line.contains("stays"), "device promise in: \(line)")
        }
    }

    @Test func theOffDeviceLinesStillSayWhatIsTrue() {
        #expect(MemoryWords.saved(.mayLeaveDevice) == "Saved.")
        #expect(MemoryWords.empty(.mayLeaveDevice).contains("change or remove it anytime"))
        #expect(MemoryWords.privacyNote(.mayLeaveDevice) == "Removing a note erases it.")
        #expect(FirstConversation.presence(.mayLeaveDevice) == "Here with you.")
    }

    @Test func theFlagReadsBothWays() {
        #expect(PrivacyPlace(staysOnDevice: true) == .onDevice)
        #expect(PrivacyPlace(staysOnDevice: false) == .mayLeaveDevice)
        #expect(PrivacyPlace.onDevice.staysOnDevice)
        #expect(!PrivacyPlace.mayLeaveDevice.staysOnDevice)
    }
}
