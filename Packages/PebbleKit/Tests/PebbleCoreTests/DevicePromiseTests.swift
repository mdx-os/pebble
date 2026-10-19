import Foundation
import PebbleCore
import PromiseWords
import SourceScan
import Testing

/// PERMANENT GUARD. No word a person sees promises the device or privacy
/// unless `PrivacyPlace` decides it, or it is allowed in `DevicePromise`
/// with a written reason. Here, every line in the copy lists the other
/// tests keep, and every word outside Swift. The sweep of every string
/// literal in the package sources and the app reads Swift, so it lives in
/// Tools/GuardKit (`DevicePromiseSweepTests`), with what each rule must
/// catch (`GuardWrongCaseTests`).
struct DevicePromiseTests {
    /// Every line the copy lists allow, and every line built around one,
    /// has its entry with the reason, so the list never lets a line by
    /// without saying why.
    @Test func everyAllowedLineHasAReason() {
        for line in DevicePromise.allowedLines {
            #expect(DevicePromise.allowed.contains { line == $0.literal }, "no reason given for: \(line)")
        }
        for built in DevicePromise.allowedBuiltLines {
            #expect(DevicePromise.allowed.contains { built.literal == $0.literal }, "no reason given for: \(built.literal)")
            #expect(built.line.contains(built.literal), "\(built.line) is not built from \(built.literal)")
            let added = built.line.replacingOccurrences(of: built.literal, with: "")
            #expect(DevicePromise.found(in: added).isEmpty, "\(built.line) adds a promise of its own")
        }
    }

    /// Every line the copy lists hold: the gated lines on the device, the
    /// allowed ones, and nothing else, may promise the device.
    @Test func everyCopyListLineIsGatedOrAllowed() {
        let gated = Set(PrivacyPlaceTests.deviceLines(.onDevice))
        let lines = CopyDashTests.copy + FeedWords.all + PrivacyPlaceTests.deviceLines(.onDevice)
            + PrivacyPlaceTests.deviceLines(.mayLeaveDevice) + Self.sampleFeedWords
        #expect(lines.count > 100)
        for line in lines where !DevicePromise.found(in: line).isEmpty {
            #expect(gated.contains(line) || DevicePromise.allowedLines.contains(line)
                        || DevicePromise.allowedBuiltLines.contains { $0.line == line },
                    "promises \(DevicePromise.found(in: line)) without PrivacyPlace: \(line)")
        }
    }

    /// Off the device, no gated line promises anything but what is allowed.
    @Test func offTheDeviceTheGatedLinesPromiseNothing() {
        for line in PrivacyPlaceTests.deviceLines(.mayLeaveDevice) {
            #expect(DevicePromise.found(in: line).isEmpty || DevicePromise.allowedLines.contains(line),
                    "promises \(DevicePromise.found(in: line)): \(line)")
        }
    }

    static var sampleFeedWords: [String] {
        SampleFeedSource().items(now: Date()).flatMap { item -> [String] in
            var words = [item.title, item.body]
            if case .open(let text) = item.action { words.append(text) }
            if case .talk(let text) = item.action { words.append(text) }
            return words
        }
    }

    /// The line said when the cloud was turned off mid chat can't read the
    /// next chat's place, so it promises nothing about the device or the
    /// cloud. Its one phrase is the setting's name, allowed with that
    /// reason, and with the name taken out no phrase is left.
    @Test func theTurnedOffLinePromisesNothing() {
        #expect(DevicePromise.found(in: CloudWords.turnedOff) == ["cloud"])
        #expect(CloudWords.turnedOff.hasPrefix(CloudWords.title))
        let rest = CloudWords.turnedOff.replacingOccurrences(of: CloudWords.title, with: "")
        #expect(DevicePromise.found(in: rest).isEmpty, "more than the setting's name: \(rest)")
        let entry = DevicePromise.allowed.first { $0.literal == CloudWords.turnedOff }
        #expect(entry?.reason.hasPrefix(DevicePromise.cloudSettingName) == true)
    }

    /// How a line is read for phrases: case, line breaks, curly apostrophes
    /// and invisible characters aside.
    @Test func phrasesAreReadAsAPersonReadsThem() {
        #expect(DevicePromise.found(in: "only one").isEmpty)
        #expect(!DevicePromise.found(in: "Kept ONLY on this device").isEmpty)
        #expect(DevicePromise.found(in: "Kept on this\n    device") == ["this device", "on this device"])
        #expect(DevicePromise.found(in: #"never\u{0020}leaves"#) == ["never leaves"])
        #expect(DevicePromise.found(in: "It doesn\u{2019}t leave") == ["doesn't leave"])
        #expect(DevicePromise.found(in: "never\u{200B}leaves") == ["never leaves"])
        #expect(DevicePromise.found(in: "never\u{2060}leaves") == ["never leaves"])
        #expect(DevicePromise.found(in: "pri\u{200B}vate") == ["private"])
        #expect(DevicePromise.found(in: "on\u{2011}device") == ["on-device"])
    }

    /// The summaries status lines that promise nothing need no entry.
    @Test func theSummaryLinesThatPromiseNothingNeedNoEntry() {
        for line in MemoryWords.couldNotForgetSummariesLines + [MemoryWords.summariesGone, MemoryWords.summariesStayed] {
            #expect(DevicePromise.found(in: line).isEmpty, "\(line)")
            #expect(!DevicePromise.allowed.contains { $0.literal == line })
        }
    }

    // MARK: Words outside Swift

    /// A line in the app's Info.plist, project.yml's info for it, or a
    /// strings catalog, where usage descriptions such as "stays on your
    /// device" usually live, that the guard lets by, and why.
    struct AllowedResource {
        let file: String
        let text: String
        let reason: String
    }

    /// Each is a promise true whatever the model is, or no words a person
    /// sees.
    static let allowedResources: [AllowedResource] = [
        AllowedResource(file: "project.yml",
                        text: "        # Empty unless set in Config/Cloud.xcconfig. Empty means no cloud model.",
                        reason: "A YAML comment beside the cloud address setting. It never reaches the plist or "
                            + "the screen, and it says when there is no cloud model, not where words go."),
    ]

    /// Every word a person can see that lives outside Swift: each string in
    /// `App/Info.plist`, each line of project.yml (its `info:` properties
    /// and `INFOPLIST_KEY_` settings become the plist), and each line of a
    /// `.strings`, `.stringsdict` or `.xcstrings` file in the app or the
    /// package sources.
    static func resourceLines() throws -> [(file: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        var lines: [(String, String)] = []
        let plist = try Data(contentsOf: root.appendingPathComponent("App/Info.plist"))
        lines += try plistStrings(plist).map { ("App/Info.plist", $0) }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        lines += project.split(separator: "\n").map { ("project.yml", String($0)) }
        for folder in ["App", "Packages/PebbleKit/Sources"] {
            let base = root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where ["strings", "stringsdict", "xcstrings"].contains(url.pathExtension) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = folder + "/" + url.lastPathComponent
                lines += text.split(separator: "\n").map { (name, String($0)) }
            }
        }
        return lines
    }

    /// Every string value in a property list, nested ones too.
    static func plistStrings(_ data: Data) throws -> [String] {
        func strings(in value: Any) -> [String] {
            switch value {
            case let text as String: return [text]
            case let list as [Any]: return list.flatMap(strings)
            case let table as [String: Any]: return table.keys.sorted().flatMap { strings(in: table[$0]!) }
            default: return []
            }
        }
        return strings(in: try PropertyListSerialization.propertyList(from: data, format: nil))
    }

    @Test func noWordsOutsideSwiftPromiseTheDevice() throws {
        let lines = try Self.resourceLines()
        #expect(lines.contains { $0.file == "App/Info.plist" }, "the app's Info.plist is read")
        #expect(lines.contains { $0.file == "project.yml" }, "project.yml is read")
        for line in lines where !DevicePromise.found(in: line.text).isEmpty {
            let allowed = Self.allowedResources.contains { $0.file == line.file && $0.text == line.text }
            #expect(allowed, "\(line.file): \"\(line.text)\" promises \(DevicePromise.found(in: line.text)) without PrivacyPlace")
        }
        for entry in Self.allowedResources {
            #expect(entry.reason.count > 40, "\(entry.file): say why")
            #expect(lines.contains { $0.file == entry.file && $0.text == entry.text }, "no longer in \(entry.file): \(entry.text)")
        }
    }

    /// The sweep sees a usage description, the place such a promise
    /// usually hides.
    @Test func theResourceSweepWouldCatchAUsageDescription() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>NSMicrophoneUsageDescription</key><string>Your voice stays on this device.</string>
            <key>Nested</key><dict><key>NSSpeechRecognitionUsageDescription</key><string>Nothing is sent anywhere.</string></dict>
            </dict></plist>
            """
        let found = try Self.plistStrings(Data(plist.utf8)).filter { !DevicePromise.found(in: $0).isEmpty }
        #expect(found.count == 2)
    }
}
