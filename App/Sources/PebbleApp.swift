import PebbleBackground
import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand
    /// The app's questions, shared by Today and the background runner, so
    /// anything the runner asks waits in the same Needs you.
    private let needsYou: NeedsYou
    /// The app's task engine, shared by Today and the background runner,
    /// so the summary counts the tasks Today shows. There is none yet, and
    /// the summary then says nothing about tasks rather than count zero.
    private let tasks: (any TaskEngine)? = nil
    /// Work done while the app is closed. Off until the person turns it on
    /// from the memory screen. Its runner is nil if its folder can't be made.
    private let background: BackgroundService

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
        let asks = NeedsYou()
        needsYou = asks
        // Registered here, before launch ends, or the system won't run it.
        background = BackgroundService(runner: BackgroundRunner.onDevice(needsYou: asks, tasks: tasks))
        background.start()
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
            memory: try? MemoryStore.onDevice(),
            needsYou: needsYou,
            tasks: tasks,
            background: background.runner
        )
    }
}
