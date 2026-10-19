import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand
    /// Off until the person turns it on, and unavailable while
    /// Config/Cloud.local.xcconfig has no address. Its settings and private
    /// words are kept next to the notes, out of backups.
    ///
    /// Held, not observed: the body reads nothing from it, so a change to
    /// the setting must not re-run the body and rebuild the home screen.
    /// The screens that show it observe it themselves.
    @State private var cloud: CloudHelp

    /// The one notes store, shared by the memory screen and the cloud
    /// redactor. Read from `cloud`, so the two are always the same store.
    /// SwiftUI may make the app again, and each time `init` opens a notes
    /// store and builds a setting around it, but `State` keeps only the
    /// first and the rest are dropped unused, so no screen ever reads one.
    private var memory: MemoryStore? { cloud.memory }

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        // Before any real store is opened, so a snapshot run reads and
        // writes nothing of the person's. It ends the process once it has
        // written its picture; it returns only when no snapshot was asked
        // for, and then nothing below has run yet.
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
        // The setting is kept next to the notes. If either can't be opened,
        // nothing typed into the setting could be kept, so it reads as off,
        // can't be turned on, and says so plainly. The notes store is held
        // either way, with or without a cloud address.
        let endpoint = CloudEndpoint.url(infoDictionary: Bundle.main.infoDictionary)
        _cloud = State(initialValue: CloudHelp.forApp(
            memory: try? MemoryStore.onDevice(),
            endpoint: endpoint,
            // Sign in with Apple, sending only Apple's identity token, a
            // one-time nonce and a key made on this device (`CloudPolicy`).
            // The token comes from the source this build offers
            // (`PEBBLE_SIGN_IN`): Apple, or in a Debug build only, the
            // staging test sign-in. Told to forget when the cloud is
            // turned off and by Forget everything.
            auth: AppleCloudAuth(source: IdentitySignIn.offered(infoDictionary: Bundle.main.infoDictionary,
                                                                endpoint: endpoint)),
            openStore: { try CloudHelpFileStore.onDevice() }
        ))
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scene = UserDefaults.standard.string(forKey: ShowcaseScene.launchKey).flatMap(ShowcaseScene.init(rawValue:)) {
                scene.view(brand: brand)
            } else {
                home
            }
            #else
            home
            #endif
        }
        .commands { HomeCommands() }
    }

    private var home: some View {
        HomeView(
            brand: brand,
            model: LocalStubModel(),
            names: UserDefaultsAgentNameStore(),
            onboarding: UserDefaultsOnboardingStore(),
            memory: memory,
            cloud: cloud
        )
    }
}
