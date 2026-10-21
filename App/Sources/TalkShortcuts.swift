#if os(iOS)
import AppIntents
import PebbleVoice

/// The Talk shortcut in Shortcuts, Siri and Spotlight, ready for the
/// Action Button. The system fills in `.applicationName` with the app's
/// display name, which comes from Config/Brand.xcconfig, so no name is
/// spelled here.
struct TalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start talking to \(.applicationName)",
            ],
            shortTitle: "Talk",
            systemImageName: "mic"
        )
    }
}

/// The intents that live in PebbleKit, included in the app's.
struct AppIntentsRoot: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [VoiceIntents.self] }
}
#endif
