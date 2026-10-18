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
            ReconWords.offer("the pool", examples: true, place: place),
            ReconWords.rememberDetail(place),
            CloudWords.offDetail(place),
        ]
    }

    /// Reads the one phrase list, `DevicePromise.phrases`. A line allowed
    /// with a written reason there, or built around one, is not a promise
    /// about the device.
    static func promisesTheDevice(_ line: String) -> Bool {
        !DevicePromise.found(in: line).isEmpty && !DevicePromise.allowedLines.contains(line)
            && !DevicePromise.allowedBuiltLines.contains { $0.line == line }
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
        #expect(ReconWords.offer("the pool", examples: true, place: .mayLeaveDevice).contains("example pages"))
        #expect(ReconWords.rememberDetail(.mayLeaveDevice).contains("where it came from"))
        // A kept point goes with Forget everything, and both lines say so.
        #expect(ReconWords.rememberDetail(.mayLeaveDevice)
            == "I'll keep it in your notes with where it came from. It's still there after this card goes, until you delete it or forget everything.")
        #expect(ReconWords.rememberDetail(.onDevice)
            == "I'll keep it in your notes with where it came from. It's still there after this card goes, until you delete it or forget everything. Notes stay on this device.")
    }

    /// Lines shown only after the cloud was asked name the cloud, never the
    /// device. "Without the cloud" says what was not used, not where words go.
    @Test func reconsCloudLinesNeverPromiseTheDevice() {
        for line in [ReconWords.declinedCloud, ReconWords.cloudUnreadable, ReconWords.cloudUnavailable,
                     ReconWords.cloudWithdrawn, ReconWords.offer("the pool"), ReconWords.wordedInCloud,
                     ReconWords.forgotWhileInCloud, ReconWords.alreadyOn, ReconWords.alreadyReady,
                     ReconWords.alreadyOnWithCloud, ReconWords.cloudOff, ReconWords.cloudStopped,
                     ReconWords.keptForCare,
                     ReconWords.memoryNote("The pool opens.", from: ["A"], wordedInCloud: true)] {
            #expect(!Self.promisesTheDevice(line), "device promise in: \(line)")
        }
        #expect(ReconWords.all.contains(ReconWords.cloudWithdrawn))
    }

    @Test func theFlagReadsBothWays() {
        #expect(PrivacyPlace(staysOnDevice: true) == .onDevice)
        #expect(PrivacyPlace(staysOnDevice: false) == .mayLeaveDevice)
        #expect(PrivacyPlace.onDevice.staysOnDevice)
        #expect(!PrivacyPlace.mayLeaveDevice.staysOnDevice)
    }
}
