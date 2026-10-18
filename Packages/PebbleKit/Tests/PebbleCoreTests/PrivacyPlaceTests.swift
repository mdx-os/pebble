import PebbleCore
import PromiseWords
import Testing

/// Every line that could promise the device, pinned to the one flag.
/// docs/VOICE.md: say it only when the flag says so.
struct PrivacyPlaceTests {
    /// Every place there is. `PrivacyPlace` is not `CaseIterable`, on
    /// purpose, so the switch with no default is what keeps this whole: a
    /// new place stops the tests building until it is listed here. A new
    /// place means updating all three: the array, the switch, and the count
    /// in `theOffDetailIsLintedForEveryPlace`.
    static let everyPlace: [PrivacyPlace] = {
        let places: [PrivacyPlace] = [.onDevice, .mayLeaveDevice]
        for place in places {
            switch place {
            case .onDevice, .mayLeaveDevice: break
            }
        }
        return places
    }()

    /// The cloud setting's off line is linted for every place: no dash, and
    /// a device promise only where the place keeps it.
    @Test func theOffDetailIsLintedForEveryPlace() {
        #expect(Set(Self.everyPlace).count == 2)
        for place in Self.everyPlace {
            let line = CloudWords.offDetail(place)
            #expect(!line.contains(where: CopyDashTests.dashes.contains), "dash in: \(line)")
            #expect(Self.promisesTheDevice(line) == place.staysOnDevice, "\(place): \(line)")
        }
    }

    /// Each device line, as the copy builds it for a place.
    static func deviceLines(_ place: PrivacyPlace) -> [String] {
        [
            MemoryWords.empty(place),
            MemoryWords.saved(place),
            MemoryWords.privacyNote(place),
            FirstConversation.presence(place),
            FirstConversation.opening(named: "Pip", place: place),
            FirstRunWords.helloDetail(place),
            FeedWords.sampleNote(place),
            CloudWords.offDetail(place),
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
