import Foundation
import PebbleCore
import PebbleModel
#if canImport(SwiftUI) && DEBUG
import SwiftUI

/// Fixed screens with sample content, used for screenshots and previews.
/// Nothing here reads or writes the person's real data.
public enum ShowcaseScene: String, CaseIterable, Sendable {
    case hello, name, look, ideas, memory, confirm, confirmTimedOut, firstChat
    /// The home screen after the first run: the sidebar on a wide window,
    /// one column on a narrow one.
    case home, homeMemory, shortcuts
    /// A reply on its way, a new chat with its starters, a memory with
    /// nothing in it yet, and a note just saved.
    case thinking, newChat, memoryEmpty, memorySaved

    public static let launchKey = "pebbleScreen"

    @MainActor
    public func view(brand: Brand) -> some View {
        // A throwaway suite so the showcase never touches real choices.
        let looks = UserDefaults(suiteName: "pebble.showcase")!
        looks.removePersistentDomain(forName: "pebble.showcase")
        return Group {
            switch self {
            case .home, .homeMemory:
                HomeView(
                    brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                    onboarding: InMemoryOnboardingStore(finished: true), memory: Self.sampleMemory(),
                    looks: looks, conversation: Self.sampleFirstChat(),
                    section: self == .home ? .chat : .memory
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
                    onDevice: LocalStubModel().privacyPlace.staysOnDevice,
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
                MemoryView(store: Self.sampleMemory(), place: LocalStubModel().privacyPlace)
            case .memoryEmpty:
                MemoryView(store: Self.emptyMemory(), place: LocalStubModel().privacyPlace)
            case .memorySaved:
                MemoryView(model: Self.savedNoteMemory(place: LocalStubModel().privacyPlace))
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

    /// A first note, just added the way a person adds one, so the saved
    /// line shows under it.
    @MainActor
    static func savedNoteMemory(place: PrivacyPlace) -> MemoryModel {
        let model = MemoryModel(store: emptyMemory(), place: place)
        model.newNote = "Sam's birthday is May 14. Loves lemon cake."
        model.add()
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
