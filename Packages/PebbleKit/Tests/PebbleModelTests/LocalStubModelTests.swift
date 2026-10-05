import Foundation
import PebbleCore
import PebbleModel
import Testing

struct LocalStubModelTests {
    let model = LocalStubModel()

    @Test func emptyTranscriptIsRefused() async {
        await #expect(throws: ModelClientError.noPersonTurn) {
            try await model.reply(to: [])
        }
    }

    @Test(arguments: [
        ("morning", "Tell me the one thing that would make the morning feel settled. I'll turn it into a short list you can keep."),
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

    @Test func otherWordsGetTheFallback() async throws {
        let reply = try await model.reply(to: [person("What should I cook tonight?")])
        #expect(reply == "I'm with you. Say a little more about what you need, and I'll answer from this device.")
        for job in FirstConversation.jobs {
            let jobReply = try await model.reply(to: [person(job.prompt)])
            #expect(reply != jobReply)
        }
    }

    @Test func aStarterJobRoundTripUsesTheStub() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "remember" })
        let next = try await Conversation.firstRun(for: Brand(name: "Nova")).sending(job.prompt, with: model)
        #expect(next.turns.last?.speaker == .agent)
        #expect(next.turns.last?.text == "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.")
    }

    private func person(_ text: String) -> ChatTurn {
        ChatTurn(id: UUID(), speaker: .person, text: text)
    }
}
