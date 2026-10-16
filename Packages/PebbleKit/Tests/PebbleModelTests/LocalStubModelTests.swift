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
        #expect(reply.hasPrefix("Thanks for telling me."))
        #expect(reply.contains("only on this device"))
        #expect(reply.contains("morning plans"))
        for job in FirstConversation.jobs {
            let jobReply = try await model.reply(to: [person(job.prompt)])
            #expect(reply != jobReply)
        }
    }

    @Test func theMorningStarterEndsInARealPlan() async throws {
        let reply = try await play("morning", then: "school drop off, gym, answer Priya; groceries")
        #expect(reply == """
        Here's a calm start, beginning at 8:00. Move anything that doesn't fit.
        8:00  School drop off
        8:30  Gym
        9:00  Answer Priya
        9:30  Groceries
        Start with the first one. The rest gets easier after that.
        """)
    }

    @Test func aLongMorningListIsCappedAndSaysSo() async throws {
        let reply = try await play("morning", then: "a, b, c, d, e, f, g, h")
        #expect(reply.contains("10:30  F"))
        #expect(!reply.contains("  G"))
        #expect(reply.contains("I kept the first 6"))
    }

    @Test func onlyCommasSemicolonsAndNewLinesSplitSteps() {
        let items = LocalStubModel.planItems(from: "mac and cheese, pick up Sam and Ana then shop\ncall mum; ")
        #expect(items == ["Mac and cheese", "Pick up Sam and Ana then shop", "Call mum"])
    }

    @Test(arguments: [
        "I want to kill myself",
        "Honestly I don\u{2019}t want to be here anymore",
        "thinking about SELF HARM again",
        "everyone is better off without me",
    ])
    func wordsOfCrisisGetCareBeforeAnyModel(text: String) async throws {
        #expect(CareCheck.needsCare(text))
        #expect(try await play("talk", then: text) == CareCheck.reply)
        #expect(try await play("morning", then: text) == CareCheck.reply)
        struct NeverAsked: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String { "a plan" }
        }
        let next = try await Conversation.firstRun(named: "Nova").sending(text, with: NeverAsked())
        #expect(next.turns.last?.text == CareCheck.reply)
        #expect(CareCheck.reply.contains("988"))
    }

    @Test(arguments: ["I'm dying to try that bakery", "Work is piling up", "plan my diet", "I want to diet"])
    func ordinaryWordsDoNotTriggerCare(text: String) {
        #expect(!CareCheck.needsCare(text))
    }

    @Test func aRetryAfterTheMorningReaskStillGetsAPlan() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        var convo = try await Conversation.firstRun(named: "Nova").sending(job.prompt, with: model)
        convo = try await convo.sending(" , ; ", with: model)
        convo = try await convo.sending("gym, iPhone repair, NYC call", with: model)
        let reply = try #require(convo.turns.last?.text)
        #expect(reply.contains("8:00  Gym"))
        #expect(reply.contains("8:30  iPhone repair"))
        #expect(reply.contains("9:00  NYC call"))
    }

    @Test func theOnDeviceFlagSurvivesSending() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        let convo = try await Conversation.firstRun(named: "Nova", onDevice: true).sending(job.prompt, with: model)
        #expect(convo.onDevice)
    }

    @Test func aMorningAnswerWithNoItemsGetsTheFallback() async throws {
        let reply = try await play("morning", then: " , ; ")
        #expect(reply == LocalStubModel.morningReask)
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
            #expect(took < .milliseconds(250), "\(job.id) took \(took)")
        }
    }

    @Test func onlyAnOnDeviceModelMayPromisePrivacy() throws {
        struct Remote: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String { "" }
        }
        #expect(LocalStubModel().runsOnDevice)
        #expect(!Remote().runsOnDevice)
        let local = Conversation.firstRun(named: "Nova", onDevice: true)
        let remote = Conversation.firstRun(named: "Nova", onDevice: false)
        #expect(local.turns.first?.text.contains("stays here") == true)
        #expect(remote.turns.first?.text.contains("stays here") == false)
        guard case .accepted(let pip) = AgentName.decide("Pip") else { Issue.record("Pip refused"); return }
        let renamed = local.renamingAgent(to: pip)
        #expect(renamed.turns.first?.text == FirstConversation.opening(named: "Pip", onDevice: true))
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
