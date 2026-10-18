import PebbleBackground
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
    /// The app's questions, shared by Today and the background runner, so
    /// anything the runner asks waits in the same Needs you.
    private let needsYou: NeedsYou
    /// The app's task engine, shared by Today and the background runner,
    /// so the summary counts the tasks Today shows. `BackgroundWiring`
    /// gives it: there is none yet.
    private let tasks: (any TaskEngine)?
    /// Work done while the app is closed. Off until the person turns it on
    /// from the memory screen. Its runner is nil if its folder can't be made.
    private let background: BackgroundService
    /// Tasks and receipts kept while the app is closed. If the folder
    /// can't be opened they are kept in memory, and Forget everything still
    /// deletes a file an earlier launch left.
    private let kept: TaskStore

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
        _cloud = State(initialValue: CloudHelp.forApp(
            memory: try? MemoryStore.onDevice(),
            endpoint: CloudEndpoint.url(infoDictionary: Bundle.main.infoDictionary),
            openStore: { try CloudHelpFileStore.onDevice() }
        ))
        // Before launch finishes, so a nudge opened from the lock screen
        // reaches Today even when it starts the app. Asks for nothing.
        LocalQuestionNotifier.shared.install()
        kept = (try? TaskStore.onDevice()) ?? TaskStore.forgetOnly()
        let asks = NeedsYou()
        needsYou = asks
        // Registered here, before launch ends, or the system won't run it.
        let wiring: BackgroundWiring
        #if DEBUG
        if let seeded = BackgroundSeed.launched() {
            wiring = .app(needsYou: asks, store: { seeded.store }, toggle: { seeded.toggle })
        } else {
            wiring = .app(needsYou: asks)
        }
        #else
        wiring = .app(needsYou: asks)
        #endif
        tasks = wiring.tasks
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
            model: LocalStubModel(),
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
