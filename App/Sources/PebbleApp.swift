import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand
    /// The one notes store, shared by the memory screen and the cloud
    /// redactor, so both always see the same notes.
    private let memory: MemoryStore?
    /// Off until the person turns it on, and unavailable while
    /// Config/Cloud.local.xcconfig has no address. Its settings and private
    /// words are kept next to the notes, out of backups.
    ///
    /// Held, not observed: the body reads nothing from it, so a change to
    /// the setting must not re-run the body and rebuild the home screen.
    /// The screens that show it observe it themselves.
    @State private var cloud: CloudHelp

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        let memory = try? MemoryStore.onDevice()
        self.memory = memory
        let endpoint = CloudEndpoint.url(infoDictionary: Bundle.main.infoDictionary)
        // The setting is kept next to the notes. If either can't be opened,
        // nothing typed into the setting could be kept, so it reads as off,
        // can't be turned on, and says so plainly.
        let cloud: CloudHelp
        if memory != nil, let store = try? CloudHelpFileStore.onDevice() {
            cloud = CloudHelp(store: store, endpoint: endpoint, memory: memory)
        } else {
            // It can still erase private words kept from an earlier launch.
            cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory,
                                           file: { try CloudHelpFileStore.onDevice() })
        }
        _cloud = State(initialValue: cloud)
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // scripts/screenshots.sh launches with -pebbleStill YES, so the
            // screen settles and two shots of it match.
            Group {
                if let scene = UserDefaults.standard.string(forKey: ShowcaseScene.launchKey).flatMap(ShowcaseScene.init(rawValue:)) {
                    scene.view(brand: brand)
                } else {
                    home
                }
            }
            .environment(\.holdsStill, UserDefaults.standard.bool(forKey: "pebbleStill"))
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
