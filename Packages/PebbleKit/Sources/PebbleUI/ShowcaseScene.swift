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
    /// The cloud setting off, the question before it turns on, and the
    /// preview of exactly what would leave the device.
    case cloudOff, cloudAsk, cloudPreview

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
            case .cloudOff, .cloudAsk:
                NavigationStack {
                    CloudHelpView(help: Self.sampleCloud(asking: self == .cloudAsk))
                }
            case .cloudPreview:
                Self.cloudPreviewChat(brand: brand, looks: looks)
            case .confirm, .confirmTimedOut:
                ZStack {
                    Backdrop()
                    // The timed out scene uses a window that has already passed.
                    let rule = AskFirst.isolated(window: self == .confirmTimedOut ? -1 : AskFirst.defaultWindow)
                    if let request = rule.ask(ProposedAction(
                            kind: .purchase,
                            recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.ca"),
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
            recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.ca"),
            details: "Sourdough loaf and two croissants, pickup tomorrow at 9",
            price: Price(minorUnits: 1450, currency: "CAD")
        ), at: now - 4 * 60)
        return asks
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

    /// A made up address on a domain kept for examples. Nothing is ever sent
    /// from the showcase: its transport refuses every request.
    static let sampleEndpoint = URL(string: "https://cloud.example.com")!

    /// The cloud setting, off, with one private word. `asking` opens on the
    /// question before turning it on.
    @MainActor
    static func sampleCloud(asking: Bool = false) -> CloudHelp {
        let help = CloudHelp(
            store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"])),
            endpoint: sampleEndpoint, memory: sampleMemory(), transport: { NoSendTransport() }
        )
        if asking { help.setOn(true) }
        return help
    }

    /// A chat on the cloud model with its preview showing. The preview is
    /// built by the same code a real reply uses.
    @MainActor
    static func cloudPreviewChat(brand: Brand, looks: UserDefaults) -> some View {
        let memory = sampleMemory()
        let help = CloudHelp(
            store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"])),
            endpoint: sampleEndpoint, memory: memory, transport: { NoSendTransport() }
        )
        let review = CloudReview()
        let model = help.chatModel(local: LocalStubModel(), review: review)
        var turns = Conversation.firstRun(named: "Pip", onDevice: false).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Help me write a note to Sam about Saturday. The party moved to 42 Maple Street. He can call me at 416 555 0199 or email jo.lee@example.com, and don't mention the lemon cake."))
        let conversation = Conversation(turns: turns, onDevice: false)
        let redactor = Redactor(memory: memory.notes(), privateWords: help.settings.privateWords)
        if let preview = try? CloudModel.preview(for: turns, endpoint: sampleEndpoint, redactor: redactor) {
            review.show(preview)
        }
        let controller = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: conversation, review: review)
        controller.isReplying = true
        return ZStack {
            Backdrop()
            ChatView(controller: controller, look: AgentLook.load(from: looks), firstMessage: nil)
        }
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

#if DEBUG
/// The showcase's transport. It sends nothing, ever.
struct NoSendTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data {
        throw CloudModelError.notSent
    }
}
#endif
