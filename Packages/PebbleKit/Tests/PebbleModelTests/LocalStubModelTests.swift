import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

struct LocalStubModelTests {
    let model = LocalStubModel()

    @Test func emptyTranscriptIsRefused() async {
        await #expect(throws: ModelClientError.noPersonTurn) {
            try await model.reply(to: [])
        }
    }

    @Test(arguments: [
        ("morning", "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep."),
        ("talk", "I'm here. Tell me what's going on, and what you want to be true when we're done."),
        ("remember", "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device."),
    ])
    func starterJobsGetWarmReplies(jobID: String, expected: String) async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == jobID })
        let reply = try await model.reply(to: [person(job.prompt)])
        #expect(reply == expected)
    }

    @Test func matchingIgnoresCaseAndSurroundingSpace() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        let expected = try await model.reply(to: [person(job.prompt)])
        let reply = try await model.reply(to: [person("  \(job.prompt.lowercased())  ")])
        #expect(reply == expected)
    }

    @Test func otherWordsGetAnHonestFallback() async throws {
        let reply = try await model.reply(to: [person("What should I cook tonight?")])
        #expect(reply.contains("only on this device"))
        #expect(reply.contains("morning plans"))
        for job in FirstConversation.jobs {
            let jobReply = try await model.reply(to: [person(job.prompt)])
            #expect(reply != jobReply)
        }
    }

    @Test func theMorningStarterEndsInARealPlan() async throws {
        let reply = try await play("morning", then: "school drop off, gym and answer Priya; groceries")
        #expect(reply == """
        Here's a calm start, beginning at 8:00. Move anything that doesn't fit.
        8:00  School drop off
        8:30  Gym
        9:00  Answer Priya
        9:30  Groceries
        Start with the first one. The rest gets easier after that.
        """)
    }

    @Test func aLongMorningListIsCappedSoThePlanStaysShort() {
        let items = LocalStubModel.planItems(from: "a, b, c, d, e, f, g, h")
        #expect(items == ["A", "B", "C", "D", "E", "F"])
    }

    @Test func aMorningAnswerWithNoItemsGetsTheFallback() async throws {
        let reply = try await play("morning", then: " , ; ")
        #expect(reply == LocalStubModel.fallback)
    }

    @Test func theRememberStarterSaysTheDetailBackAndDoesNotClaimToSave() async throws {
        let reply = try await play("remember", then: "  Sam is allergic to peanuts ")
        #expect(reply.contains("\"Sam is allergic to peanuts\""))
        #expect(reply.contains("add it in What I remember"))
        #expect(!reply.contains("I saved"))
    }

    @Test func theTalkStarterOffersOneNextStep() async throws {
        let reply = try await play("talk", then: "Work is piling up and I can't think")
        #expect(reply.contains("one small next step"))
    }

    @Test func aThirdMessageDoesNotRepeatTheResult() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        let turns = [person(job.prompt), agent("..."), person("gym"), agent("..."), person("thanks")]
        #expect(try await model.reply(to: turns) == LocalStubModel.fallback)
    }

    @Test func everyFirstResultArrivesWellInsideTheLatencyBudget() throws {
        let clock = ContinuousClock()
        for job in FirstConversation.jobs {
            let turns = [person(job.prompt), agent("..."), person("gym, call mum, email Ana")]
            let took = clock.measure { _ = try? LocalStubModel.answer(to: turns) }
            #expect(took < .milliseconds(50), "\(job.id) took \(took)")
        }
    }

    @Test func aStarterJobRoundTripUsesTheModel() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "remember" })
        let next = try await Conversation.firstRun(named: "Nova").sending(job.prompt, with: model)
        #expect(next.turns.last?.speaker == .agent)
        #expect(next.turns.last?.text == "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.")
    }

    private func play(_ jobID: String, then answer: String) async throws -> String {
        let job = try #require(FirstConversation.jobs.first { $0.id == jobID })
        var convo = try await Conversation.firstRun(named: "Nova").sending(job.prompt, with: model)
        convo = try await convo.sending(answer, with: model)
        return try #require(convo.turns.last?.text)
    }

    private func person(_ text: String) -> ChatTurn { ChatTurn(id: UUID(), speaker: .person, text: text) }
    private func agent(_ text: String) -> ChatTurn { ChatTurn(id: UUID(), speaker: .agent, text: text) }
}
