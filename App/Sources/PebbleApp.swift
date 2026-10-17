import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
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
            memory: try? MemoryStore.onDevice()
        )
    }
}
