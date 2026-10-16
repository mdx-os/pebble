import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// The app's root: the guided first run until it's finished, then the chat
/// with a way to see what the agent remembers.
public struct HomeView: View {
    let brand: Brand
    let model: any ModelClient
    let names: any AgentNameStoring
    let onboarding: any OnboardingStoring
    let memory: MemoryStore?
    let looks: UserDefaults

    @State private var finished: Bool
    @State private var firstMessage: String?
    @State private var showsMemory = false

    public init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults = .standard
    ) {
        self.brand = brand
        self.model = model
        self.names = names
        self.onboarding = onboarding
        self.memory = memory
        self.looks = looks
        let needed = OnboardingFlow.isNeeded(store: onboarding, names: names)
        // People who named their agent before the first run existed count as finished.
        if !needed, !onboarding.hasFinished() { onboarding.markFinished() }
        _finished = State(initialValue: !needed)
    }

    public var body: some View {
        Group {
            if finished {
                NavigationStack {
                    ChatView(brand: brand, model: model, names: names, look: AgentLook.load(from: looks), firstMessage: firstMessage,
                             onFirstMessageSent: { firstMessage = nil })
                        .background(Backdrop())
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button { showsMemory = true } label: {
                                    Label(MemoryWords.title, systemImage: "heart.text.square")
                                }
                            }
                        }
                }
                .sheet(isPresented: $showsMemory) {
                    NavigationStack {
                    Group {
                    if let memory {
                        MemoryView(store: memory)
                            .presentationDragIndicator(.visible)
                    } else {
                        // The store couldn't be opened. Say so rather than hide memory.
                        ZStack {
                            Backdrop()
                            Label(MemoryWords.unavailable, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                                .padding(Theme.gutter)
                        }
                        .presentationDragIndicator(.visible)
                    }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(MemoryWords.doneTitle) { showsMemory = false }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    }
                }
                .transition(.opacity)
            } else {
                OnboardingView(brand: brand, names: names, store: onboarding, looks: looks) { line in
                    firstMessage = line
                    withAnimation(.easeInOut(duration: 0.4)) { finished = true }
                }
                .transition(.opacity)
            }
        }
        .tint(Theme.accent)
    }
}
#endif
