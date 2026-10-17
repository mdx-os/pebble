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
    /// A reply on its way, a new chat with its starters, and a memory with
    /// nothing in it yet.
    case thinking, newChat, memoryEmpty
    /// Today with live task cards on the scripted engine, held still at a
    /// moment: working, trying another way, waiting on the person, and done.
    /// `tasksLive` plays the same tasks in real time.
    case taskRunning, taskRetrying, taskWaiting, taskDone, tasksLive

    public static let launchKey = "pebbleScreen"

    @MainActor
    public func view(brand: Brand) -> some View {
        // A throwaway suite so the showcase never touches real choices.
        let looks = UserDefaults(suiteName: "pebble.showcase")!
        looks.removePersistentDomain(forName: "pebble.showcase")
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
                    needsYou: NeedsYou(rule: .isolated())
                )
            case .today, .todayNeedsYou, .todayEmpty:
                HomeView(
                    brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                    onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
                    looks: looks, conversation: Self.sampleFirstChat(), section: .today,
                    feed: self == .todayEmpty ? [EmptyFeedSource()] : [SampleFeedSource()],
                    needsYou: self == .todayNeedsYou ? Self.sampleQuestion(at: morning) : NeedsYou(rule: .isolated()),
                    now: { morning }
                )
            case .taskRunning, .taskRetrying, .taskWaiting, .taskDone, .tasksLive:
                taskHome(brand: brand, looks: looks)
            case .shortcuts:
                KeyboardShortcutsView()
            case .hello, .name, .look, .ideas:
                OnboardingView(
                    brand: brand,
                    names: InMemoryAgentNameStore(),
                    store: InMemoryOnboardingStore(),
                    looks: looks,
                    // The showcase plays the on-device model, as the app does.
                    onDevice: LocalStubModel().runsOnDevice,
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
                MemoryView(store: Self.sampleMemory())
            case .memoryEmpty:
                MemoryView(store: Self.emptyMemory())
            case .confirm, .confirmTimedOut:
                ZStack {
                    Backdrop()
                    // The timed out scene uses a window that has already passed.
                    let rule = AskFirst.isolated(window: self == .confirmTimedOut ? -1 : AskFirst.defaultWindow)
                    if let request = rule.ask(ProposedAction(
                            kind: .purchase,
                            recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.example"),
                            details: "Sourdough loaf and two croissants, pickup at 9",
                            price: Price(minorUnits: 1450, currency: "CAD")
                        )) {
                        ConfirmationSheet(request: request, rule: rule, onApprove: { _ in }, onDecline: {})
                    }
                }
            }
        }
    }

    /// Today at 9:40, so the feed's times sit just before the 9:41 the
    /// screenshots show in the status bar.
    static var morning: Date {
        Calendar.current.date(bySettingHour: 9, minute: 40, second: 0, of: Date()) ?? Date()
    }

    /// One purchase waiting for a yes, asked through its own rule so the
    /// showcase never touches the app's.
    static func sampleQuestion(at now: Date = morning) -> NeedsYou {
        let asks = NeedsYou(rule: .isolated())
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
        let rule = AskFirst.isolated()
        let live = self == .tasksLive
        return HomeView(
            brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
            onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
            looks: looks, conversation: Self.sampleFirstChat(), section: .today,
            feed: [SampleFeedSource()], needsYou: NeedsYou(rule: rule),
            tasks: live ? Self.liveTasks(rule: rule) : Self.sampleTasks(self, rule: rule),
            drivesTasks: live,
            now: live ? { Date() } : { Self.morning }
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

    /// Every sample task from the start, played in real time.
    static func liveTasks(rule: AskFirst) -> LocalFakeEngine {
        let engine = LocalFakeEngine(rule: rule)
        for script in SampleTasks.all { engine.start(script) }
        return engine
    }

    /// The morning starter played through the on-device model.
    static func sampleFirstChat() -> Conversation {
        var turns = Conversation.firstRun(named: "Pip", onDevice: true).turns
        let prompt = FirstConversation.jobs.first { $0.id == "morning" }?.prompt ?? ""
        for said in [prompt, "school drop off, gym, answer Priya, groceries"] {
            turns.append(ChatTurn(id: UUID(), speaker: .person, text: said))
            let reply = (try? LocalStubModel.answer(to: turns)) ?? LocalStubModel.fallback
            turns.append(ChatTurn(id: UUID(), speaker: .agent, text: reply))
        }
        return Conversation(turns: turns, onDevice: true)
    }

    /// The person has just asked for a morning plan and the dots are showing.
    /// Nothing is sent to the model; the reply never comes.
    @MainActor
    static func thinkingChat(brand: Brand) -> ChatController {
        var turns = Conversation.firstRun(named: "Pip", onDevice: true).turns
        let prompt = FirstConversation.jobs.first { $0.id == "morning" }?.prompt ?? ""
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: prompt))
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: Conversation(turns: turns, onDevice: true))
        controller.isReplying = true
        return controller
    }

    static func emptyMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-empty-memory-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        try? store.forgetEverything()
        return store
    }

    private var page: OnboardingView.Page {
        switch self {
        case .name: .name
        case .look: .look
        case .ideas: .ideas
        default: .hello
        }
    }

    static func sampleMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-showcase-memory.json")
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
