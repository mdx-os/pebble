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
        #expect(LocalStubModel.planItems(from: "call (mum), see Dr. Lee") == ["Call (mum)", "See Dr. Lee"])
    }

    @Test(arguments: [
        "I want to kill myself",
        "Honestly I don\u{2019}t want to be here anymore",
        "thinking about SELF HARM again",
        "everyone is better off without me",
        "I keep hurting myself",
        "I wish I was dead",
        "I can\u{2019}t go on",
        "I don\u{02BC}t want to be here",
        "I don\u{2019}t want to live",
        "thinking of an overdose",
        "I want to take my own life",
    ])
    func wordsOfCrisisGetCareBeforeAnyModel(text: String) async throws {
        #expect(CareCheck.needsCare(text))
        #expect(try await play("talk", then: text) == CareCheck.reply)
        #expect(try await play("morning", then: text) == CareCheck.reply)
        struct Reached: Error {}
        struct NeverAsked: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String { throw Reached() }
        }
        let next = try await Conversation.firstRun(named: "Nova").sending(text, with: NeverAsked())
        #expect(next.turns.last?.text == CareCheck.reply)
        #expect(CareCheck.reply.contains("988"))
    }

    @Test func theMessageAfterACareReplyStaysWithThePerson() async throws {
        let convo = try await Conversation.firstRun(named: "Nova").sending("I want to end my life", with: model)
        let next = try await convo.sending("yes", with: model)
        let reply = try #require(next.turns.last?.text)
        #expect(reply == CareCheck.followUp)
        #expect(!reply.contains("morning plans"))
        #expect(reply.contains("988"))
        let third = try await next.sending("I have the pills here", with: model)
        #expect(third.turns.last?.text == CareCheck.followUp)
        let job = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        let chosen = try await third.sending(job.prompt, with: model)
        #expect(chosen.turns.last?.text != CareCheck.followUp)
        let spoken = try await third.sending("plan my morning", with: model)
        #expect(spoken.turns.last?.text != CareCheck.followUp)
        #expect(CareCheck.followUp.contains("plan my morning"))
    }

    @Test func aModelNeverSeesWordsOfCrisisOnLaterTurns() async throws {
        final class Seen: @unchecked Sendable { var texts: [String] = [] }
        struct Recorder: ModelClient {
            let seen: Seen
            func reply(to transcript: [ChatTurn]) async throws -> String {
                seen.texts += transcript.map(\.text)
                return "ok"
            }
        }
        let seen = Seen()
        var convo = try await Conversation.firstRun(named: "Nova").sending("I want to kill myself", with: Recorder(seen: seen))
        convo = try await convo.sending("I'm ok now", with: Recorder(seen: seen))
        let job = try #require(FirstConversation.jobs.first { $0.id == "talk" })
        convo = try await convo.sending(job.prompt, with: Recorder(seen: seen))
        #expect(convo.turns.last?.text == "ok")
        #expect(!seen.texts.isEmpty)
        #expect(!seen.texts.contains { CareCheck.needsCare($0) })
        #expect(!seen.texts.contains("I'm ok now"))
        #expect(!seen.texts.contains(CareCheck.reply))
        #expect(!seen.texts.contains(CareCheck.followUp))
    }

    @Test(arguments: ["I'm dying to try that bakery", "Work is piling up", "plan my diet", "I want to diet", "this commute will kill me"])
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
        let convo = try await Conversation.firstRun(named: "Nova", place: .onDevice).sending(job.prompt, with: model)
        #expect(convo.place == .onDevice)
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

    @Test func onlyAnOnDeviceModelMayPromisePrivacy() async throws {
        struct Remote: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String { "" }
        }
        #expect(LocalStubModel().runsOnDevice)
        #expect(!Remote().runsOnDevice)
        let local = Conversation.firstRun(named: "Nova", place: .onDevice)
        let promised = try local.appendingPerson("hi")
        await #expect(throws: ConversationError.leavesDevice) {
            _ = try await promised.appendingReply(from: Remote())
        }
        let remote = Conversation.firstRun(named: "Nova", place: .mayLeaveDevice)
        #expect(local.turns.first?.text.contains("stays here") == true)
        #expect(remote.turns.first?.text.contains("stays here") == false)
        guard case .accepted(let pip) = AgentName.decide("Pip") else { Issue.record("Pip refused"); return }
        let renamed = local.renamingAgent(to: pip)
        #expect(renamed.turns.first?.text == FirstConversation.opening(named: "Pip", place: .onDevice))
    }

    /// The one source for every device line is the model itself.
    @Test func thePrivacyPlaceComesFromTheModel() {
        struct Remote: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String { "" }
        }
        struct Local: ModelClient {
            var runsOnDevice: Bool { true }
            func reply(to transcript: [ChatTurn]) async throws -> String { "" }
        }
        #expect(LocalStubModel().privacyPlace == .onDevice)
        #expect(Local().privacyPlace == .onDevice)
        // A new adapter that says nothing makes no promise.
        #expect(Remote().privacyPlace == .mayLeaveDevice)
        // The device lines in the stub's own replies are only said by a model
        // that runs here.
        #expect(LocalStubModel.fallback.contains("this device") && LocalStubModel().runsOnDevice)
    }

    @Test func aStarterJobRoundTripUsesTheModel() async throws {
        let job = try #require(FirstConversation.jobs.first { $0.id == "remember" })
        let next = try await Conversation.firstRun(named: "Nova").sending(job.prompt, with: model)
        #expect(next.turns.last?.speaker == .agent)
        #expect(next.turns.last?.text == "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.")
    }

    @Test func careRunsBeforeTheLeavesDeviceCheck() async throws {
        struct Remote: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String {
                Issue.record("model reached")
                return "reached-model"
            }
        }
        let promised = try Conversation.firstRun(named: "Nova", place: .onDevice)
            .appendingPerson("I want to kill myself")
        let next = try await promised.appendingReply(from: Remote())
        #expect(next.turns.last?.text == CareCheck.reply)
        #expect(CareCheck.reply.contains("988"))
        // A short "yes" after care still stays local and never reaches a remote model.
        let follow = try next.appendingPerson("yes")
        let stayed = try await follow.appendingReply(from: Remote())
        #expect(stayed.turns.last?.text == CareCheck.followUp)
        // Picking a starter after care must still refuse a remote model.
        let pick = try stayed.appendingPerson("plan my morning")
        await #expect(throws: ConversationError.leavesDevice) {
            _ = try await pick.appendingReply(from: Remote())
        }
        // Ordinary words still refuse a remote model after the privacy promise.
        let ordinary = try Conversation.firstRun(named: "Nova", place: .onDevice)
            .appendingPerson("plan my morning")
        await #expect(throws: ConversationError.leavesDevice) {
            _ = try await ordinary.appendingReply(from: Remote())
        }
    }

    @Test(arguments: [
        "'I want to kill myself'",
        "I want to kill myself!",
        "\"want to die\"",
        "thinking about self-harm?",
        "\u{2018}kill myself\u{2019}",
    ])
    func quotedAndPunctuatedCrisisStillGetsCare(text: String) async throws {
        #expect(CareCheck.needsCare(text), "missed care for \(text)")
        struct NeverAsked: ModelClient {
            func reply(to transcript: [ChatTurn]) async throws -> String {
                Issue.record("model reached")
                return "reached-model"
            }
        }
        let next = try await Conversation.firstRun(named: "Nova").sending(text, with: NeverAsked())
        #expect(next.turns.last?.text == CareCheck.reply)
    }

    @Test func theStubMatchesTheCareFollowUpNaturalPhrasing() async throws {
        var convo = try await Conversation.firstRun(named: "Nova")
            .sending("I want to end my life", with: model)
        convo = try await convo.sending("yes", with: model)
        #expect(convo.turns.last?.text == CareCheck.followUp)
        let morning = try await convo.sending("plan my morning", with: model)
        #expect(morning.turns.last?.text == "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep.")
        let again = try await convo.sending("'plan my morning!'", with: model)
        #expect(again.turns.last?.text == morning.turns.last?.text)
        let byTitle = try await model.reply(to: [person("Talk something through")])
        #expect(byTitle.hasPrefix("I'm here."))
    }

    @Test func aStarterSaidMidJobStartsThatJobInsteadOfFinishingTheOldOne() async throws {
        let talk = try #require(FirstConversation.jobs.first { $0.id == "talk" })
        let morningOpener = "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep."
        let reply = try await model.reply(to: [
            person(talk.prompt),
            agent("I'm here."),
            person("plan my morning"),
        ])
        #expect(reply == morningOpener)
    }

    @Test func tappingAStarterTwiceGetsTheOpenerAgain() async throws {
        let morning = try #require(FirstConversation.jobs.first { $0.id == "morning" })
        let opener = "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep."
        let first = try await model.reply(to: [person(morning.prompt)])
        #expect(first == opener)
        let second = try await model.reply(to: [
            person(morning.prompt),
            agent(opener),
            person("plan my morning!"),
        ])
        #expect(second == opener)
        let chained = try await model.reply(to: [
            person(morning.prompt),
            agent(opener),
            person("plan my morning!"),
            agent(opener),
            person("gym, call mum"),
        ])
        #expect(chained.contains("8:00  Gym"))
    }


    @Test func starterTitlesAreNotCasualRepliesAfterCare() {
        let casual = ["yes", "ok", "not now", "thanks", "no"]
        for job in FirstConversation.jobs {
            let title = job.title.lowercased()
            #expect(!casual.contains(title), "title \(job.title) looks casual")
            #expect(CareCheck.starter(matching: job.title)?.id == job.id)
            for word in casual {
                #expect(CareCheck.starter(matching: word) == nil)
            }
            #expect(!CareCheck.needsCare(job.title))
            #expect(!CareCheck.needsCare(job.prompt))
        }
    }

    @Test(arguments: [
        "kill myself", "don't want to be here", "can't go on", "self harm", "want to die",
    ])
    func carePhrasesStillMatchAfterNormalize(phrase: String) {
        #expect(CareCheck.needsCare(phrase))
        #expect(CareCheck.needsCare("\(phrase)."))
        #expect(CareCheck.needsCare("'\(phrase)'"))
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
