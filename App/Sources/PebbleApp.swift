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
    @StateObject private var cloud: CloudHelp

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        let memory = try? MemoryStore.onDevice()
        self.memory = memory
        let endpoint = CloudEndpoint.url(infoDictionary: Bundle.main.infoDictionary)
        // A store that can't be opened reads as off, like a fresh device.
        let store: any CloudHelpStoring = (try? CloudHelpFileStore.onDevice()) ?? InMemoryCloudHelpStore()
        _cloud = StateObject(wrappedValue: CloudHelp(store: store, endpoint: endpoint, memory: memory))
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
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
