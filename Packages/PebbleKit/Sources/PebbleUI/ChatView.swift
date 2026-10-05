import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// The first screen: the agent has a face, a name, and a conversation.
public struct ChatView: View {
    @StateObject private var controller: ChatController

    public init(brand: Brand, model: any ModelClient = LocalStubModel()) {
        _controller = StateObject(wrappedValue: ChatController(brand: brand, model: model))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transcript
                    if controller.conversation.isWaitingForPerson {
                        starterJobs
                    }
                    if controller.isReplying {
                        Text(FirstConversation.thinking)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let failure = controller.failure {
                        Text(failure)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            composer
                .padding(.vertical, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: controller.conversation.turns.count)
    }

    private var header: some View {
        VStack(spacing: 8) {
            AvatarView(initial: FirstConversation.initial(for: controller.brand))
            Text(controller.brand.name)
                .font(.title.weight(.semibold))
            Text(FirstConversation.presence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(controller.conversation.turns) { turn in
                bubble(turn)
            }
        }
    }

    private func bubble(_ turn: ChatTurn) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if turn.speaker == .person {
                Spacer(minLength: 48)
            }
            Text(turn.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleFill(for: turn.speaker), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 420, alignment: turn.speaker == .agent ? .leading : .trailing)
            if turn.speaker == .agent {
                Spacer(minLength: 48)
            }
        }
    }

    private func bubbleFill(for speaker: ChatTurn.Speaker) -> Color {
        switch speaker {
        case .agent:
            Color.primary.opacity(0.06)
        case .person:
            Color.orange.opacity(0.18)
        }
    }

    private var starterJobs: some View {
        VStack(spacing: 10) {
            ForEach(FirstConversation.jobs) { job in
                Button {
                    controller.submit(job.prompt)
                } label: {
                    Text(job.title)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(controller.isReplying)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(FirstConversation.composerPlaceholder, text: $controller.draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .onSubmit { controller.submit(controller.draft) }
                .disabled(controller.isReplying)
            Button(FirstConversation.sendTitle) {
                controller.submit(controller.draft)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(controller.isReplying || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

@MainActor
final class ChatController: ObservableObject {
    let brand: Brand
    private let model: any ModelClient
    @Published var conversation: Conversation
    @Published var draft = ""
    @Published var isReplying = false
    @Published var failure: String?

    init(brand: Brand, model: any ModelClient) {
        self.brand = brand
        self.model = model
        conversation = .firstRun(for: brand)
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        let clearsDraft = trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            conversation = try conversation.appendingPerson(trimmed)
        } catch {
            return
        }
        if clearsDraft {
            draft = ""
        }
        failure = nil
        isReplying = true
        let snapshot = conversation
        let client = model
        Task {
            do {
                conversation = try await snapshot.appendingReply(from: client)
            } catch {
                failure = FirstConversation.couldNotAnswer
            }
            isReplying = false
        }
    }
}

struct AvatarView: View {
    let initial: String

    var body: some View {
        Circle()
            .fill(Color.orange.gradient)
            .frame(width: 88, height: 88)
            .overlay {
                Text(initial)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ChatView(brand: Brand(name: "Preview"))
}
#else
public enum PebbleUISupport {
    public static let available = false
}
#endif
