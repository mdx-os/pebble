import PebbleBackground
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
    /// The model that runs here. The task engine takes its place from it.
    private let model = LocalStubModel()
    /// The real task engine: on this device only, reading the same notes,
    /// its tasks kept in `kept`, the one task store. Shared by Today and the
    /// background runner, so the summary counts the tasks Today shows. It
    /// follows the notes whatever the model, and starts tasks only with one
    /// that keeps every word here. None when the notes can't be opened.
    private let tasks: DeviceTaskEngine?
    /// Off until the person turns it on, and unavailable while
    /// Config/Cloud.local.xcconfig has no address. Its settings and private
    /// words are kept next to the notes, out of backups.
    ///
    /// Held, not observed: the body reads nothing from it, so a change to
    /// the setting must not re-run the body and rebuild the home screen.
    /// The screens that show it observe it themselves.
    @State private var cloud: CloudHelp
    /// The app's questions, shared by Today and the background runner, so
    /// anything the runner asks waits in the same Needs you.
    private let needsYou: NeedsYou
    /// Work done while the app is closed. Off until the person turns it on
    /// from the memory screen. Its runner is nil if its folder can't be made.
    private let background: BackgroundService
    /// Tasks and receipts kept while the app is closed. If the folder
    /// can't be opened they are kept in memory, and Forget everything still
    /// deletes a file an earlier launch left.
    private let kept: TaskStore

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        // Before launch finishes, so a nudge opened from the lock screen
        // reaches Today even when it starts the app. Asks for nothing.
        LocalQuestionNotifier.shared.install()
        let memory = try? MemoryStore.onDevice()
        self.memory = memory
        let kept = (try? TaskStore.onDevice()) ?? TaskStore.forgetOnly()
        self.kept = kept
        let model = self.model
        let tasks = memory.map { OnDeviceTasks.engine(model: model, notes: $0, store: kept) }
        self.tasks = tasks
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
        let asks = NeedsYou()
        needsYou = asks
        // Registered here, before launch ends, or the system won't run it.
        let wiring: BackgroundWiring
        #if DEBUG
        if let seeded = BackgroundSeed.launched() {
            wiring = .app(needsYou: asks, tasks: tasks, store: { seeded.store }, toggle: { seeded.toggle })
        } else {
            wiring = .app(needsYou: asks, tasks: tasks)
        }
        #else
        wiring = .app(needsYou: asks, tasks: tasks)
        #endif
        background = wiring.service
        background.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // scripts/screenshots.sh launches with -showcaseStill YES, so the
            // screen settles and two shots of it match.
            Group {
                if let scene = UserDefaults.standard.string(forKey: ShowcaseScene.launchKey).flatMap(ShowcaseScene.init(rawValue:)) {
                    scene.view(brand: brand)
                } else {
                    home
                }
            }
            .environment(\.holdsStill, UserDefaults.standard.bool(forKey: ShowcaseScene.stillKey))
            #else
            home
            #endif
        }
        .commands { HomeCommands() }
    }

    private var home: some View {
        HomeView(
            brand: brand,
            model: model,
            names: UserDefaultsAgentNameStore(),
            onboarding: UserDefaultsOnboardingStore(),
            memory: memory,
            needsYou: needsYou,
            tasks: tasks,
            kept: kept,
            notifier: LocalQuestionNotifier.shared,
            cloud: cloud,
            background: background.runner
        )
    }
}
