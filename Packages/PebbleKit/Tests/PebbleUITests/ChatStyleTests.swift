#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

@MainActor
struct ChatStyleTests {
    let brand = Brand(name: "Nova")

    private func turn(_ speaker: ChatTurn.Speaker, _ text: String = "Hi") -> ChatTurn {
        ChatTurn(id: UUID(), speaker: speaker, text: text)
    }

    @Test func linesFromOneSpeakerGroupTogether() {
        let turns = [turn(.agent), turn(.person), turn(.person), turn(.person), turn(.agent)]
        let groups = ChatStyle.grouping(of: turns)
        #expect(groups[turns[0].id] == .init(isFirst: true, isLast: true))
        #expect(groups[turns[1].id] == .init(isFirst: true, isLast: false))
        #expect(groups[turns[2].id] == .init(isFirst: false, isLast: false))
        #expect(groups[turns[3].id] == .init(isFirst: false, isLast: true))
        #expect(groups[turns[4].id] == .init(isFirst: true, isLast: true))
    }

    @Test func theReplyTapIsOnlyForAReplyLanding() {
        let opening = [turn(.agent)]
        let sent = opening + [turn(.person)]
        let replied = sent + [turn(.agent)]
        let mark = ChatStyle.ReplyMark.init
        #expect(!ChatStyle.playsReplyTap(from: mark([]), to: mark(opening)), "a new chat's opening line")
        #expect(!ChatStyle.playsReplyTap(from: mark(opening), to: mark(sent)), "the person's own line")
        #expect(ChatStyle.playsReplyTap(from: mark(sent), to: mark(replied)), "a reply")
        #expect(!ChatStyle.playsReplyTap(from: mark(sent), to: mark(opening)), "a line taken back")
        #expect(!ChatStyle.playsReplyTap(from: mark(replied), to: mark(replied)), "nothing new")
    }

    @Test func aSuggestionFillsTheComposerAndNeverSends() {
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(),
                                        replyBeat: .zero)
        let job = FirstConversation.jobs[0]
        let other = FirstConversation.jobs[1]
        controller.draft = ChatStyle.draft(filling: controller.draft, with: job.prompt)
        #expect(controller.draft == job.prompt)
        #expect(controller.sentCount == 0 && !controller.isReplying)
        #expect(controller.conversation.isWaitingForPerson, "nothing went into the chat")
        // Another suggestion swaps it; words the person typed stay.
        #expect(ChatStyle.draft(filling: job.prompt, with: other.prompt) == other.prompt)
        #expect(ChatStyle.draft(filling: "Pack lunches", with: job.prompt) == "Pack lunches")
        #expect(ChatStyle.draft(filling: "  ", with: job.prompt) == job.prompt)
    }

    @Test func theCharacterHoldsStillWithReduceMotion() {
        for time in stride(from: 0.0, through: 5, by: 0.37) {
            let rest = Breath.look(at: time, thinking: false, reduceMotion: true)
            #expect(rest.body == 1 && rest.glow == 1)
            let thinking = Breath.look(at: time, thinking: true, reduceMotion: true)
            #expect(thinking.body == 1 && thinking.glow == 1)
            #expect(thinking.glowOpacity > rest.glowOpacity, "thinking still shows, without motion")
        }
        let a = Breath.look(at: 0, thinking: false, reduceMotion: false)
        let b = Breath.look(at: 2.1, thinking: false, reduceMotion: false)
        #expect(a.body != b.body, "it breathes when it may move")
    }

    @Test("Smoke: the chat's pieces draw in light and dark", arguments: [ColorScheme.light, .dark])
    func smokeTheChatPieces(scheme: ColorScheme) throws {
        try smokeRender(VStack {
            Composer(draft: .constant("Plan my week"), isBusy: false, keyboardSends: true, send: { _ in })
            StarterChip(title: "Plan my morning", symbol: ChatStyle.symbol(forStarter: "morning"), index: 0) {}
            CharacterView(look: .sunrise, size: 64, isThinking: true)
        }
        .environment(\.colorScheme, scheme)
        .frame(width: 393))
    }
}
#endif
