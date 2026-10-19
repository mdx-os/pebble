import AppIntents
import PebbleCore

/// Talk to the agent from Shortcuts, Siri, Spotlight or the iPhone's Action
/// Button. It opens the app straight into listening, on the composer in
/// front, with a tap to send. The app's `AppShortcutsProvider` names it
/// "Talk to" the app's name, which the system reads from the app, so no
/// name is written here.
public struct TalkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Talk"
    public static let description = IntentDescription("Opens the app listening, so you can say what you need. Tap Send when you're done.")
    public static let openAppWhenRun = true
    #if os(iOS)
    public static let isDiscoverable = true
    #else
    // Listening is on iPhone and iPad for now, so the Mac doesn't offer it.
    public static let isDiscoverable = false
    #endif

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TalkRequests.shared.ask()
        return .result()
    }
}

/// The intents in this package, for the app to include.
public struct VoiceIntents: AppIntentsPackage {}
