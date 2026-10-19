import Foundation
import GuardScan
import PromiseWords
import Testing

/// One snippet a guard must flag, the file it is read as, and the rule
/// that must be the one to flag it.
struct WrongCase {
    let rule: String
    let text: String
    var file: String
}

/// One snippet a guard must let by, read as `file`. With `only`, just
/// those rules must stay quiet, for a snippet another rule rightly flags.
struct RightCase {
    let text: String
    var file: String
    var only: Set<String>? = nil
}

/// PERMANENT GUARD. The wrong cases every source guard must catch: the
/// privacy promise guard, the contrast guard, the accent guard (orange only
/// where it belongs) and the platform gate. Each case names the rule that
/// catches it, so a rule that stops catching any case, or is turned off,
/// fails here. Every hole a review has found is a case: `#if !os(macOS)`,
/// `os(macOS) || os(iOS)`, code after a closed `#Preview`, `\u{0020}`, `+`
/// joins, multi-line literals and raw strings among them.
struct GuardWrongCaseTests {
    // MARK: The privacy promise guard

    static func promise(_ rule: String, _ text: String, file: String = "PebbleUI/Wrong.swift") -> WrongCase {
        WrongCase(rule: "promise." + rule, text: text, file: file)
    }

    static func words(_ text: String) -> WrongCase { promise("phrase", text, file: "PebbleCore/Wrong.swift") }

    static let promiseWrong: [WrongCase] = [
        words(#"public static let note = "Your notes stay on this device.""#),
        words(#"let line = onDevice ? "Here with you." : "Kept only on this device.""#),
        words("let detail = \"\"\"\n    Everything here is private.\n    \"\"\""),
        words(#"Text("Nothing was sent.")"#),
        words(#"static let x = "It never leaves your phone.""#),
        // The flag turned around, or only part of the condition.
        words(#"let line = !place.staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = (!place.staysOnDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = !(place.staysOnDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = isRemote || (place.staysOnDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = isRemote && (place.staysOnDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = isRemote && place.staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = flipped(place.staysOnDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = wasLocal == place.staysOnDevice ? "It stays on this device." : "Hi.""#),
        words("let line = isRemote ||\n    place.staysOnDevice\n    ? \"It stays on this device.\"\n    : \"Hi.\""),
        // The false branch is never gated, nor words inside a call in the true one.
        words(#"let line = place.staysOnDevice ? "Hi." : "It stays on this device.""#),
        words(#"let line = place.staysOnDevice ? f("It stays on this device.") : "Hi.""#),
        // A Bool of its own never gates, whatever it is called, since
        // nothing ties it to the flag.
        words("let onDevice = !place.staysOnDevice\nlet line = onDevice ? \"It stays on this device.\" : \"Hi.\""),
        words(#"let line = onDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = (onDevice) ? "It stays on this device." : "Hi.""#),
        words(#"let line = staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = !staysOnDevice ? "It stays on this device." : "Hi.""#),
        // Only the place's own receivers gate: never a call's result or
        // some other value's flag.
        words(#"let line = flipped().staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = other.place.staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = settings.staysOnDevice ? "It stays on this device." : "Hi.""#),
        words(#"let line = PrivacyPlace.onDevice.staysOnDevice ? "It stays on this device." : "Hi.""#),
        // The newer phrases.
        words(#"Text("Your privacy comes first.")"#),
        words(#"static let x = "It's all on this Mac.""#),
        words(#"static let x = "Only you can read this.""#),
        words(#"static let x = "Your words are encrypted and secure.""#),
        words(#"static let x = "It works offline, and what you say isn't sent.""#),
        words(#"static let x = "Your words are never sent anywhere.""#),
        words(#"static let x = "Nothing leaves your iPhone.""#),
        words(#"static let x = "It all stays with your iPad.""#),
        words(#"static let x = "No cloud, no server, no upload.""#),
        words(#"static let x = "Your notes are uploaded to our servers.""#),
        // Wrapped over the lines of a multi-line literal, or split by an
        // escape, a phrase is still one phrase.
        words("let detail = \"\"\"\n    What you say never\n    leaves your phone.\n    \"\"\""),
        words("let detail = \"\"\"\n    It's all kept on this\n        Mac.\n    \"\"\""),
        words("let detail = \"\"\"\n    Your words stay \\\n    on your Mac.\n    \"\"\""),
        words(#"static let x = "Only\nyou can read it.""#),
        words(#"static let x = "It runs on this\ndevice.""#),
        words(#"static let x = "Nothing\tleaves.""#),
        words(#"static let x = "It never\u{0020}leaves.""#),
        words(#"static let x = "Only\u{A}you can read it.""#),
        // Raw strings, with their own escapes.
        words(##"static let x = #"It never leaves."#"##),
        words(##"static let x = #"It never\#u{0020}leaves."#"##),
        words(##"static let x = #"It never\#nleaves."#"##),
        words("let detail = #\"\"\"\n    Kept only\n    on this Mac.\n    \"\"\"#"),
        // A curly apostrophe, written or escaped, reads as a plain one.
        words("static let x = \"It doesn\u{2019}t leave your phone.\""),
        words(#"static let x = "It won\u{2019}t leave.""#),
        // Zero-width space and word joiner: a gap, or nothing at all.
        words(#"static let x = "It never\u{200B}leaves.""#),
        words(#"static let x = "Kept on\u{2060}this Mac.""#),
        words(#"static let x = "Your pri\u{200B}vacy matters.""#),
        // Split into literals joined with +, a phrase is still one phrase.
        words(#"static let x = "It never " + "leaves.""#),
        words("static let x = \"Your words stay on this \"\n    + \"device.\""),
        words(#"static let x = "Kept on " + /* here */ "this Mac.""#),
        words(#"static let x = "It never " + ("leaves.")"#),
        words(#"static let x = name + "It never " + "leaves.""#),
        // Words in an interpolation are words too.
        words(#"static let x = "\(flag ? "It never leaves." : "")""#),

        // Any type with a staysOnDevice of its own would pass the gate.
        promise("staysOnDeviceDeclared", "struct Identity { let staysOnDevice: Bool }"),
        promise("staysOnDeviceDeclared", "extension Settings { var staysOnDevice: Bool { true } }"),
        promise("staysOnDeviceDeclared", "struct Wrapper { func staysOnDevice() -> Bool { false } }"),
        // A case or label called staysOnDevice is a staysOnDevice too.
        promise("staysOnDeviceDeclared", "enum Where { case a, staysOnDevice }"),
        promise("staysOnDeviceDeclared", "enum Where {\n    case here,\n        staysOnDevice\n}"),
        promise("staysOnDeviceDeclared", "let identity: (kind: String, staysOnDevice: Bool)"),
        promise("staysOnDeviceDeclared", "func f(staysOnDevice: Bool) {}"),
        promise("staysOnDeviceDeclared", "let (name, staysOnDevice) = pair"),
        promise("staysOnDeviceDeclared", "let place: PrivacyPlace = .init(staysOnDevice: true)"),
        promise("staysOnDeviceDeclared", "public var staysOnDevice: Bool { self == .onDevice }", file: "PebbleCore/Other.swift"),
        // In backticks, a name is the same name.
        promise("staysOnDeviceDeclared", "struct Identity { var `staysOnDevice`: Bool }"),
        promise("staysOnDeviceDeclared", "func `staysOnDevice`() -> Bool { true }"),
        // A type that answers any member could answer staysOnDevice unseen.
        promise("dynamicLookup", "@dynamicMemberLookup\nstruct Settings {\n"
                + "    subscript(dynamicMember name: String) -> Bool { true }\n}\nlet line = settings.staysOnDevice"),
        promise("dynamicLookup", "@dynamicMemberLookup final class Box {}"),
        // A place made anywhere but the model.
        promise("placeMade", "let place = PrivacyPlace(staysOnDevice: !model.runsOnDevice)"),
        promise("placeMade", "let place: PrivacyPlace = .init(staysOnDevice: true)"),
        promise("placeMade", "let place = PrivacyPlace.init(staysOnDevice: true)"),
        promise("placeMade", "let place = PebbleCore.PrivacyPlace(staysOnDevice: true)"),
        promise("placeMade", "let place = `PrivacyPlace`(`staysOnDevice`: true)"),
        promise("placeMade", "var privacyPlace: PrivacyPlace { PrivacyPlace(staysOnDevice: runsOnDevice) }",
                file: "PebbleUI/Other.swift"),
        // A Bool called onDevice, kept, computed, passed or set.
        promise("onDeviceBool", "let onDevice = !place.staysOnDevice"),
        promise("onDeviceBool", "let onDevice = true"),
        promise("onDeviceBool", "f(onDevice: !place.staysOnDevice)"),
        promise("onDeviceBool", "f(onDevice: model.runsOnDevice)"),
        promise("onDeviceBool", "init(onDevice: Bool = false) {}"),
        promise("onDeviceBool", "var onDevice: Bool { !place.staysOnDevice }"),
        promise("onDeviceBool", "var onDevice: Bool { true }"),
        promise("onDeviceBool", "var onDevice: Bool {\n    get { !place.staysOnDevice }\n}"),
        promise("onDeviceBool", "func onDevice() -> Bool { true }"),
        promise("onDeviceBool", "static func onDevice() -> Bool { !place.staysOnDevice }"),
        promise("onDeviceBool", "var onDevice: Bool"),
        promise("onDeviceBool", "onDevice = !place.staysOnDevice"),
        promise("onDeviceBool", "self.onDevice = flag"),
        promise("onDeviceBool", "let pair = (name: \"a\", onDevice: true)"),
        promise("onDeviceBool", "let `onDevice` = !place.staysOnDevice"),
        promise("onDeviceBool", "f(`onDevice`: true)"),
        // The place written out, rather than taken from the model.
        promise("placeWritten", "let place: PrivacyPlace = .onDevice"),
        promise("placeWritten", "let place = PrivacyPlace.onDevice"),
        promise("placeWritten", "let x = flag ? .onDevice : .mayLeaveDevice"),
        promise("placeWritten", "let x = flag ? PrivacyPlace.mayLeaveDevice : .onDevice"),
        promise("placeWritten", "f(place: .onDevice)"),
        promise("placeWritten", "f(place: isRemote ? .mayLeaveDevice : model.privacyPlace)"),
        promise("placeWritten", "switch place { case .onDevice: return true default: return false }"),
        promise("placeWritten", "if case .onDevice = place { return }"),
        promise("placeWritten", "typealias Place = PrivacyPlace\nlet place = Place.onDevice"),
        promise("placeWritten", "let place = type(of: model.privacyPlace).onDevice"),
        promise("placeWritten", "let kind = PrivacyPlace.self\nlet place = kind.onDevice"),
        promise("placeWritten", "public static let place = PrivacyPlace.mayLeaveDevice", file: "PebbleUI/Other.swift"),
        promise("placeWritten", "public static let place = PrivacyPlace.onDevice", file: "PebbleModel/CloudModel.swift"),
        promise("placeWritten", "let place: PrivacyPlace = .`onDevice`"),
        promise("placeWritten", "let place = `PrivacyPlace`.`onDevice`"),
        promise("placeWritten", "if case .`onDevice` = place { return }"),
        // The place under another name.
        promise("placeAlias", "typealias Place = PrivacyPlace\nlet place = Place.onDevice"),
        promise("placeAlias", "typealias Place = PebbleCore.PrivacyPlace"),
        promise("placeAlias", "typealias Places = [PrivacyPlace]"),
        promise("placeAlias", "typealias Pair = (Int,\n    PrivacyPlace)"),
        // A place made of no places, which would read as on the device.
        promise("emptyAll", "let place = PrivacyPlace.all()"),
        promise("emptyAll", "let place = PrivacyPlace\n    .all( )"),
        promise("emptyAll", "f(place: .all())"),
        // A stand-in model made by a screen, whose place reads as the device.
        promise("stubMade", "MemoryView(store: store, place: LocalStubModel().privacyPlace)"),
        promise("stubMade", "init(model: any ModelClient = LocalStubModel()) {}"),
        promise("stubMade", "let model = LocalStubModel\n    .init()"),
        promise("stubMade", "let make = LocalStubModel.init"),
        promise("stubMade", "HomeView(brand: brand, model: LocalStubModel())", file: "PebbleUI/HomeView.swift"),
        promise("stubMade", "#Preview { Text(\"a\") }\nlet model = LocalStubModel()"),
        // A preview's scope ends at its own closing brace, whatever opens after it.
        promise("stubMade", "#Preview { Text(\"a\") }\nstruct Screen: View {\n    var body: some View {\n"
                + "        Text(LocalStubModel().privacyPlace.staysOnDevice ? \"a\" : \"b\")\n    }\n}"),
        // Named as a type, its metatype taken, qualified, in backticks, or
        // extended, it can be made with no call to its name.
        promise("stubMade", "let model: LocalStubModel = .init()"),
        promise("stubMade", "let models: [LocalStubModel] = [.init()]"),
        promise("stubMade", "let made = Maker<LocalStubModel>().make()"),
        promise("stubMade", "func screen(model: LocalStubModel) {}"),
        promise("stubMade", "typealias Stand = LocalStubModel"),
        promise("stubMade", "let model = LocalStubModel.self.init()"),
        promise("stubMade", "let kind = LocalStubModel.self"),
        promise("stubMade", "let kind: LocalStubModel.Type = type(of: other)"),
        promise("stubMade", "let model = PebbleModel.LocalStubModel()"),
        promise("stubMade", "let model: PebbleModel.LocalStubModel = .init()"),
        promise("stubMade", "let model = `LocalStubModel`()"),
        promise("stubMade", "extension LocalStubModel { static let shared = Self() }"),
        promise("stubMade", "extension PebbleModel.LocalStubModel {}"),
        promise("stubMade", "#Preview { Text(\"a\") }\nextension LocalStubModel { static let shared = Self() }"),

        // A model made anywhere but the model layer.
        promise("modelMade", "struct Here: ModelClient { var runsOnDevice: Bool { true } }"),
        promise("modelMade", "final class Here: NSObject, ModelClient {\n    var runsOnDevice: Bool { true }\n}"),
        promise("modelMade", "extension Settings: ModelClient { var runsOnDevice: Bool { true } }"),
        promise("modelMade", "actor Here: Sendable,\n    PebbleModel.ModelClient {}"),
        promise("modelMade", "struct Box<T>: ModelClient {}"),
        promise("modelMade", "protocol Local: ModelClient {}"),
        promise("modelMade", "extension ModelClient { var runsOnDevice: Bool { true } }"),
        promise("modelMade", "struct Here: Sendable & ModelClient {}"),
        promise("modelMade", "struct Here: `ModelClient` {}"),
        // The model under another name, alone or in a composition.
        promise("modelAlias", "typealias Local = Sendable & ModelClient\nstruct Here: Local { var runsOnDevice: Bool { true } }"),
        promise("modelAlias", "typealias Local = ModelClient"),
        promise("modelAlias", "typealias Local = PebbleModel.ModelClient"),
        promise("modelAlias", "typealias Local = Sendable &\n    ModelClient"),
        promise("modelAlias", "typealias Local = Sendable\n    & ModelClient"),
        // A model maker's own models are closed to subclasses.
        promise("makerKind", "public class LocalStubModel: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "class CloudModel: @unchecked Sendable, ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "open class Base: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "public open class Base: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "@MainActor public class Base: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "public protocol LocalModel: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        promise("makerKind", "extension NSObject: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        // Nothing extends the place, its own file included.
        promise("placeExtension", "extension PrivacyPlace { static var here: PrivacyPlace { onDevice } }"),
        promise("placeExtension", "extension PebbleCore.PrivacyPlace {}"),
        promise("placeExtension", "extension PrivacyPlace: CaseIterable {}"),
        promise("placeExtension", "extension PrivacyPlace\n    : Codable {}"),
        promise("placeExtension", "public extension PrivacyPlace where Self == PrivacyPlace {}"),
        promise("placeExtension", "extension PrivacyPlace { static var here: PrivacyPlace { onDevice } }",
                file: "PebbleCore/PrivacyPlace.swift"),
        promise("placeExtension", "extension PrivacyPlace: CaseIterable {}", file: "PebbleCore/PrivacyPlace.swift"),
        promise("placeExtension", "extension `PrivacyPlace` {}"),
    ] + placeMinted.map { promise("placeMember", placeOpen + $0, file: "PebbleCore/PrivacyPlace.swift") }

    static let placeOpen = "public enum PrivacyPlace: Sendable, Hashable {\n    case onDevice\n    case mayLeaveDevice\n"

    /// Members that would hand out a place under a name nothing checks.
    static let placeMinted = [
        "    public static var here: PrivacyPlace { .onDevice }\n}",
        "    public static let here = onDevice\n}",
        "    public static func make() -> Self { .onDevice }\n}",
        "    public init() { self = .onDevice }\n}",
        "    public init?(_ text: String) { self = .onDevice }\n}",
        "    public init(staysOnDevice: Bool, really: Bool) { self = .onDevice }\n}",
        "    case here\n}",
        "    case here, there\n}",
        "    public subscript(_ index: Int) -> PrivacyPlace { .onDevice }\n}",
        "}\npublic enum Places { public static let here = PrivacyPlace.onDevice }",
        "}\nextension PrivacyPlace { static var here: PrivacyPlace { onDevice } }",
    ]

    static func fine(_ text: String, file: String = "PebbleUI/Right.swift", only: Set<String>? = nil) -> RightCase {
        RightCase(text: text, file: file, only: only)
    }

    static func fineWords(_ text: String) -> RightCase { fine(text, file: "PebbleCore/Right.swift") }

    static let promiseRight: [RightCase] = [
        fineWords(#"place.staysOnDevice ? "Saved. It stays on this device." : "Saved.""#),
        fineWords("place.staysOnDevice\n    ? \"I run on this device.\"\n    : \"Hi.\""),
        fineWords(#"return (place.staysOnDevice) ? "I run on this device." : "Hi.""#),
        fineWords(#"return model.privacyPlace.staysOnDevice ? "I run on this device." : "Hi.""#),
        fineWords(#"return privacyPlace.staysOnDevice ? "I run on this device." : "Hi.""#),
        fineWords(#"Text(place.staysOnDevice ? "Kept only on this device." : "Kept.")"#),
        fineWords(#"Text((place.staysOnDevice) ? "Kept only on this device." : "Kept.")"#),
        fineWords(#"let line = ((place.staysOnDevice) ? "I run on this device." : "Hi.")"#),
        fineWords(#"let line = place.staysOnDevice ? ("I run on this device.") : "Hi.""#),
        fineWords("func f() -> String {\n    self.place.staysOnDevice\n        ? \"It stays on this device.\"\n        : \"Hi.\"\n}"),
        fineWords(#"// Says "on this device" only when the flag says so."#),
        fineWords("/* \"stays on this device\" */"),
        fineWords(#"static let x = "Only one note at a time.""#),
        fineWords(#"place.staysOnDevice ? "It stays on " + "this device." : "Hi.""#),
        fineWords(#"place.staysOnDevice ? "It stays " + ("on this device.") : "Hi.""#),
        fineWords(#"let x = "Only " + name + " leaves.""#),
        fineWords(#"let x = "\(place.staysOnDevice ? "It stays on this device." : "")""#),
        // The place, read and passed as the model gives it.
        fine("let place: PrivacyPlace"),
        fine("let place = model.privacyPlace"),
        fine("f(place: model.privacyPlace, onDevice: model.privacyPlace.staysOnDevice)"),
        fine("// var staysOnDevice: Bool, in a comment"),
        fine("let note = \"staysOnDevice and .onDevice, in words\""),
        fine("if place.staysOnDevice && !model.privacyPlace.staysOnDevice { throw Oops.leaves }"),
        fine("let x = place\n    .staysOnDevice"),
        fine("let flags = places.map(\\.staysOnDevice)"),
        fine("public init(turns: [ChatTurn], place: PrivacyPlace = .mayLeaveDevice) {}"),
        fine("let store = try? MemoryStore.onDevice()"),
        fine("public static func onDevice(fileManager: FileManager = .default) throws -> MemoryStore { try make() }"),
        fine("var onDevice: Bool { place.staysOnDevice }"),
        fine("let onDevice = self.place.staysOnDevice"),
        fine("let place = PrivacyPlace.all(chat.privacyPlace, model.privacyPlace)"),
        fine("let lines = CloudWords.all()"),
        fine("let reply = (try? LocalStubModel.answer(to: turns)) ?? LocalStubModel.fallback"),
        fine("typealias RGB = Contrast.RGB"),
        fine("typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)"),
        fine("let store = try CloudHelpFileStore.onDevice()"),
        fine("#Preview {\n    ChatView(brand: brand, model: LocalStubModel())\n}"),
        fine("#Preview { Text(\"a\") }\n#Preview(\"Chat\") {\n    VStack {\n        ChatView(brand: brand, model: LocalStubModel())\n    }\n}"),
        fine("#Preview {\n    let model: LocalStubModel = .init()\n    ChatView(brand: brand, model: model)\n}"),
        fine("let line = LocalStubModel.fallback"),
        // Each exemption holds in its own file.
        fine("var privacyPlace: PrivacyPlace { PrivacyPlace(staysOnDevice: runsOnDevice) }", file: "PebbleModel/ModelClient.swift"),
        fine("public static let place = PrivacyPlace.mayLeaveDevice", file: "PebbleModel/CloudModel.swift"),
        fine("public var staysOnDevice: Bool { self == .onDevice }", file: "PebbleCore/PrivacyPlace.swift"),
        fine(placeOpen + "    public init(staysOnDevice: Bool) { self = staysOnDevice ? .onDevice : .mayLeaveDevice }\n"
             + "    public var staysOnDevice: Bool { self == .onDevice }\n"
             + "    public static func all(_ first: PrivacyPlace, _ rest: PrivacyPlace...) -> PrivacyPlace { first }\n}",
             file: "PebbleCore/PrivacyPlace.swift"),
        // Pinned in its own file; elsewhere the reads above see .onDevice.
        fine(placeOpen + placeMinted[0], file: "PebbleCore/Other.swift", only: ["promise.placeMember"]),
        // The model, used rather than made.
        fine("let model: any ModelClient"),
        fine("init(model: any ModelClient) {}"),
        fine("struct Screen: View {\n    let model: any ModelClient\n}"),
        fine("func reply<M: ModelClient>(from model: M) {}"),
        fine("// struct Here: ModelClient, in a comment"),
        fine("let note = \"extension Here: ModelClient\""),
        fine("typealias Local = Sendable\nlet model: any ModelClient"),
        fine("public struct LocalStubModel: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("public typealias Local = Sendable & ModelClient", file: "PebbleModel/ModelClient.swift"),
        fine("public final class Stub: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("@MainActor public final class Stub: Sendable, ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("final public class Stub: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("public actor Stub: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("enum Stub: ModelClient {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("public protocol ModelClient: Sendable {}", file: "PebbleModel/LocalStubModel.swift"),
        fine("extension ModelClient { var privacyPlace: PrivacyPlace { .mayLeaveDevice } }", file: "PebbleModel/LocalStubModel.swift",
             only: ["promise.makerKind"]),
        fine("extension PrivacyPlaceTests {}"),
        fine("// extension PrivacyPlace {}"),
        // The stub's own makers, written out here rather than read from
        // `stubMakers`, so a file added there is a change this suite sees.
        fine("HomeView(brand: brand, model: LocalStubModel())", file: "App/Sources/PebbleApp.swift"),
        fine("HomeView(brand: brand, model: LocalStubModel())", file: "PebbleUI/ShowcaseScene.swift"),
        fine("HomeView(brand: brand, model: LocalStubModel())", file: "PebbleModel/LocalStubModel.swift"),
        fine("let model: LocalStubModel = .init()", file: "App/Sources/PebbleApp.swift"),
        fine("extension LocalStubModel { static let shared = Self() }", file: "PebbleModel/LocalStubModel.swift"),
    ]

    /// The files exempt from the stub rule, exactly. A file added to the
    /// exemption fails here until it is written into this list too.
    static let expectedStubMakers: Set<String> = [
        "App/Sources/PebbleApp.swift",
        "PebbleUI/ShowcaseScene.swift",
        "PebbleModel/LocalStubModel.swift",
    ]

    @Test func thePromiseGuardCatchesEveryWrongCase() {
        #expect(PromiseRules.stubMakers == Self.expectedStubMakers)
        check(Self.promiseWrong, Self.promiseRight, rules: PromiseRules.allRuleNames) { DevicePromise.findings(in: $0, file: $1) }
    }

    // MARK: The contrast guard

    static func contrast(_ rule: String, _ text: String) -> WrongCase {
        WrongCase(rule: "contrast." + rule, text: text, file: "PebbleUI/Wrong.swift")
    }

    static let contrastWrong: [WrongCase] = [
        contrast("rawAccent", #"Text("Open").foregroundStyle(Theme.accent)"#),
        contrast("rawAccent", #".foregroundStyle(asks ? Theme.onAccent : Theme.accent)"#),
        contrast("rawAccent", #".foregroundColor(Theme.accent)"#),
        contrast("rawAccent", #".foregroundStyle(Theme . accent)"#),
        contrast("tint", #".tint(Theme.accent)"#),
        contrast("tint", #".tint(.orange)"#),
        contrast("orange", #".tint(.orange)"#),
        contrast("orange", #"Color.orange.opacity(0.18)"#),
        contrast("orange", #"let warm = flag ? .orange : Theme.accentText"#),
        contrast("bordered", #".buttonStyle(.bordered)"#),
        contrast("bordered", #".buttonStyle(.borderedProminent)"#),
        contrast("bordered", #".buttonStyle(BorderedProminentButtonStyle())"#),
        contrast("systemGray", #".foregroundStyle(.secondary)"#),
        contrast("systemGray", #".foregroundStyle(.tertiary)"#),
        contrast("systemGray", #".foregroundStyle(.quaternary)"#),
        contrast("systemGray", #".foregroundStyle(source == .inferred ? Color.primary : Color.secondary)"#),
        contrast("gray", #".foregroundStyle(.gray)"#),
        contrast("gray", #".foregroundStyle(Color.gray)"#),
        contrast("red", #".foregroundStyle(Color.red)"#),
        contrast("red", #".foregroundColor(.red)"#),
        // Off any type but Theme, a system color is still the system's.
        contrast("gray", #".foregroundStyle(Color(UIColor.gray))"#),
        contrast("gray", #".foregroundStyle(Color(nsColor: NSColor.gray))"#),
        contrast("red", #".foregroundStyle(Color(uiColor: UIColor.red))"#),
        contrast("systemGray", #".foregroundStyle(HierarchicalShapeStyle.secondary)"#),
        contrast("systemGray", #".foregroundStyle(ShapeStyle.tertiary)"#),
        contrast("systemGray", #".foregroundStyle(style.quaternary)"#),
        contrast("white", #".foregroundStyle(Theme.RGB.white.color)"#),
        contrast("surface", #".background(Color(UIColor.gray))"#),
        contrast("fadedWhite", #".foregroundStyle(.white.opacity(0.8))"#),
        contrast("fadedWhite", #".foregroundStyle(Color.white.opacity(0.7))"#),
        contrast("white", #".foregroundStyle(.white)"#),
        // White in a branch of the argument.
        contrast("white", #".foregroundStyle(flag ? .white : Theme.onAccent)"#),
        contrast("white", #".foregroundStyle(flag ? Theme.onAccent : Color.white)"#),
        contrast("surface", #".background(Color.gray, in: Capsule())"#),
        contrast("surface", #".fill(Color.red)"#),
        contrast("accentSymbol", "Text(\"Hi\")\n    .font(.body)\n    .foregroundStyle(Theme.accentSymbol)"),
        // An Image a few lines up, in another statement, is not this call's.
        contrast("accentSymbol", "Image(systemName: \"a\")\nText(\"Hi\").foregroundStyle(Theme.accentSymbol)"),
        // Wrapped onto the next line, the argument is still read.
        contrast("rawAccent", "Text(\"Open\")\n    .foregroundStyle(\n        Theme.accent\n    )"),
        contrast("rawAccent", "Text(\"Open\")\n    .foregroundStyle(asks\n        ? Theme.onAccent\n        : Theme.accent)"),
        contrast("tint", ".tint(\n    Theme.accent\n)"),
        contrast("fadedWhite", ".foregroundStyle(\n    .white.opacity(\n        0.8))"),
        // The call's paren on the next line is no call to Swift, but it
        // is still caught.
        contrast("splitCall", "Text(\"Open\")\n    .foregroundStyle\n    (Theme.accent)"),
        contrast("splitCall", ".tint\n(.orange)"),
        // In backticks, a name is the same name.
        contrast("gray", #".foregroundStyle(.`gray`)"#),
        contrast("rawAccent", #".foregroundStyle(Theme.`accent`)"#),
        contrast("rawAccent", #".`foregroundStyle`(`Theme`.accent)"#),
        contrast("white", #".foregroundStyle(Color.`white`)"#),
        contrast("orange", #"let warm = Color.`orange`"#),
        contrast("bordered", #".buttonStyle(.`bordered`)"#),
        // Theme qualified by its module is still Theme.
        contrast("rawAccent", #".foregroundStyle(PebbleUI.Theme.accent)"#),
        contrast("accentSymbol", "Text(\"Hi\").foregroundStyle(PebbleUI.Theme.accentSymbol)"),
    ]

    static let contrastRight: [RightCase] = [
        fine(#"Text("Open").foregroundStyle(Theme.accentText)"#),
        fine(#".foregroundStyle(Theme.secondaryText)"#),
        fine(#".background(Theme.accent, in: Capsule())"#),
        fine(#".tint(Theme.accentText)"#),
        fine("Image(systemName: \"sparkles\")\n    .font(.largeTitle)\n    .foregroundStyle(Theme.accentSymbol)"),
        fine("Image(systemName: \"a\")\n    .foregroundStyle(flag ? AnyShapeStyle(Theme.accentSymbol) : AnyShapeStyle(Theme.secondaryText))"),
        fine("Image(systemName: \"a\").foregroundStyle(Theme.accentSymbol.opacity(0.8))"),
        fine("// .foregroundStyle(Theme.accent) is wrong"),
        fine("/* .foregroundStyle(Theme.accent)\n   .tint(.orange) */"),
        fine("/* nested /* .foregroundStyle(.gray) */ still a comment .tint(.red) */"),
        fine(#"Text(".foregroundStyle(Theme.accent) and .orange")"#),
        fine("Text(\"\"\"\n    .foregroundStyle(.white)\n    \"\"\")"),
        fine(#"Text("\(name) .foregroundStyle(.secondary)")"#),
        fine("Image(systemName: \"bell.badge.fill\")"),
        fine("self.background = background\nif model.background != nil {}\nlet moment: Moment = .background"),
        fine(".background {\n    Theme.card\n}"),
        // Art, not words: the character's highlights.
        fine(#".fill(.white.opacity(0.35))"#),
        fine(#".foregroundStyle(Theme.white)"#),
        fine(#".foregroundStyle(PebbleUI.Theme.accentText)"#),
        fine(#".foregroundStyle(Theme.`secondaryText`)"#),
    ]

    /// Each right case here passes every rule, the accent rules too.
    @Test func theContrastGuardCatchesEveryWrongCase() {
        check(Self.contrastWrong, Self.contrastRight, rules: ContrastLint.contrastRules.map(\.name),
              quiet: ContrastLint.rules.map(\.name)) {
            ContrastLint.problems(in: $0, file: $1)
        }
    }

    // MARK: The accent guard: orange only where it belongs

    static func accent(_ rule: String, _ text: String) -> WrongCase {
        WrongCase(rule: "accent." + rule, text: text, file: "PebbleUI/Wrong.swift")
    }

    static func split(_ body: String) -> String { "struct HomeSplit: View {\n" + body + "\n}" }

    static let accentWrong: [WrongCase] = [
        // A confirmation button fills with the tint and writes in white.
        accent("confirmation", "ToolbarItem(placement: .confirmationAction) {\n    Button(\"Done\") { dismiss() }\n}"),
        // The next item's DoneButton doesn't count for this one.
        accent("confirmation", "ToolbarItem(placement: .confirmationAction) {\n    Button(\"Done\") { dismiss() }\n}\n"
               + "ToolbarItem(placement: .cancellationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)"),
        accent("confirmation", "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n"
               + "    Button { dismiss() } label: { Text(\"OK\") }\n}\n.sharedBackgroundVisibility(.hidden)"),
        // Done without hiding the toolbar's glass gets a ring around it,
        // whatever the placement, or with none.
        accent("doneRing", "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}"),
        accent("doneRing", "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.visible)"),
        accent("doneRing", "ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}"),
        accent("doneRing", "ToolbarItem(placement: .topBarTrailing) {\n    DoneButton { dismiss() }\n}"),
        accent("doneRing", "ToolbarItem(placement: .cancellationAction) {\n    DoneButton { dismiss() }\n}"),
        accent("doneRing", "ToolbarItem {\n    DoneButton { dismiss() }\n}"),
        // The hiding belongs to the item, not to something after it.
        accent("doneRing", "ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}\nText(\"a\")\n.sharedBackgroundVisibility(.hidden)"),
        // Done outside a ToolbarItem escapes both rules above.
        accent("doneInItem", "ToolbarItemGroup(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)"),
        accent("doneInItem", "ToolbarItemGroup {\n    DoneButton { dismiss() }\n}"),
        accent("doneInItem", ".toolbar {\n    DoneButton { dismiss() }\n}"),
        accent("doneInItem", "VStack {\n    DoneButton(title: \"Done\") { dismiss() }\n}"),
        accent("doneInItem", "ToolbarItem {\n    Text(\"a\")\n}\n.sharedBackgroundVisibility(.hidden)\nDoneButton { dismiss() }"),
        // The fill tint, anywhere but a fill.
        accent("tintFillTint", #"Text("Open").tint(Theme.tintFill)"#),
        accent("tintFillWords", #"Text("Open").foregroundStyle(Theme.tintFill)"#),
        accent("tintFillTint", "List { Text(\"a\") }\nText(\"b\").tint(Theme.tintFill)"),
        accent("tintFillTint", "struct DoneButton: View { var body: some View { Button(\"Done\") {} } }\n"
               + "struct Other: View { var body: some View { Text(\"x\").tint(Theme.tintFill) } }"),
        // After DoneButton's closing brace, or in a type inside it, is not DoneButton.
        accent("tintFillTint", "struct DoneButton: View { var body: some View { Button(\"Done\") {} } }\n"
               + "let other = Text(\"x\").tint(Theme.tintFill)"),
        accent("tintFillTint", "struct DoneButton: View {\n    struct Inner: View { var body: some View { Text(\"x\").tint(Theme.tintFill) } }\n}"),
        // The fill tint on any list but the sidebar's.
        accent("tintFillTint", "List(items) { item in\n    Button(item.title) {}\n}\n.tint(Theme.tintFill)"),
        accent("tintFillTint", "struct Other: View {\n    var body: some View {\n        List(selection: $picked) {\n            Text(\"a\")\n        }\n"
               + "        .tint(Theme.tintFill)\n    }\n}"),
        accent("tintFillTint", split("    var body: some View {\n        List {\n            Text(\"a\")\n        }\n        .tint(Theme.tintFill)\n    }")),
        accent("tintFillTint", split("    var body: some View { Text(\"a\") }") + "\n"
               + "let list = List(selection: $picked) { Text(\"a\") }.tint(Theme.tintFill)"),
        // White for words on the fill, anywhere the fill isn't under it.
        accent("onTintFill", #"Text("Open").foregroundStyle(Theme.onTintFill)"#),
        accent("onTintFill", "struct Card: View {\n    var body: some View {\n        Text(\"a\").foregroundStyle(Theme.onTintFill)\n"
               + "            .background(Theme.accent)\n    }\n}"),
        accent("onTintFill", split("    var body: some View {\n        Text(\"a\").foregroundStyle(Theme.onTintFill)\n    }")),
        accent("onTintFill", split("    var body: some View {\n"
               + "        Text(\"a\").foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.onTintFill))\n    }")),
        accent("onTintFill", split("    var body: some View {\n        Text(\"a\").tint(flag ? Theme.onTintFill : .primary)\n    }")),
        // A ternary styles every other row too, over their tinted icons.
        accent("onTintFill", split("    var body: some View {\n        HStack { Text(\"a\"); Text(\"3\") }\n"
               + "            .foregroundStyle(chosen ? AnyShapeStyle(Theme.onTintFill) : AnyShapeStyle(.primary))\n    }")),
        accent("onTintFill", split("    func ink() -> some View {\n        if !chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
               + "        }\n    }")),
        accent("onTintFill", split("    func ink() -> some View {\n        if chosen {\n            row()\n        } else {\n"
               + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    func ink() -> some View {\n        if chosen {\n            row().overlay {\n"
               + "                Text(\"a\").foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        if chosen, flag {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", "struct FillButtonStyle: ButtonStyle {}\nstruct Other: View {\n"
               + "    var body: some View { Text(\"a\").foregroundStyle(Theme.onTintFill) }\n}"),
        accent("onTintFill", "let ink = Theme.onTintFill"),
        // A `chosen` that isn't the row's own.
        accent("onTintFill", split("    var body: some View {\n"
               + "        let chosen = !Self.isChosen(place, section: section, regular: true)\n"
               + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    var body: some View {\n        let chosen = true\n"
               + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    var body: some View {\n        var chosen = Self.isChosen(place, section: section, regular: true)\n"
               + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        let chosen = !chosen\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
               + "        }\n    }")),
        accent("onTintFill", split("    var body: some View {\n        if chosen {\n"
               + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        // Scope: a stored `chosen` is not another function's parameter.
        accent("onTintFill", split("    var chosen: Bool\n"
               + "    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    var body: some View {\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    static func other(flag: Bool) -> some View {\n        if chosen {\n"
               + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    var body: some View {\n        ForEach(rows) { chosen in\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        // The exact type body: not after HomeSplit's closing brace, and
        // not in a type whose name only starts the same.
        accent("onTintFill", split("    var body: some View { Text(\"a\") }") + "\n"
               + "func ink(chosen: Bool) -> some View {\n    if chosen {\n        row().foregroundStyle(Theme.onTintFill)\n    }\n}"),
        accent("onTintFill", "extension HomeSplitter {\n    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
               + "        }\n    }\n}"),
        // Every row is handed its own `chosen`.
        accent("ink", split("    var body: some View {\n        Self.ink(chosen: !chosen) { Text(\"a\") }\n    }")),
        accent("ink", split("    var body: some View {\n        let chosen = !Self.isChosen(place, section: section, regular: true)\n"
               + "        Self.ink(chosen: chosen) { Text(\"a\") }\n    }")),
        accent("ink", split("    var body: some View {\n        Self.ink(chosen: flag) { Text(\"a\") }\n    }")),
        accent("ink", split("    let chosen = true\n    var body: some View {\n        Self.ink(chosen: chosen) { Text(\"a\") }\n    }")),
        accent("ink", "extension HomeSplit {\n    var row: some View { Self.ink(chosen: flag) { Text(\"a\") } }\n}"),
        // A `chosen` a case, a while or a catch binds is not the parameter.
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        switch state {\n        case .picked(let chosen):\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        default:\n            row()\n"
               + "        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        switch state {\n        case let .picked(chosen):\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        default:\n            row()\n"
               + "        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        while let chosen = next() {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        do {\n            try work()\n        } catch let chosen {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("ink", split("    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    static func rows(chosen: Bool) -> some View {\n        switch state {\n"
               + "        case .picked(let chosen):\n            Self.ink(chosen: chosen) { Text(\"a\") }\n"
               + "        default:\n            Text(\"b\")\n        }\n    }")),
        accent("ink", split("    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    static func rows(chosen: Bool) -> some View {\n        do {\n            try work()\n"
               + "        } catch let chosen as Flag {\n            Self.ink(chosen: chosen) { Text(\"a\") }\n        }\n    }")),
        // A `chosen` a tuple binds, in any of the forms that bind one, is
        // not the parameter either.
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        let (chosen, _) = (!chosen, 1)\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
               + "        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        var (other, chosen) = (1, false)\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
               + "        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        let ((chosen, _), _) = ((true, 1), 2)\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
               + "        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        for (chosen, _) in pairs {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        if case let (chosen, _) = pair {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        guard case (let chosen, _) = pair else { return row() }\n        if chosen {\n"
               + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        switch pair {\n        case (let chosen, _):\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        while case let (chosen, _)? = next() {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        do {\n            try work()\n        } catch let Failure.picked(chosen, _) {\n            if chosen {\n"
               + "                row().foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }")),
        // A `chosen` set inside an #if before it is not the parameter.
        accent("onTintFill", split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
               + "        #if DEBUG\n        let chosen = true\n        #endif\n        if chosen {\n"
               + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }")),
        accent("ink", split("    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    static func rows(chosen: Bool) -> some View {\n        let (chosen, _) = (flag, 1)\n"
               + "        Self.ink(chosen: chosen) { Text(\"a\") }\n    }")),
        accent("ink", split("    static func ink(chosen: Bool, row: () -> some View) -> some View { row() }\n"
               + "    static func rows(chosen: Bool) -> some View {\n        #if DEBUG\n        var chosen = flag\n        #endif\n"
               + "        Self.ink(chosen: chosen) { Text(\"a\") }\n    }")),
        // In backticks, a name is the same name.
        accent("tintFillWords", #"Text("Open").foregroundStyle(Theme.`tintFill`)"#),
        accent("tintFillTint", #"Text("Open").tint(Theme.`tintFill`)"#),
        accent("onTintFill", #"Text("Open").foregroundStyle(Theme.`onTintFill`)"#),
        accent("doneRing", "`ToolbarItem`(placement: .primaryAction) {\n    `DoneButton` { dismiss() }\n}"),
        // Theme qualified by its module is still Theme.
        accent("tintFillWords", #"Text("Open").foregroundStyle(PebbleUI.Theme.tintFill)"#),
        accent("tintFillTint", #"Text("Open").tint(PebbleUI.Theme.tintFill)"#),
    ]

    static let accentRight: [RightCase] = [
        fine(split("    var body: some View {\n        List(selection: $section) {\n            Text(\"a\")\n"
                   + "        }\n        // The sidebar.\n        .tint(Theme.tintFill)\n    }")),
        fine("struct DoneButton: View {\n    var body: some View {\n        Button(\"Done\") {}\n            .tint(Theme.tintFill)\n    }\n}"),
        fine("ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)"),
        fine("ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)"),
        fine("ToolbarItem {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)"),
        fine(".toolbar {\n    ToolbarItem(placement: .confirmationAction) {\n        DoneButton(title: \"Done\") { dismiss() }\n"
             + "    }\n    .sharedBackgroundVisibility(.hidden)\n}"),
        fine("struct DoneButton: View {\n    var body: some View { Button(\"Done\") {} }\n}"),
        // An item with no Done keeps the toolbar's glass.
        fine("ToolbarItem(placement: .cancellationAction) {\n    Button(\"Cancel\") { dismiss() }\n}"),
        // White on the fill: the chosen sidebar row, its badge, and Done.
        fine(split("    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
                   + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
                   + "        }\n    }")),
        fine("struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
             + "        configuration.label.foregroundStyle(Theme.onTintFill)\n    }\n}"),
        fine("static let onTintFill = RGB.white.color"),
        fine("// Theme.onTintFill only on the fill"),
        // The row's own chosen, from Self.isChosen.
        fine(split("    var body: some View {\n"
                   + "        let chosen = Self.isChosen(place, section: section, regular: isRegular) && Self.drawsOwnFill\n"
                   + "        Self.ink(chosen: chosen) { Text(\"a\") }\n"
                   + "        Self.ink(chosen: Self.isChosen(place, section: section, regular: true)) { Text(\"b\") }\n    }\n"
                   + "    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
                   + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
                   + "        }\n    }")),
        // As the sidebar really is: the row's chosen in a ForEach, handed on.
        fine(split("    var body: some View {\n        List(selection: $section) {\n"
                   + "            ForEach(HomeSection.allCases, id: \\.self) { place in\n"
                   + "                let chosen = Self.isChosen(place, section: section, regular: isRegular) && Self.drawsOwnFill\n"
                   + "                NavigationLink(value: place) {\n                    Self.ink(chosen: chosen) { Text(\"a\") }\n"
                   + "                }\n            }\n        }\n        .tint(Theme.tintFill)\n    }")),
        // An extension of the type is the type's own code.
        fine("extension HomeSplit {\n    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
             + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
             + "        }\n    }\n}"),
        fine("extension FillButtonStyle {\n    func label(_ text: String) -> some View { Text(text).foregroundStyle(Theme.onTintFill) }\n}"),
    ]

    @Test func theAccentGuardCatchesEveryWrongCase() {
        check(Self.accentWrong, Self.accentRight, rules: ContrastLint.accentRules.map(\.name),
              quiet: ContrastLint.rules.map(\.name)) {
            ContrastLint.problems(in: $0, file: $1)
        }
    }

    // MARK: The design token guard

    static func token(_ rule: String, _ text: String) -> WrongCase {
        WrongCase(rule: "token." + rule, text: text, file: "PebbleUI/Wrong.swift")
    }

    static let tokenWrong: [WrongCase] = [
        token("literalColor", "let a = Color(red: 0.2, green: 0.3, blue: 0.4)"),
        token("literalColor", ".fill(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))"),
        token("literalColor", "let a = SwiftUI.Color(hue: 0.6, saturation: 0.5, brightness: 0.9)"),
        token("literalColor", "let a = Color.init(white: 0.5)"),
        token("literalColor", "let a = `Color`(`red`: 1, green: 1, blue: 1)"),
        token("literalColor", "let a = UIColor(red: 1, green: 1, blue: 1, alpha: 1)"),
        token("fixedFont", "Text(\"a\").font(.system(size: 30))"),
        token("fixedFont", "Text(\"a\").font(.system(size: 40, weight: .semibold, design: .rounded))"),
        token("fixedFont", "Text(\"a\").font(Font.custom(\"Serif\", size: 17))"),
        token("fixedFont", "let font = UIFont.systemFont(ofSize: 12)"),
        token("fixedFont", "Text(\"a\").font(.`system`(`size`: 30))"),
    ]

    static let tokenRight: [RightCase] = [
        fine("Text(\"a\").font(Theme.TypeScale.body)"),
        fine("Text(\"a\").font(.system(.title2, design: .rounded).weight(.bold))"),
        fine("Text(\"a\").font(.title.weight(.semibold))"),
        fine(".fill(Color.primary.opacity(Theme.fieldTint))"),
        fine(".fill(Theme.accentRGB.color)"),
        fine("Text(\"Color(red: 1, green: 0, blue: 0) and .system(size: 30)\")"),
        fine("// .font(.system(size: 30)) and Color(red: 1, green: 0, blue: 0)"),
        // Theme.swift defines the tokens, so it may spell them out.
        fine("static let accent = Color(red: 0.4, green: 0.62, blue: 0.97)", file: TokenLint.themeFile),
        fine("static let badgeSymbol = Font.system(size: 30, weight: .semibold)", file: TokenLint.themeFile),
        // Only PebbleUI's screens are read.
        fine("let a = Color(red: 1, green: 1, blue: 1)", file: "App/Snapshot.swift"),
    ]

    @Test func theTokenGuardCatchesEveryWrongCase() {
        check(Self.tokenWrong, Self.tokenRight, rules: TokenLint.rules.map(\.name)) {
            TokenLint.problems(in: $0, file: $1)
        }
    }

    // MARK: The platform gate

    static func gate(_ rule: String, _ text: String) -> WrongCase {
        WrongCase(rule: "platform." + rule, text: text, file: "PebbleCoreTests/Wrong.swift")
    }

    static let platformWrong: [WrongCase] = [
        gate("nsName", "let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)"),
        gate("nsName", "#if canImport(SwiftUI)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif"),
        gate("nsName", "#if os(macOS)\nlet a = 1\n#else\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif"),
        gate("nsName", "#if os(iOS)\nlet a = 1\n#else\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif"),
        gate("nsName", "#if os(iOS)\nlet a = 1\n#endif\nlet host = NSHostingView(rootView: Text(\"\"))"),
        // Naming the Mac isn't enough: turned around, or one arm of many.
        gate("nsName", "#if !os(macOS)\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if os(macOS) || os(iOS)\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if canImport(AppKit) || canImport(UIKit)\nlet image = NSImage()\n#endif"),
        gate("nsName", "#if os(iOS)\nlet a = 1\n#elseif !canImport(AppKit)\nlet image = NSImage()\n#endif"),
        gate("nsName", "#if os(macOS)\nlet a = 1\n#elseif os(iOS)\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if DEBUG\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if os(macOS) || DEBUG\nlet window = NSWindow()\n#endif"),
        // Any AppKit name, not only the ones someone thought to list.
        gate("nsName", "let controller = NSViewController()"),
        gate("nsName", "NSPasteboard.general.clearContents()"),
        gate("nsName", "let range = NSRange(location: 0, length: 1); let board = NSPasteboard.general"),
        // Mac Catalyst runs UIKit, and AppKit can be imported there, so
        // neither it nor canImport(AppKit) alone is a Mac gate.
        gate("nsName", "#if targetEnvironment(macCatalyst)\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if os(macOS) || targetEnvironment(macCatalyst)\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if canImport(AppKit)\nlet image = NSImage()\n#endif"),
        gate("nsName", "#if os(macOS) || canImport(AppKit)\nlet image = NSImage()\n#endif"),
        // With no space after the directive, the branch is still read.
        gate("nsName", "#if(os(iOS))\nlet a = 1\n#else\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if os(macOS)\nlet a = 1\n#elseif(os(iOS))\nlet window = NSWindow()\n#endif"),
        gate("nsName", "#if(!os(macOS))\nlet window = NSWindow()\n#endif"),
        // AppKit with no NS in its name.
        gate("macOnlyImport", "import AppKit"),
        gate("macOnlyImport", "@testable import AppKit"),
        gate("macOnlyImport", "import class AppKit.NSWindow"),
        gate("macOnlyImport", "import Cocoa"),
        gate("macOnlyImport", "#if !os(macOS)\nimport AppKit\n#endif"),
        gate("macOnlyImport", "#if os(macOS) || targetEnvironment(macCatalyst)\nimport AppKit\n#endif"),
        gate("macOnlyName", "let process = Process()"),
        gate("macOnlyName", "#if os(iOS)\n#else\nlet task = Process()\n#endif"),
        gate("macOnlyName", "func run(_ process: Process) {}"),
        gate("macOnlyName", "DistributedNotificationCenter.default().post(name: name, object: nil)"),
        // In backticks, a name is the same name.
        gate("nsName", "let window = `NSWindow`()"),
        gate("macOnlyImport", "import `AppKit`"),
        gate("macOnlyImport", "import `Cocoa`"),
        gate("macOnlyName", "let process = `Process`()"),
        // Cocoa brings AppKit, and imports on Mac Catalyst as AppKit does.
        gate("nsName", "#if canImport(Cocoa)\nlet image = NSImage()\n#endif"),
        gate("macOnlyImport", "#if canImport(Cocoa)\nimport AppKit\n#endif"),
        gate("nsName", "#if canImport(`Cocoa`)\nlet image = NSImage()\n#endif"),
        // Past sixteen flags, the last one still counts.
        gate("nsName", "#if \(GuardScanTests.manyFlags("os(macOS) || ZZ"))\nlet window = NSWindow()\n#endif"),
        gate("macOnlyImport", "#if \(GuardScanTests.manyFlags("os(macOS) || ZZ"))\nimport AppKit\n#endif"),
    ]

    static func fineTest(_ text: String) -> RightCase { fine(text, file: "PebbleCoreTests/Right.swift") }

    static let platformRight: [RightCase] = [
        fineTest("#if os(macOS)\nlet window = NSWindow()\n#endif"),
        fineTest("#if canImport(SwiftUI)\n#if os(macOS)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif\n#endif"),
        fineTest("#if os(iOS)\nlet a = 1\n#elseif os(macOS)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif"),
        fineTest("#if canImport(AppKit) && !targetEnvironment(macCatalyst)\nlet image = NSImage()\n#endif"),
        fineTest("#if canImport(Cocoa) && !targetEnvironment(macCatalyst)\nlet image = NSImage()\n#endif"),
        fineTest("#if os(macOS)\nimport `Cocoa`\n#endif"),
        fineTest("#if (os(macOS))\nlet image = NSImage()\n#endif"),
        fineTest("#if(os(macOS))\nlet image = NSImage()\n#endif"),
        fineTest("#if os(iOS)\nlet a = 1\n#elseif(os(macOS))\nlet image = NSImage()\n#endif"),
        fineTest("#if os(macOS) && DEBUG\nlet window = NSWindow()\n#endif"),
        fineTest("#if os(iOS)\nlet a = 1\n#else\n#if os(macOS)\nlet window = NSWindow()\n#endif\n#endif"),
        // The #else of "not the Mac" is the Mac.
        fineTest("#if !os(macOS)\nlet a = 1\n#else\nlet window = NSWindow()\n#endif"),
        fineTest("#if os(macOS)\nimport AppKit\n#endif"),
        fineTest("#if os(macOS)\nlet process = Process()\n#endif"),
        fineTest("struct Tests {\n    #if os(macOS)\n    @Test func runs() {\n        let process = Process()\n    }\n    #endif\n}"),
        fineTest("let info = ProcessInfo.processInfo"),
        fineTest("// NSWindow, in a comment"),
        fineTest("let note = \"NSHostingView, in words\""),
        fineTest("let range = NSRange(location: 0, length: 1)"),
        fineTest("let regex = try NSRegularExpression(pattern: \"a\")"),
        fineTest("let lock = NSLock(); let text = NSString(string: \"a\")"),
    ]

    @Test func thePlatformGateCatchesEveryWrongCase() {
        check(Self.platformWrong, Self.platformRight, rules: PlatformGate.rules.map(\.name)) {
            PlatformGate.ungated(in: $0, file: $1)
        }
    }

    // MARK: The grant issuer

    static func issuer(_ text: String, file: String = "PebbleUI/FeedView.swift") -> WrongCase {
        WrongCase(rule: "grant.issuerOutsideSheet", text: text, file: file)
    }

    static let grantWrong: [WrongCase] = [
        issuer("let grant = GrantIssuer().issue(.always, for: approval, now: Date())"),
        issuer("let grant = `GrantIssuer`().issue(.always, for: approval, now: Date())"),
        issuer("let make = GrantIssuer.init\nlet grant = make().issue(.always, for: approval, now: Date())"),
        issuer("typealias Maker = GrantIssuer"),
        issuer("func widen(_ issuer: GrantIssuer) {}", file: "PebbleCore/LocalFakeEngine.swift"),
        issuer("let grant = GrantIssuer().issue(.always, for: approval, now: Date())", file: "PebbleUI/ChatView.swift"),
        issuer("let grant = GrantIssuer().issue(.always, for: approval, now: Date())", file: "PebbleUI/ShowcaseScene.swift"),
        issuer("let grant = PebbleCore.GrantIssuer().issue(.always, for: approval, now: Date())",
               file: "PebbleModel/Conversation.swift"),
        granting("let s = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: { book.add($0) }, onDecline: {})\ns.choose(.always)\ns.tapPrimary()"),
        granting("let s = `ConfirmationState`(request: r, rule: rule, onApprove: { _ in }, onGrant: { book.add($0) }, onDecline: {})"),
        granting("let s = PebbleUI.ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: { _ in }, onDecline: {})"),
        granting("let s = ConfirmationState(request: r, rule: rule) { _ in } onGrant: { book.add($0) } onDecline: {}"),
        granting("let s = ConfirmationState.init(request: r, rule: rule, onApprove: { _ in }, onGrant: { _ in }, onDecline: {})"),
        granting("let make = ConfirmationState.init"),
        granting("typealias Sheet = ConfirmationState"),
        granting("func answer(_ state: ConfirmationState) { state.choose(.always); state.tapPrimary() }"),
        granting("func other() { _ = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: { _ in }, onDecline: {}) }",
                 file: "PebbleUI/ShowcaseScene.swift"),
        granting("func sampleGrants() { _ = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: { _ in }, onDecline: {}) }",
                 file: "PebbleUI/HomeView.swift"),
    ]

    static func granting(_ text: String, file: String = "PebbleUI/FeedView.swift") -> WrongCase {
        WrongCase(rule: "grant.grantingStateOutsideSheet", text: text, file: file)
    }

    static let grantRight: [RightCase] = [
        fine("let grant = GrantIssuer().issue(choice, for: approval, now: wallClock())",
             file: "PebbleUI/ConfirmationSheet.swift"),
        fine("public struct GrantIssuer: Sendable {}", file: "PebbleCore/Grants.swift"),
        fine("// GrantIssuer, in a comment"),
        fine("let note = \"GrantIssuer, in words\""),
        fine("let issuers = GrantIssuers()"),
        fine("let s = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onDecline: {})\ns.tapPrimary()",
             file: "PebbleUI/ShowcaseScene.swift"),
        fine("_ = PebbleUI.ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onDecline: {})"),
        fine("_ = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: onGrant, onDecline: {})",
             file: "PebbleUI/ConfirmationSheet.swift"),
        fine("static func sampleGrants(at now: Date) -> GrantBook {\n    let s = ConfirmationState(request: r, rule: rule, onApprove: { _ in }, onGrant: { book.add($0) }, onDecline: {})\n    s.choose(.always)\n    s.tapPrimary()\n}",
             file: "PebbleUI/ShowcaseScene.swift"),
        fine("ConfirmationSheet(request: r, rule: rule, onApprove: { _ in }, onGrant: { _ in }, onDecline: {})"),
        fine("// ConfirmationState, in a comment"),
        fine("let note = \"ConfirmationState, in words\""),
    ]

    @Test func theGrantIssuerGuardCatchesEveryWrongCase() {
        check(Self.grantWrong, Self.grantRight, rules: GrantIssuerGate.rules.map(\.name)) {
            GrantIssuerGate.problems(in: $0, file: $1)
        }
    }

    // MARK: The suite itself

    /// Every rule of every guard has a wrong case here, so none can be
    /// added, or stop working, unseen.
    @Test func everyRuleHasAWrongCase() {
        let all = Self.promiseWrong + Self.contrastWrong + Self.accentWrong + Self.tokenWrong + Self.platformWrong
            + Self.grantWrong
        let rules = PromiseRules.allRuleNames + ContrastLint.rules.map(\.name) + TokenLint.rules.map(\.name)
            + PlatformGate.rules.map(\.name) + GrantIssuerGate.rules.map(\.name)
        #expect(Set(rules).count == rules.count, "each rule has its own name")
        for rule in rules {
            #expect(all.contains { $0.rule == rule }, "no wrong case for \(rule)")
        }
        for wrong in all {
            #expect(rules.contains(wrong.rule), "no rule named \(wrong.rule)")
        }
    }

    /// Each wrong case is flagged by the rule it names, and each right case
    /// by none of `quiet`, which is `rules` unless given.
    func check(_ wrong: [WrongCase], _ right: [RightCase], rules: [String], quiet: [String]? = nil,
               sourceLocation: SourceLocation = #_sourceLocation,
               findings: (SyntaxSource, String) -> [Finding]) {
        #expect(!wrong.isEmpty && !right.isEmpty, sourceLocation: sourceLocation)
        for rule in rules {
            #expect(wrong.contains { $0.rule == rule }, "no wrong case for \(rule)", sourceLocation: sourceLocation)
        }
        for item in wrong {
            let found = findings(SyntaxSource(item.text), item.file)
            #expect(found.contains { $0.rule == item.rule },
                    "\(item.rule) missed: \(item.text)\nfound: \(found.map(\.rule))", sourceLocation: sourceLocation)
        }
        let quiet = Set(quiet ?? rules)
        for item in right {
            let found = findings(SyntaxSource(item.text), item.file)
                .filter { quiet.contains($0.rule) && (item.only?.contains($0.rule) ?? true) }
            #expect(found.isEmpty, "flagged: \(item.text)\n\(found)", sourceLocation: sourceLocation)
        }
    }
}

/// The scanner the guards share reads Swift as the compiler does.
struct GuardScanTests {
    /// A name in backticks is the same name, and code reads without them.
    @Test func namesAreReadWithoutBackticks() {
        let source = SyntaxSource("let `place` = `PrivacyPlace`.`onDevice`")
        #expect(SyntaxSource.code(source.tree) == "letplace=PrivacyPlace.onDevice")
        #expect(source.firstToken("onDevice").map(SyntaxSource.name) == "onDevice")
        #expect(source.firstToken("`onDevice`") == nil, "found by its name, not as written")
    }

    @Test func literalsAreReadAsTheProgramSeesThem() throws {
        func value(_ text: String) throws -> String { try #require(SyntaxSource(text).literals.first).value }
        #expect(try value(#"let x = "a\u{0020}b\tc""#) == "a b\tc")
        #expect(try value(##"let x = #"a\#u{0020}b\n"#"##) == "a b\\n")
        #expect(try value("let x = \"\"\"\n    one\n      two \\\n    three\n    \"\"\"") == "one\n  two three")
        #expect(try value(#"let x = "Hi \(name), \(1 + 2)!""#) == "Hi \u{FFFC}, \u{FFFC}!")
        let literal = try #require(SyntaxSource(#"let x = "Hi \(name)""#).literals.first)
        #expect(literal.hasInterpolation)
        #expect(literal.written == #"Hi \(name)"#)
        // A literal inside an interpolation is a literal of its own.
        #expect(SyntaxSource(#"let x = "a \(f("b")) c""#).literals.map(\.value) == ["a \u{FFFC} c", "b"])
    }

    @Test func plusJoinsLiteralsIntoChains() {
        func chains(_ text: String) -> [[String]] { SyntaxSource(text).chains.map { $0.map(\.value) } }
        #expect(chains(#"let x = "a" + "b" + "c""#) == [["a", "b", "c"]])
        #expect(chains(#"let x = "a" + ("b")"#) == [["a", "b"]])
        #expect(chains(#"let x = "a" + name + "b""#) == [["a"], ["b"]])
        #expect(chains(#"let x = name + "a" + "b""#) == [["a", "b"]])
        #expect(chains(#"let x = "a" == "b""#) == [["a"], ["b"]])
    }

    @Test func ifConditionsAreEvaluated() {
        func macOnly(_ condition: String) -> Bool {
            SyntaxSource("#if \(condition)\nlet x = 1\n#endif").context(atFirst: "x")?.isMacOnly ?? false
        }
        #expect(macOnly("os(macOS)"))
        #expect(macOnly("(os(macOS))"))
        #expect(macOnly("os(macOS) && DEBUG"))
        #expect(macOnly("canImport(AppKit) && !targetEnvironment(macCatalyst)"))
        #expect(!macOnly("!os(macOS)"))
        #expect(!macOnly("os(macOS) || os(iOS)"))
        #expect(!macOnly("canImport(AppKit)"))
        #expect(!macOnly("canImport(Cocoa)"))
        #expect(macOnly("canImport(Cocoa) && !targetEnvironment(macCatalyst)"))
        #expect(!macOnly("targetEnvironment(macCatalyst)"))
        #expect(!macOnly("DEBUG"))
        #expect(!macOnly("os(macOS) || swift(>=6.0)"))
        // #elseif and #else turn down every branch before them.
        let chain = SyntaxSource("#if os(iOS)\nlet a = 1\n#elseif os(macOS)\nlet b = 1\n#else\nlet c = 1\n#endif")
        #expect(chain.context(atFirst: "a")?.isMacOnly == false)
        #expect(chain.context(atFirst: "b")?.isMacOnly == true)
        #expect(chain.context(atFirst: "c")?.isMacOnly == false)
        #expect(chain.context(atFirst: "c")?.condition.canHold(on: Condition.Platform.all.filter { $0.os == "Linux" }) == true)
        let notMac = SyntaxSource("#if !os(macOS)\nlet a = 1\n#else\nlet b = 1\n#endif")
        #expect(notMac.context(atFirst: "b")?.isMacOnly == true)
        let debug = SyntaxSource("#if DEBUG\nlet a = 1\n#else\nlet b = 1\n#endif")
        #expect(debug.context(atFirst: "a")?.isDebugOnly == true)
        #expect(debug.context(atFirst: "b")?.isDebugOnly == false)
        // Every flag counts, the seventeenth too: `ZZ` sorts after the
        // sixteen others, and alone makes each condition hold elsewhere.
        func debugOnly(_ condition: String) -> Bool {
            SyntaxSource("#if \(condition)\nlet x = 1\n#endif").context(atFirst: "x")?.isDebugOnly ?? false
        }
        #expect(macOnly(Self.manyFlags("os(macOS)")))
        #expect(!macOnly(Self.manyFlags("os(macOS) || ZZ")))
        #expect(debugOnly(Self.manyFlags("DEBUG")))
        #expect(!debugOnly(Self.manyFlags("DEBUG || ZZ")))
    }

    /// `condition`, or'd with sixteen flags that can never hold: `A01` to
    /// `A16`, each and'd with its own negation.
    static func manyFlags(_ condition: String) -> String {
        ([condition] + (1...16).map { String(format: "(A%02d && !A%02d)", $0, $0) }).joined(separator: " || ")
    }

    @Test func declarationsAndMacrosAroundANodeAreKnown() throws {
        let text = "@main\nstruct App {\n    struct Inner { let a = 1 }\n    let b = 2\n}\nextension PebbleUI.HomeSplit { let c = 3 }\n"
            + "#Preview { Text(\"d\") }\nlet e = 5"
        let source = SyntaxSource(text)
        let a = try #require(source.context(atFirst: "a"))
        #expect(a.types.map(\.name) == ["Inner", "App"])
        #expect(a.inMain)
        #expect(!source.isInside("App", atFirst: "a"), "a type inside it is not it")
        #expect(source.isInside("App", atFirst: "b"))
        #expect(source.isInside("HomeSplit", atFirst: "c"), "an extension of it is it")
        #expect(source.context(atFirst: "d")?.inPreview == true)
        #expect(source.context(atFirst: "e")?.inPreview == false, "a preview ends at its own brace")
        #expect(source.context(atFirst: "e")?.inMain == false)
        #expect(!source.isInside("App", atFirst: "e"))
    }

    /// Lines and columns count Characters, so an emoji, a flag or an
    /// accented letter before a problem never moves where it points.
    @Test func diagnosticsCountCharacters() throws {
        let family = "👩‍👩‍👧‍👦"
        let text = "let a = \"\(family)\(family)\(family) é\u{301}\"\nlet place = PrivacyPlace.onDevice\nlet b = 1\nlet c = 2\nlet d = 3"
        let found = PromiseRules.placeProblems(in: SyntaxSource(text), file: "PebbleUI/Wrong.swift")
        #expect(found.map(\.line) == [2])
        #expect(found.map(\.column) == [13])
        let same = "let a = \"\(family) é\u{301}\"; let place = PrivacyPlace.onDevice"
        let column = try #require(PromiseRules.placeProblems(in: SyntaxSource(same), file: "PebbleUI/Wrong.swift").first).column
        #expect(column == 28, "8 for `let a = `, 5 for the literal, 14 for `; let place = `")
        let literal = try #require(SyntaxSource("let a = 1; let b = \"\(family)\"; let c = \"x\"").literals.last)
        #expect(literal.column == 33, "19, then 3 for the family's literal, then 10")
        #expect(Finding(rule: "r", line: 2, column: 13, message: "m").report(in: "A.swift") == "A.swift:2:13: m")
    }
}

extension GuardWrongCaseTests {
    static let privacyWrong: [WrongCase] = [
        WrongCase(rule: "privacy.gateTests", text: "// func offByDefaultMakesNoTransportAndKeepsChatsOnDevice() { #expect(maker.made == 0) }", file: PrivacyRules.gateTests),
        WrongCase(rule: "privacy.network", text: "let x = NSURLSession.sharedSession()", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = `socket`\n (AF_INET, SOCK_STREAM, 0)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = try Data.init(\n contentsOf: url)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = Data.init(contentsOf:)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.transport", text: "let x: URLSessionCloudTransport = .init()", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.transport", text: "let x = URLSessionCloudTransport.init", file: PrivacyRules.gate),
        WrongCase(rule: "privacy.transport", text: "func f() { _ = ModelChoice.model(local: local) { _ in local }; makeTransport() }", file: PrivacyRules.gate),
        WrongCase(rule: "privacy.transport", text: "let x = ModelChoice.model(local: { makeTransport() }()) { _ in local }", file: PrivacyRules.gate),
        WrongCase(rule: "privacy.transport", text: "let x = makeTransport", file: PrivacyRules.gate),
        WrongCase(rule: "privacy.sessionFactory", text: "public static func makeSession() -> URLSession { fatalError() }", file: PrivacyRules.cloud),
        WrongCase(rule: "privacy.requiredReason", text: "let x = fstat\n (fd, &info)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.speech", text: "local.requiresOnDeviceRecognition = true\nrecognizer.recognitionTask(with: unrestricted) { _, _ in }", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.speech", text: "func unrestricted() { SFSpeechRecognizer() }", file: PrivacyRules.speechHelper),
        WrongCase(rule: "privacy.upload", text: "let x = MKLocalSearch(request: request)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.encryption", text: "import CryptoKit", file: PrivacyRules.cloud),
        // Round 3: remote readers with no flagged name.
        WrongCase(rule: "privacy.network", text: "var body: some View { WebView(url: url) }", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let page = WebPage()", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = MCSession(peer: peer)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = MCNearbyServiceBrowser(peer: peer, serviceType: kind)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = MCBrowserViewController(serviceType: kind, session: session)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = NSArray(contentsOf: url)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = try NSAttributedString(url: url, options: [:], documentAttributes: nil)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = AVURLAsset(url: url)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = AVAsset(url: url)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = try NSXMLDocument(contentsOf: url, options: [])", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.upload", text: "let x = FileManager.default.url(forUbiquityContainerIdentifier: nil)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.upload", text: "let x = FileManager.default.ubiquityIdentityToken", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "for try await line in url.lines { print(line) }", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = url.resourceBytes", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = urls.map(\\.lines)", file: "App/Sources/Wrong.swift"),
        // contentsOf: however the initializer's type is spelled.
        WrongCase(rule: "privacy.urlRead", text: "let x: Data = try .init(contentsOf: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "typealias Bytes = Data\nlet x = all.map(Bytes.init)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "extension Data { static func f(_ all: [Data]) -> [Data] { all.map(Self.init) } }", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = type(of: data).init(contentsOf:options:)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "try FileManager.default.copyItem(at: remote, to: local)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = FileManager.default.copyItem(at:to:)", file: "App/Sources/Wrong.swift"),
        // Round 4. An alias of any case, from this file or another.
        WrongCase(rule: "privacy.urlRead", text: "typealias bytes = Data\nlet x = try bytes(contentsOf: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = try bytes(contentsOf: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "enum Kinds { typealias bytes = Data }\nlet x = try Kinds.bytes(contentsOf: remote)", file: "App/Sources/Wrong.swift"),
        // A remote initializer through an alias, inference or another label.
        WrongCase(rule: "privacy.network", text: "typealias Player = AVPlayer\nlet x = Player(url: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.network", text: "let x = NSImage(byReferencing: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x: AVPlayer = .init(url: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x: NSImage = .init(byReferencing: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = Loader(url: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "class Loader: AVPlayer {}\nlet x = Loader(url: remote)", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "let x = remotes.map(Loader.init(url:))", file: "App/Sources/Wrong.swift"),
        // The URL readers with self. left off.
        WrongCase(rule: "privacy.urlRead", text: "extension URL { func f() async throws { for try await b in resourceBytes { _ = b } } }", file: "App/Sources/Wrong.swift"),
        WrongCase(rule: "privacy.urlRead", text: "typealias Link = URL\nextension Link { var x: AsyncLineSequence<URL.AsyncBytes> { lines } }", file: "App/Sources/Wrong.swift"),
        // A capture list runs before consent is checked.
        WrongCase(rule: "privacy.transport", text: "let x = ModelChoice.model(local: local) { [t = URLSessionCloudTransport()] url in t }", file: PrivacyRules.gate),
        WrongCase(rule: "privacy.transport", text: "let x = ModelChoice.model(local: local, cloud: { [t = makeTransport()] _ in t })", file: PrivacyRules.gate),
    ]

    @Test func privacyRulesCatchEveryWrongCase() {
        for item in Self.privacyWrong {
            let hits = PrivacyRules.findings(in: SyntaxSource(item.text), file: item.file)
            #expect(hits.contains { $0.rule == item.rule }, "\(item.rule) missed \(item.text)")
        }
    }

    @Test func privacyRulesAllowReviewedContexts() {
        let comments = SyntaxSource("/* URLSession /* stat() */ CryptoKit */\nlet x = \"socket()\"")
        #expect(PrivacyRules.findings(in: comments, file: "App/Sources/Right.swift").isEmpty)
        for text in [
            "ModelChoice.model(settings: settings, endpoint: url, local: local) { _ in\n\n\n\n\n\n\n\n\n\n URLSessionCloudTransport() }",
            "ModelChoice.model(settings: settings, endpoint: url, local: local, cloud: { _ in URLSessionCloudTransport.init() })",
            "ModelChoice.model(settings: settings, endpoint: url, local: local) { _ in let x: URLSessionCloudTransport = .init(); return x }",
            "ModelChoice.model(settings: settings, endpoint: url, local: local) { [settings] _ in URLSessionCloudTransport() }",
            "ModelChoice.model(settings: settings, endpoint: url, local: local) { _ in { [t = URLSessionCloudTransport()] in t }() }",
        ] {
            #expect(!PrivacyRules.findings(in: SyntaxSource(text), file: PrivacyRules.gate).contains { $0.rule == "privacy.transport" })
        }
        // contentsOf: on a method, a method named lines, and a copy by path read nothing.
        // A plain type made here may take a url:, a method's url: reads nothing,
        // and lines outside an extension of URL is just a name.
        for text in ["all.append(contentsOf: more)", "let x = announcer.lines(for: list)", "try FileManager.default.copyItem(atPath: a, toPath: b)",
                     "struct Source { var url: URL }\nlet x = Source(url: link)", "final class Box { init(url: URL) {} }\nlet x = Box(url: link)",
                     "let x = shown.title(url: link)", "var lines = [\"a\"]\nlines.append(\"b\")",
                     "extension URL { var name: String { lastPathComponent } }"] {
            #expect(!PrivacyRules.findings(in: SyntaxSource(text), file: "App/Sources/Right.swift").contains { $0.rule == "privacy.urlRead" }, "\(text)")
        }
        // The cloud client may hand its request a url:.
        #expect(!PrivacyRules.findings(in: SyntaxSource("let x = URLRequest(url: url)"), file: PrivacyRules.cloud).contains { $0.rule == "privacy.urlRead" })
        #expect(!PrivacyRules.findings(in: SyntaxSource("static func makeSession() {}"), file: PrivacyRules.cloud).contains { $0.rule == "privacy.sessionFactory" })
    }

    @Test func privacyReasonCodesBelongToTheirCategories() {
        for (category, codes) in PrivacyAudit.allowedReasons {
            #expect(!codes.isEmpty)
            for code in codes { #expect(PrivacyAudit.validReason(code, category: category)) }
            #expect(!PrivacyAudit.validReason("0000.0", category: category))
        }
        #expect(!PrivacyAudit.validReason("C617.1", category: "NSPrivacyAccessedAPICategoryUserDefaults"))
        #expect(!PrivacyAudit.validReason("CA92.1", category: "invented"))
    }

    @Test func privacyRejectsUnreadableCompiledSources() {
        #expect(PrivacyAudit.readableSource("App/Sources/Main.swift"))
        for ext in ["m", "mm", "c", "cpp", "metal", "cc", "cxx", "s"] {
            #expect(!PrivacyAudit.readableSource("App/Sources/Wrong." + ext))
        }
    }

    /// project.yml as `xcodegen dump --type json` gives it.
    static func project(_ app: [String: Any], _ more: [String: Any] = [:], packages: [String: Any] = ["PebbleKit": ["path": "Packages/PebbleKit"]]) -> [String: Any] {
        var app = app
        app["type"] = "application"
        return ["packages": packages, "targets": more.merging(["Pebble": app]) { _, new in new }]
    }

    @Test func privacyProjectReadsEveryForm() throws {
        let read = try PrivacyProject.linked(spec: Self.project([
            "sources": ["App/Sources", ["path": "Extra"]],
            "dependencies": [
                ["package": "PebbleKit", "products": ["PebbleCore", "PebbleUI"]],
                ["package": "PebbleKit", "product": "PebblePulse", "embed": false],
                ["package": "PebbleKit"],
                ["target": "Helper"],
            ],
        ], [
            // Reached only as a dependency, so its sources count through it.
            "Helper": ["type": "bundle.unit-test", "sources": "Helper"],
            "PebbleAppUITests": ["type": "bundle.ui-testing", "sources": ["AppUITests"], "dependencies": [["target": "Pebble"]]],
        ]))
        #expect(read.products == ["PebbleCore", "PebbleUI", "PebblePulse", "PebbleKit"])
        #expect(read.roots == ["App/Sources", "Extra", "Helper"])
    }

    @Test func privacyProjectFailsOnFormsItCannotRead() {
        let cases: [(String, [String: Any])] = [
            ("a source key", Self.project(["sources": [["path": "App/Sources", "buildPhase": "sources"]]])),
            ("a framework", Self.project(["dependencies": [["framework": "Vendor.framework"]]])),
            ("an SDK", Self.project(["dependencies": [["sdk": "Network.framework"]]])),
            ("another package", Self.project(["dependencies": [["package": "Other"]]],
                                             packages: ["PebbleKit": ["path": "Packages/PebbleKit"], "Other": ["path": "Other"]])),
            ("PebbleKit elsewhere", Self.project(["dependencies": [["package": "PebbleKit", "product": "PebbleCore"]]],
                                                 packages: ["PebbleKit": ["url": "https://example.com/PebbleKit"]])),
            ("both product forms", Self.project(["dependencies": [["package": "PebbleKit", "product": "PebbleCore", "products": ["PebbleUI"]]]])),
            ("a framework target", Self.project([:], ["Helper": ["type": "framework", "sources": ["Extra"]]])),
            ("a missing target", Self.project(["dependencies": [["target": "Gone"]]])),
        ]
        for (what, spec) in cases {
            #expect(throws: PrivacyProject.Unreadable.self, "\(what)") { try PrivacyProject.linked(spec: spec) }
        }
    }

    @Test func privacyRequiresAllFiveCategories() {
        let cases = ["UserDefaults": "`UserDefaults`\n .standard", "FileTimestamp": "fstat\n (fd, &info)",
                     "SystemBootTime": "`mach_absolute_time`\n ()", "DiskSpace": "statfs\n (path, &info)",
                     "ActiveKeyboards": "UITextInputMode\n .`activeInputModes`"]
        for (category, text) in cases {
            let hits = PrivacyRules.findings(in: SyntaxSource(text), file: "App/Sources/Wrong.swift")
            #expect(hits.contains { $0.rule == "privacy.requiredReason" && $0.message == "NSPrivacyAccessedAPICategory" + category })
        }
    }
}
