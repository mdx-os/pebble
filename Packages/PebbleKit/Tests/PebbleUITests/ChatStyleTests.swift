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

    private func chat() -> ChatController {
        ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(), replyBeat: .zero)
    }

    @Test func aSuggestionFillsTheComposerAndNeverSends() {
        let controller = chat()
        let job = FirstConversation.jobs[0]
        let other = FirstConversation.jobs[1]
        controller.fill(withSuggestion: job.prompt)
        #expect(controller.draft == job.prompt)
        #expect(controller.sentCount == 0 && !controller.isReplying)
        #expect(controller.conversation.isWaitingForPerson, "nothing went into the chat")
        // Another suggestion swaps one a tap put there, untouched.
        controller.fill(withSuggestion: other.prompt)
        #expect(controller.draft == other.prompt)
        controller.fill(withSuggestion: job.prompt)
        #expect(controller.draft == job.prompt)
        // Words the person typed stay, and an empty field takes one.
        let typed = chat()
        typed.draft = "Pack lunches"
        typed.fill(withSuggestion: job.prompt)
        #expect(typed.draft == "Pack lunches")
        typed.draft = "  "
        typed.fill(withSuggestion: job.prompt)
        #expect(typed.draft == job.prompt)
    }

    /// Typed or pasted words that read exactly like a suggestion are still
    /// the person's: only a tap makes a draft a suggestion.
    @Test func wordsThatMatchASuggestionAreStillThePersons() {
        let job = FirstConversation.jobs[0]
        let other = FirstConversation.jobs[1]
        // Typed or pasted by hand, the same words as a suggestion, with or
        // without spaces around them.
        for words in [job.prompt, other.prompt, " \(job.prompt)\n"] {
            let controller = chat()
            controller.draft = words
            controller.fill(withSuggestion: FirstConversation.jobs[2].prompt)
            #expect(controller.draft == words, "kept: \(words)")
        }
        // A suggestion the person then edits, even back to the same words,
        // is theirs too.
        let edited = chat()
        edited.fill(withSuggestion: job.prompt)
        edited.draft = job.prompt + "!"
        edited.draft = job.prompt
        edited.fill(withSuggestion: other.prompt)
        #expect(edited.draft == job.prompt)
        // Cleared by a send, the field takes the next suggestion again.
        let sent = chat()
        sent.fill(withSuggestion: job.prompt)
        sent.draft = ""
        sent.draft = other.prompt
        sent.fill(withSuggestion: job.prompt)
        #expect(sent.draft == other.prompt, "typed after the field was cleared")
    }

    @Test func theHeaderFadeIsOffWithIncreaseContrast() {
        #expect(ChatStyle.headerFadeHeight(scrolls: false, contrast: .standard) == ChatStyle.headerFade)
        #expect(ChatStyle.headerFadeHeight(scrolls: false, contrast: .increased) == 0)
        #expect(ChatStyle.headerFadeHeight(scrolls: true, contrast: .standard) == 0)
    }

    /// With Reduce Motion the header's face is a new face at each size, so
    /// it only cross fades; otherwise it is one face that shrinks.
    @Test func theFaceOnlyFadesWithReduceMotion() {
        let face = { ChatStyle.faceIdentity($0, reduceMotion: $1) }
        #expect(face(ChatStyle.greetingFace, true) != face(ChatStyle.talkingFace, true))
        #expect(face(ChatStyle.greetingFace, false) == face(ChatStyle.talkingFace, false))
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
