import Foundation
import PebbleCore
import PebbleModel
#if canImport(SwiftUI) && DEBUG
import SwiftUI

/// Fixed screens with sample content, used for screenshots and previews.
/// Nothing here reads or writes the person's real data.
public enum ShowcaseScene: String, CaseIterable, Sendable {
    case hello, name, look, ideas, memory, confirm, confirmTimedOut, firstChat
    /// The home screen after the first run, open on the chat and on the
    /// memory: the sidebar on a wide window, one column on a narrow one.
    case home, homeMemory, shortcuts
    /// Today with sample work, with a question waiting, and for a brand new
    /// person with nothing yet.
    case today, todayNeedsYou, todayEmpty
    /// A reply on its way, a new chat with its starters, a memory with
    /// nothing in it yet, and a note just saved.
    case thinking, newChat, memoryEmpty, memorySaved
    /// The cloud setting off, the question before it turns on, and the
    /// preview of exactly what would leave the device.
    case cloudOff, cloudAsk, cloudPreview
    /// Today with live task cards on the scripted engine, held still at a
    /// moment: working, trying another way, waiting on the person, and done.
    /// `tasksLive` plays the same tasks in real time.
    case taskRunning, taskRetrying, taskWaiting, taskDone, tasksLive
    /// Looking into something: the offer in the chat, the live card while it
    /// reads, and the summary with its sources. On the sample sources.
    case reconOffer, reconRunning, reconReady
    /// Today after background work: this morning's summary, made late
    /// because the device was locked, and yesterday's, which never ran.
    /// `memoryBackground` is the memory screen with background work on and
    /// the cloud setting's row, and `memoryBackgroundEnd` the same screen
    /// scrolled to its end, so a phone shows the switch and the cloud row
    /// together. `memoryForgetAsk` asks Forget everything with the summaries
    /// and the private words named, and `memorySummariesStayed` is the
    /// screen after Forget everything couldn't erase the summaries' file.
    case todaySummary, memoryBackground, memoryBackgroundEnd, memoryForgetAsk, memorySummariesStayed
    /// The dentist search reaching its one question: waiting in Needs you
    /// with the offer of a nudge, open in its sheet, its receipt after a
    /// yes, and its card after Not now. `askLive` plays it in real time and
    /// keeps it while the app is closed, for the UI tests.
    case askWaiting, askSheet, askAnswered, askClosed, askLive
    /// A task's question to send something, with how long the yes is for,
    /// and the memory screen listing what the agent may do without asking.
    /// `memoryUnavailableGrants` is the screen in its place when the notes
    /// couldn't be opened, still listing them.
    case confirmScopes, memoryGrants, memoryUnavailableGrants

    /// The launch argument that picks a scene. No name in it, product or
    /// codename, as `make brand-check` asks of new code.
    public static let launchKey = "showcaseScreen"
    /// `-showcaseStill YES` holds every gentle motion still, so the screen
    /// settles and two screenshots of it match.
    public static let stillKey = "showcaseStill"
    /// `-snapshotSheet YES` has the Mac's snapshot draw the sheet the scene
    /// presents, in a real window.
    public static let sheetKey = "snapshotSheet"
    /// `-snapshotDark YES` has the Mac's snapshot draw in dark mode.
    public static let darkKey = "snapshotDark"
    /// Launch with this set to keep what `askLive` kept last time, as the
    /// app does after it is closed. Without it, `askLive` starts fresh.
    public static let keepAsksKey = "showcaseKeepAsks"
    /// The throwaway suite the showcase keeps its looks in.
    static let looksSuite = "showcase.looks"

    @MainActor
    public func view(brand: Brand) -> some View {
        // A throwaway suite so the showcase never touches real choices.
        let looks = UserDefaults(suiteName: Self.looksSuite)!
        looks.removePersistentDomain(forName: Self.looksSuite)
        // Read the clock once, so the cards and the question agree.
        let morning = Self.morning
        return Group {
            switch self {
            case .home, .homeMemory:
                HomeView(
                    brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                    onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
                    looks: looks, conversation: Self.sampleFirstChat(),
                    section: self == .home ? .chat : .memory,
                    // Its own rule, so the showcase never touches the app's.
                    needsYou: needsYou(at: morning) ?? NeedsYou(rule: .isolated())
                )
            case .today, .todayNeedsYou, .todayEmpty:
                HomeView(
                    brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                    onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
                    looks: looks, conversation: Self.sampleFirstChat(), section: .today,
                    feed: self == .todayEmpty ? [EmptyFeedSource()] : [SampleFeedSource()],
                    needsYou: needsYou(at: morning) ?? NeedsYou(rule: .isolated()),
                    now: { morning }
                )
            case .taskRunning, .taskRetrying, .taskWaiting, .taskDone, .tasksLive,
                 .askWaiting, .askSheet, .askAnswered, .askClosed, .askLive:
                taskHome(brand: brand, looks: looks)
                    .overlay(alignment: .topLeading) {
                        if self == .askLive { NudgePermissionProbe() }
                    }
            case .todaySummary:
                summaryHome(brand: brand, looks: looks, at: morning)
            case .reconOffer:
                HomeView(
                    brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                    onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
                    looks: looks, conversation: Self.sampleFirstChat(), section: .chat,
                    feed: [SampleFeedSource()], needsYou: needsYou(at: morning) ?? NeedsYou(rule: .isolated()),
                    now: { morning }, chatLine: Self.reconRequest
                )
            case .reconRunning, .reconReady:
                reconHome(brand: brand, looks: looks)
            case .shortcuts:
                KeyboardShortcutsView()
            case .hello, .name, .look, .ideas:
                OnboardingView(
                    brand: brand,
                    names: InMemoryAgentNameStore(),
                    store: InMemoryOnboardingStore(),
                    looks: looks,
                    // The showcase plays the on-device model, as the app does.
                    place: LocalStubModel().privacyPlace,
                    startAt: page,
                    draftName: self == .name || self == .look || self == .ideas ? "Pip" : ""
                ) { _ in }
            case .firstChat:
                ZStack {
                    Backdrop()
                    ChatView(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                             look: AgentLook.load(from: looks), firstMessage: nil,
                             conversation: Self.sampleFirstChat())
                }
            case .thinking, .newChat:
                ZStack {
                    Backdrop()
                    ChatView(controller: self == .thinking ? Self.thinkingChat(brand: brand)
                                 : ChatController.make(brand: brand, model: LocalStubModel(),
                                                       names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil),
                             look: AgentLook.load(from: looks), firstMessage: nil)
                }
            case .memory:
                MemoryView(store: Self.sampleMemory(), place: LocalStubModel().privacyPlace,
                           background: Self.sampleBackground(on: false, at: morning))
            case .memoryBackground:
                // With the cloud setting too, as the app shows it once a
                // cloud model is set up, so the whole screen is seen.
                MemoryView(store: Self.sampleMemory(), place: LocalStubModel().privacyPlace, cloud: Self.sampleCloud(),
                           background: Self.sampleBackground(on: true, at: morning))
            case .memoryBackgroundEnd:
                MemoryView(store: Self.sampleMemory(), place: LocalStubModel().privacyPlace, cloud: Self.sampleCloud(),
                           background: Self.sampleBackground(on: true, at: morning))
                    .defaultScrollAnchor(.bottom)
            case .memoryForgetAsk:
                Self.forgetAskMemory(at: morning)
            case .memorySummariesStayed:
                Self.summariesStayedMemory(at: morning)
                    .defaultScrollAnchor(.bottom)
            case .memoryEmpty:
                MemoryView(store: Self.emptyMemory(), place: LocalStubModel().privacyPlace)
            case .memoryGrants:
                MemoryView(store: Self.emptyMemory(), place: LocalStubModel().privacyPlace,
                           grants: Self.sampleGrants(at: morning))
            case .memoryUnavailableGrants:
                MemoryUnavailableView(hasTasks: false, grants: Self.sampleGrants(at: morning), onForgetTasks: {})
            case .memorySaved:
                MemoryView(model: Self.savedNoteMemory(place: LocalStubModel().privacyPlace),
                           place: LocalStubModel().privacyPlace)
            case .cloudOff, .cloudAsk:
                NavigationStack {
                    // With the cloud off and no cloud chat open, the flag
                    // is the on-device model's, as `HomeView` would give it.
                    CloudHelpView(help: Self.sampleCloud(),
                                  place: HomeView.surfacePlace(chat: LocalStubModel().privacyPlace,
                                                               newChat: LocalStubModel().privacyPlace),
                                  asking: self == .cloudAsk)
                }
            case .cloudPreview:
                Self.cloudPreviewChat(brand: brand, looks: looks)
            case .confirm, .confirmTimedOut, .confirmScopes:
                ZStack {
                    Backdrop()
                    if let sheet = sampleSheet {
                        ConfirmationSheet(request: sheet.request, rule: sheet.rule, isExample: sheet.isExample,
                                          onApprove: { _ in }, onGrant: sheet.offersGrants ? { _ in } : nil,
                                          onDecline: {})
                    }
                }
            }
        }
    }

    /// A sample question shown in a confirmation sheet of its own.
    struct SampleSheet {
        let request: ConfirmationRequest
        let rule: AskFirst
        /// Always true: a sample sheet says it is an example.
        let isExample: Bool
        /// True when the sheet offers how long the yes is for.
        var offersGrants = false
    }

    /// A sample task's question to send a note, asked as a task asks it, so
    /// the sheet offers every choice of how long the yes is for.
    static let sampleSend = ProposedAction(
        kind: .send,
        // A reserved name, so the example never points at a real address.
        recipient: Recipient(id: "contact:sample-sam", displayName: "Sam", handle: "sam@example.com"),
        details: "Running ten minutes late, see you at the cafe.",
        outcome: "I'll send this to Sam now."
    )

    /// The key the sample task asks with.
    static let sampleTaskKey = "showcase/task:1"

    /// The sheet the question scenes show, asked through a rule of its own.
    /// The timed out scene uses a window that has already passed.
    var sampleSheet: SampleSheet? {
        if self == .confirmScopes {
            let rule = AskFirst.isolated(grants: .inMemory())
            guard case .asking(let request) = rule.ask(Self.sampleSend, forTask: Self.sampleTaskKey) else { return nil }
            return SampleSheet(request: request, rule: rule, isExample: true, offersGrants: true)
        }
        guard self == .confirm || self == .confirmTimedOut else { return nil }
        let rule = AskFirst.isolated(window: self == .confirmTimedOut ? -1 : AskFirst.defaultWindow)
        guard let request = rule.ask(ProposedAction(
            kind: .purchase,
            recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.example"),
            details: "Sourdough loaf and two croissants, pickup at 9",
            price: Price(minorUnits: 1450, currency: "CAD")
        )) else { return nil }
        return SampleSheet(request: request, rule: rule, isExample: true)
    }

    /// The questions a home screen scene has waiting, which Today's cards
    /// open in the confirmation sheet. Nil for scenes without a home screen.
    /// The task scenes ask through `rule`, the one their tasks share.
    func needsYou(at now: Date = morning, rule: AskFirst = .isolated()) -> NeedsYou? {
        switch self {
        case .todayNeedsYou, .todaySummary: Self.sampleQuestion(at: now)
        case .today, .todayEmpty, .home, .homeMemory: NeedsYou(rule: .isolated())
        case .reconOffer: NeedsYou(rule: .isolated())
        case .taskRunning, .taskRetrying, .taskWaiting, .taskDone, .tasksLive, .reconRunning, .reconReady,
             .askWaiting, .askSheet, .askAnswered, .askClosed, .askLive: NeedsYou(rule: rule)
        default: nil
        }
    }

    /// The scripted tasks a scene shows, asking through `rule`. Nil for
    /// scenes without tasks.
    @MainActor
    func tasks(rule: AskFirst) -> (any TaskEngine)? {
        switch self {
        case .tasksLive: Self.liveTasks(rule: rule)
        case .taskRunning, .taskRetrying, .taskWaiting, .taskDone: Self.sampleTasks(self, rule: rule)
        case .reconRunning, .reconReady: Self.sampleRecon(ready: self == .reconReady, rule: rule)
        case .askWaiting, .askSheet, .askAnswered, .askClosed: Self.askTasks(self, rule: rule)
        case .askLive: Self.liveAsks().engine
        default: nil
        }
    }

    /// Where an ask scene keeps its tasks and receipts. In memory, except
    /// for `askLive`, whose file outlasts the app being closed. Nil for
    /// scenes that keep nothing.
    @MainActor
    func kept() -> TaskStore? {
        switch self {
        case .askLive: return Self.liveAsks().store
        case .askWaiting, .askSheet, .askAnswered, .askClosed:
            if let store = Self.askStores[self] { return store }
            let store = TaskStore.inMemory()
            Self.askStores[self] = store
            return store
        default: return nil
        }
    }

    @MainActor private static var askStores: [ShowcaseScene: TaskStore] = [:]
    @MainActor private static var liveAsk: (rule: AskFirst, engine: LocalFakeEngine, store: TaskStore)?

    /// The one live ask scene for this launch: its rule, engine and store,
    /// made once so the screen and its question always agree.
    @MainActor
    static func liveAsks() -> (rule: AskFirst, engine: LocalFakeEngine, store: TaskStore) {
        if let liveAsk { return liveAsk }
        let temporary = FileManager.default.temporaryDirectory
        let store = TaskStore(fileURL: temporary.appendingPathComponent("showcase-asks.json"),
                              forgetMarker: temporary.appendingPathComponent("showcase-asks-pending", isDirectory: true)
                                  .appendingPathComponent("tasks-forgotten"))
        if !UserDefaults.standard.bool(forKey: keepAsksKey) { store.reset() }
        let rule = AskFirst.isolated()
        // Played to the moment the dentist search asks, so the question
        // opens as the app does. Kept tasks come back instead, when there are any.
        let engine = LocalFakeEngine(rule: rule, scripts: Self.liveScripts(), origin: Date() - 42)
        if store.tasks.isEmpty && store.receipts.isEmpty {
            engine.start(liveDentist)
        }
        engine.advance(by: 42)
        let made = (rule: rule, engine: engine, store: store)
        liveAsk = made
        return made
    }

    /// Launch with this many seconds to make the held visit take that long
    /// after a yes, so a UI test can close the app while it is under way.
    public static let holdSecondsKey = "showcaseHoldSeconds"

    /// Every sample script for `askLive`, the dentist search swapped for
    /// `liveDentist` wherever it is in `all`.
    static func liveScripts(_ all: [TaskScript] = SampleTasks.all) -> [TaskScript] {
        [liveDentist] + all.filter { $0.title != SampleTasks.dentist.title }
    }

    /// The dentist search for `askLive`, its held visit as long as asked.
    static var liveDentist: TaskScript {
        let hold = UserDefaults.standard.double(forKey: holdSecondsKey)
        guard hold > 0, let last = SampleTasks.dentist.steps.last else { return SampleTasks.dentist }
        let held = TaskScript.Step(last.text, kind: last.kind, duration: hold, kept: last.kept, todo: last.todo)
        return TaskScript(title: SampleTasks.dentist.title, steps: SampleTasks.dentist.steps.dropLast() + [held],
                          determinate: SampleTasks.dentist.determinate, doneLine: SampleTasks.dentist.doneLine,
                          result: SampleTasks.dentist.result)
    }

    /// The dentist search at its question, and after it is answered.
    /// Nothing here is really done. Each call starts the scene's store over.
    ///
    /// The search asks at 42 seconds and holds the visit in 4 more after a
    /// yes. The plan, started at 20, is done at 42.
    @MainActor
    static func askTasks(_ scene: ShowcaseScene, rule: AskFirst) -> LocalFakeEngine {
        let store = scene.kept()
        store?.reset()
        // The waiting scene shows the offer of a nudge; the others have had it.
        if scene != .askWaiting { store?.setNudges(.declined) }
        let at: TimeInterval = scene == .askWaiting || scene == .askSheet ? 42 : 50
        let engine = LocalFakeEngine(rule: rule, origin: morning - at)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 20)
        engine.start(SampleTasks.plan)
        engine.advance(by: 22)
        if let task = engine.tasks.first(where: { $0.title == SampleTasks.dentistTitle }), let question = task.question {
            // Answered through the sheet's own state, as a tap would.
            let sheet = ConfirmationState(request: question, rule: rule,
                                          onApprove: { _ = engine.resume(task.id, with: $0) },
                                          onDecline: { engine.questionClosed(question) })
            switch scene {
            case .askAnswered: sheet.tapPrimary()
            case .askClosed: sheet.cancel()
            default: break
            }
        }
        engine.advance(by: at - 42)
        return engine
    }

    /// Nudges for the still ask scenes: the system has not been asked, and
    /// nothing is ever posted.
    final class StillNotifier: QuestionNotifying, @unchecked Sendable {
        func permission() async -> NudgePermission { .notDetermined }
        func requestPermission() async -> Bool { false }
        func post(_ nudge: QuestionNudge, after delay: TimeInterval) {}
        func remove(_ ids: [String]) {}
        func removeAll() {}
        func forget() {}
        func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
    }

    /// For the UI tests, in `askLive` only: what the system says about
    /// nudges as the scene opens, so a test meets a simulator that was
    /// asked before with a clear failure, not a confusing one later. Too
    /// small and clear to be seen.
    struct NudgePermissionProbe: View {
        @State private var permission = "checking"

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(permission)
                .accessibilityIdentifier("nudgePermission")
                .task {
                    #if canImport(UserNotifications)
                    guard LocalQuestionNotifier.shared.installed else { return }
                    permission = String(describing: await LocalQuestionNotifier.shared.permission())
                    #endif
                }
        }
    }

    /// How an ask scene nudges: the real notifications for `askLive`, so
    /// the UI tests meet the system's own question, and none for the rest.
    var notifier: (any QuestionNotifying)? {
        switch self {
        #if canImport(UserNotifications)
        case .askLive: LocalQuestionNotifier.shared
        #endif
        case .askWaiting, .askSheet, .askAnswered, .askClosed: StillNotifier()
        default: nil
        }
    }

    /// Whether every confirmation sheet this scene can show says it is an
    /// example: its own sample sheet, the sheet a waiting question opens
    /// from Today, which follows `NeedsYou.isSample`, or the sheet a task's
    /// Approve opens, which follows the engine's `isSample`. Any task may
    /// come to ask, so a scene with tasks counts even before one does. Nil
    /// when the scene can show no question at all.
    @MainActor
    var confirmationSheetsAreExamples: Bool? {
        if let sheet = sampleSheet { return sheet.isExample }
        var examples: [Bool] = []
        if let asks = needsYou(), !asks.items(now: Self.morning).isEmpty { examples.append(asks.isSample) }
        if let tasks = tasks(rule: .isolated()), !tasks.tasks.isEmpty { examples.append(tasks.isSample) }
        return examples.isEmpty ? nil : !examples.contains(false)
    }

    /// Today at 9:40, so the feed's times sit just before the 9:41 the
    /// screenshots show in the status bar.
    static var morning: Date {
        Calendar.current.date(bySettingHour: 9, minute: 40, second: 0, of: Date()) ?? Date()
    }

    /// One purchase waiting for a yes, asked through its own rule so the
    /// showcase never touches the app's. Marked as an example, so its card
    /// and its sheet say so.
    static func sampleQuestion(at now: Date = morning) -> NeedsYou {
        let asks = NeedsYou(rule: .isolated(), isSample: true)
        asks.ask(ProposedAction(
            kind: .purchase,
            recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.example"),
            details: "Sourdough loaf and two croissants, pickup tomorrow at 9",
            price: Price(minorUnits: 1450, currency: "CAD")
        ), at: now - 4 * 60)
        return asks
    }

    /// Today with the scripted tasks. Questions from the tasks and the feed
    /// share one rule of their own, so the showcase never touches the app's.
    @MainActor
    private func taskHome(brand: Brand, looks: UserDefaults) -> HomeView {
        // The live ask scene keeps one rule for the launch, the one its
        // kept question is asked again through.
        let rule = self == .askLive ? Self.liveAsks().rule : AskFirst.isolated()
        let live = self == .tasksLive || self == .askLive
        let morning = Self.morning
        return HomeView(
            brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
            onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
            looks: looks, conversation: Self.sampleFirstChat(), section: .today,
            feed: [SampleFeedSource()], needsYou: needsYou(at: morning, rule: rule) ?? NeedsYou(rule: rule),
            tasks: tasks(rule: rule),
            drivesTasks: live,
            kept: kept(), notifier: notifier, opensQuestion: self == .askSheet,
            now: { @Sendable in live ? Date() : morning }
        )
    }

    /// Today looking into the pool reopening. The recon and the feed share
    /// one rule of their own, as the task scenes do.
    @MainActor
    private func reconHome(brand: Brand, looks: UserDefaults) -> HomeView {
        let rule = AskFirst.isolated()
        let morning = Self.morning
        return HomeView(
            brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
            onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
            looks: looks, conversation: Self.sampleFirstChat(), section: .today,
            feed: [SampleFeedSource()], needsYou: needsYou(at: morning, rule: rule) ?? NeedsYou(rule: rule),
            tasks: tasks(rule: rule),
            now: { morning }
        )
    }

    /// The scripted tasks, played to the moment each scene shows, so the
    /// engine's clock lands on 9:40. Nothing here is really done.
    ///
    /// With the standard retry policy the dentist search finds its list at
    /// 6 seconds, hangs on Saturday hours until 26, tries again at 28,
    /// reads reviews from 36 and asks for a yes at 42. The plan is done
    /// after 22. The lunch menu hangs three times and asks at 66.
    @MainActor
    static func sampleTasks(_ scene: ShowcaseScene, rule: AskFirst) -> LocalFakeEngine {
        // When each scene stops: seconds since the first task began.
        let at: TimeInterval = switch scene {
        case .taskRetrying: 31
        case .taskWaiting: 68
        case .taskDone: 80
        default: 39
        }
        let engine = LocalFakeEngine(rule: rule, origin: morning - at)
        switch scene {
        case .taskWaiting:
            engine.start(SampleTasks.lunch)
            engine.advance(by: 24)
            engine.start(SampleTasks.dentist)
            engine.advance(by: at - 24)
        case .taskDone:
            engine.start(SampleTasks.dentist)
            engine.advance(by: 20)
            engine.start(SampleTasks.plan)
            engine.advance(by: 43 - 20)
            // The yes goes through the sheet's own state, as a tap on Yes would.
            if let task = engine.tasks.first(where: { $0.title == SampleTasks.dentistTitle }), let question = task.question {
                let sheet = ConfirmationState(request: question, rule: rule,
                                              onApprove: { _ = engine.resume(task.id, with: $0) }, onDecline: {})
                sheet.tapPrimary()
            }
            engine.advance(by: at - 43)
        default:
            engine.start(SampleTasks.dentist)
            engine.advance(by: 30)
            if scene == .taskRunning { engine.start(SampleTasks.plan) }
            engine.advance(by: at - 30)
        }
        return engine
    }

    /// What the person says in the offer scene.
    static let reconRequest = "Can you look into the Riverside pool reopening for me?"

    /// Looking into the pool reopening on the scripted engine, with the
    /// sample sources, played to the moment the scene shows: reading the
    /// sources, or done. The engine's clock lands on 9:40.
    @MainActor
    static func sampleRecon(ready: Bool, rule: AskFirst) -> ReconRunner {
        let at: TimeInterval = ready ? 16 : 4
        let engine = LocalFakeEngine(rule: rule, origin: morning - at)
        // Pages dated by the engine's clock, so they read as days old at 9:40.
        let runner = ReconRunner(engine: engine, provider: SampleSources(now: { [engine] in engine.currentDate }))
        runner.lookInto(SampleSources.poolTopic)
        engine.advance(by: at)
        return runner
    }

    /// Today with the cards background work left. The summary counted a
    /// copy of the sample question Today shows, asked through a rule of
    /// its own, so the showcase never touches the app's.
    @MainActor
    private func summaryHome(brand: Brand, looks: UserDefaults, at morning: Date) -> HomeView {
        HomeView(
            brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
            onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
            looks: looks, conversation: Self.sampleFirstChat(), section: .today,
            needsYou: needsYou(at: morning) ?? NeedsYou(rule: .isolated()),
            background: Self.sampleBackground(on: true, needsYou: Self.sampleQuestion(at: morning), played: true,
                                              at: morning),
            now: { morning }
        )
    }

    /// A runner that keeps nothing on disk, marked as an example, so
    /// nothing here touches the person's own and no launch leaves a file
    /// behind. It plays as if the app had been running all along.
    /// `played` runs it through two mornings: yesterday's held back by Low
    /// Power Mode until its day ended, and today's held back before the
    /// first unlock, then made at `morning`. It has no tasks, as the app
    /// has none yet, so the missed day leaves no card, just as in the app.
    static func sampleBackground(on: Bool, needsYou: NeedsYou? = nil, played: Bool = false,
                                 at morning: Date, store: BackgroundStore = .memoryOnly()) -> BackgroundRunner {
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(),
                                      needsYou: needsYou, watchingSince: .distantPast, sample: true)
        guard on else { return runner }
        let calendar = Calendar.current
        let today = BackgroundPlan.morning(of: morning, calendar: calendar)
        guard played, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            runner.turnOn(now: morning)
            return runner
        }
        runner.turnOn(now: yesterday - 60 * 60)
        runner.runDue(now: yesterday + 60, conditions: BackgroundConditions(moment: .background, lowPower: true))
        runner.runDue(now: today + 60, conditions: BackgroundConditions(moment: .background, fileShut: true))
        runner.runDue(now: morning - 5 * 60, conditions: .foreground)
        return runner
    }

    /// Every sample task from the start, played in real time.
    static func liveTasks(rule: AskFirst) -> LocalFakeEngine {
        let engine = LocalFakeEngine(rule: rule)
        for script in SampleTasks.all { engine.start(script) }
        return engine
    }

    /// The morning starter played through the on-device model.
    static func sampleFirstChat() -> Conversation {
        var turns = Conversation.firstRun(named: "Pip", place: LocalStubModel().privacyPlace).turns
        let prompt = FirstConversation.jobs.first { $0.id == "morning" }?.prompt ?? ""
        for said in [prompt, "school drop off, gym, answer Priya, groceries"] {
            turns.append(ChatTurn(id: UUID(), speaker: .person, text: said))
            let reply = (try? LocalStubModel.answer(to: turns)) ?? LocalStubModel.fallback
            turns.append(ChatTurn(id: UUID(), speaker: .agent, text: reply))
        }
        return Conversation(turns: turns, place: LocalStubModel().privacyPlace)
    }

    /// The person has just asked for a morning plan and the dots are showing.
    /// Nothing is sent to the model; the reply never comes.
    @MainActor
    static func thinkingChat(brand: Brand) -> ChatController {
        var turns = Conversation.firstRun(named: "Pip", place: LocalStubModel().privacyPlace).turns
        let prompt = FirstConversation.jobs.first { $0.id == "morning" }?.prompt ?? ""
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: prompt))
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: Conversation(turns: turns, place: LocalStubModel().privacyPlace))
        controller.isReplying = true
        return controller
    }

    /// A made up address on a domain kept for examples. Nothing is ever sent
    /// from the showcase: its transport refuses every request.
    static let sampleEndpoint = URL(string: "https://cloud.example.com")!

    /// The cloud setting, off, with one private word.
    @MainActor
    static func sampleCloud(privateWords: [String] = ["lemon cake"]) -> CloudHelp {
        CloudHelp(
            store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: false, privateWords: privateWords)),
            endpoint: sampleEndpoint, memory: sampleMemory(), transport: { NoSendTransport() }
        )
    }

    /// The memory screen with background work on and the cloud setting,
    /// asking Forget everything, so its words name the summaries and the
    /// private words.
    @MainActor
    static func forgetAskMemory(at morning: Date) -> some View {
        let cloud = sampleCloud()
        let model = MemoryModel(store: sampleMemory(), place: LocalStubModel().privacyPlace,
                                alsoForget: MemoryView.alsoForget(cloud),
                                background: sampleBackground(on: true, at: morning), now: { morning })
        return MemoryView(model: model, place: LocalStubModel().privacyPlace, cloud: cloud)
            .onAppear { model.askForgetEverything = true }
    }

    /// The memory screen just after Forget everything, when every note and
    /// private word went but the summaries' file couldn't be erased. It runs
    /// a real Forget everything against a store that won't erase, so it
    /// shows what that leaves: work while away is off, its cards are gone,
    /// Forget everything stays so it can be tried again, and the line is
    /// the one said for that outcome. Nothing here is kept anywhere: the
    /// note's scratch file goes with the forget.
    @MainActor
    static func summariesStayedMemory(at morning: Date) -> some View {
        let (model, cloud) = summariesStayedModel(at: morning)
        return MemoryView(model: model, place: LocalStubModel().privacyPlace, cloud: cloud)
    }

    /// The memory screen's model for `summariesStayedMemory`, after its
    /// Forget everything has run.
    @MainActor
    static func summariesStayedModel(at morning: Date) -> (MemoryModel, CloudHelp) {
        let store = BackgroundStore.memoryOnly(faults: BackgroundStoreFaults(eraseFails: true))
        let runner = sampleBackground(on: true, needsYou: sampleQuestion(at: morning), played: true, at: morning,
                                      store: store)
        let notes = MemoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("showcase-forgotten-memory-\(UUID().uuidString).json"))
        _ = try? notes.remember("Sam's birthday is May 14. Loves lemon cake.", source: .toldMe)
        let cloud = sampleCloud()
        let model = MemoryModel(store: notes, place: LocalStubModel().privacyPlace,
                                alsoForget: MemoryView.alsoForget(cloud), background: runner, now: { morning })
        model.forgetEverything()
        return (model, cloud)
    }

    /// A chat on the cloud model with its preview showing, presented the
    /// way `HomeView` presents it. The preview is built by the same code a
    /// real reply uses.
    @MainActor
    static func cloudPreviewChat(brand: Brand, looks: UserDefaults) -> some View {
        let memory = sampleMemory()
        let auth = SampleSignIn()
        let help = CloudHelp(
            store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: sampleEndpoint, privateWords: ["lemon cake"])),
            endpoint: sampleEndpoint, memory: memory, auth: auth, transport: { NoSendTransport() }
        )
        let review = CloudReview()
        let model = help.chatModel(local: LocalStubModel(), review: review)
        var turns = Conversation.firstRun(named: "Pip", place: model.privacyPlace).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Help me write a note to Sam about Saturday. The party moved to 42 Maple Street. He can call me at 416 555 0199 or email jo.lee@example.com, and don't mention the lemon cake."))
        let conversation = Conversation(turns: turns, place: model.privacyPlace)
        let redactor = Redactor(memory: memory.notes(), privateWords: help.settings.privateWords)
        if let preview = try? CloudModel.preview(for: turns, endpoint: sampleEndpoint, redactor: redactor,
                                                 headers: auth.headers(for: CloudModel.url(for: sampleEndpoint)),
                                                 signIn: auth.signIn(for: sampleEndpoint)) {
            review.show(preview)
        }
        let controller = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: conversation, review: review)
        controller.isReplying = true
        return ZStack {
            Backdrop()
            ChatView(controller: controller, look: AgentLook.load(from: looks), firstMessage: nil, covered: true)
        }
        .cloudPreview(review)
    }

    static func emptyMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-empty-memory-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        try? store.forgetEverything()
        return store
    }

    /// A first note, just added the way a person adds one, so the saved
    /// line shows under it. The note goes to a scratch file of its own,
    /// which is removed once it is saved: the model keeps what it read, so
    /// the screen still shows the note and nothing is left behind.
    @MainActor
    static func savedNoteMemory(place: PrivacyPlace) -> MemoryModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("showcase-saved-memory-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        let model = MemoryModel(store: store, place: place)
        model.newNote = "Sam's birthday is May 14. Loves lemon cake."
        model.add()
        try? store.forgetEverything()
        return model
    }

    private var page: OnboardingView.Page {
        switch self {
        case .name: .name
        case .look: .look
        case .ideas: .ideas
        default: .hello
        }
    }

    /// Grants for the memory screen's list, each made the one way there is:
    /// a question asked, a choice picked on its sheet and its yes tapped.
    /// In memory only, and nothing is really allowed by them.
    @MainActor
    static func sampleGrants(at now: Date) -> GrantBook {
        let book = GrantBook.inMemory(now: { now })
        let rule = AskFirst.isolated(grants: book)
        let picks: [(ProposedAction, GrantChoice)] = [
            (sampleSend, .always),
            (ProposedAction(kind: .send,
                            recipient: Recipient(id: "contact:sample-priya", displayName: "Priya",
                                                 handle: "+1 555 0142"),
                            details: "The book club moved to Thursday."), .untilTonight),
            (SampleTasks.holdVisit, .forThisTask),
        ]
        for (action, choice) in picks {
            guard case .asking(let request) = rule.ask(action, forTask: sampleTaskKey) else { continue }
            let state = ConfirmationState(request: request, rule: rule, wallClock: { now },
                                          onApprove: { _ in }, onGrant: { book.add($0) }, onDecline: {})
            state.choose(choice)
            state.tapPrimary()
        }
        return book
    }

    static func sampleMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-memory.json")
        let store = MemoryStore(fileURL: url)
        try? store.forgetEverything()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSinceReferenceDate: 813_000_000)
        _ = try? store.remember("Sam's birthday is May 14. Loves lemon cake.", at: now - 9 * day, source: .toldMe)
        _ = try? store.remember("Dentist on Thursday at 3", at: now - 4 * day, source: .fromApp("Calendar"))
        _ = try? store.remember("Prefers tea in the afternoon", at: now - day, source: .inferred)
        return store
    }
}
#endif

#if DEBUG
/// The showcase's transport. It sends nothing, ever.
struct NoSendTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data {
        throw CloudModelError.notSent
    }
}

/// The showcase's sign-in: a made-up sign-in hop, so the preview shows how
/// one looks ahead of the message, and one made-up header, so it shows a
/// sign-in label with its value covered and VoiceOver leaving it out.
/// Tests give it other values, to see what sign-in may never carry.
struct SampleSignIn: CloudAuth {
    var header = "made-up-sample"
    var device = "made-up-sample-device"
    var headerName = "X-Sample-Sign-In"
    var bodyKey = "device"

    func headers(for url: URL) -> [String: String] { [headerName: header] }

    func signIn(for endpoint: URL) -> CloudSignIn? {
        let body = (try? JSONEncoder().encode([bodyKey: device])) ?? Data()
        return CloudSignIn(path: "v1/sign-in", body: body)
    }
}
#endif
