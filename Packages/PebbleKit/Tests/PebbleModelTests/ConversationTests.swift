import Foundation
import PebbleCore
import PebbleModel
import Testing

struct ConversationTests {
    let brand = Brand(name: "Nova")
    let personID = UUID(uuidString: "B2000000-0000-4000-8000-000000000002")!
    let agentID = UUID(uuidString: "C3000000-0000-4000-8000-000000000003")!

    @Test func firstRunNamesTheAgentOnce() {
        let conversation = Conversation.firstRun(named: brand.name)
        #expect(conversation.turns.map(\.speaker) == [.agent])
        #expect(conversation.turns.map(\.text) == [FirstConversation.opening(named: brand.name)])
        #expect(conversation.turns.map(\.id) == [FirstConversation.openingID])
        #expect(conversation.isWaitingForPerson)
    }

    @Test func blankLineIsRefused() async {
        let start = Conversation.firstRun(named: brand.name)
        await #expect(throws: ConversationError.blank) {
            try await start.sending("  \n", with: LocalStubModel(), personID: personID, agentID: agentID)
        }
        #expect(start.turns.count == 1)
    }

    @Test func personLineAppearsBeforeTheModelIsAsked() throws {
        let next = try Conversation.firstRun(named: brand.name).appendingPerson("Hello there", id: personID)
        #expect(next.turns.map(\.text) == [
            FirstConversation.opening(named: brand.name),
            "Hello there",
        ])
        #expect(!next.isWaitingForPerson)
    }

    @Test func sendingUsesTheModelReply() async throws {
        let model = RecordingModel(replyText: "Noted.")
        let next = try await Conversation.firstRun(named: brand.name).sending(
            "Hello there",
            with: model,
            personID: personID,
            agentID: agentID
        )
        let seen = await model.seen
        #expect(seen.map(\.text) == [
            FirstConversation.opening(named: brand.name),
            "Hello there",
        ])
        #expect(next.turns.map(\.id) == [FirstConversation.openingID, personID, agentID])
        #expect(next.turns.map(\.text).last == "Noted.")
    }

    @Test func emptyModelReplyIsRefused() async {
        let start = Conversation.firstRun(named: brand.name)
        await #expect(throws: ConversationError.emptyReply) {
            try await start.sending("Hello there", with: RecordingModel(replyText: "  "), personID: personID, agentID: agentID)
        }
    }

    @Test func replyBeforeThePersonSpeaksIsRefused() async {
        await #expect(throws: ConversationError.missingPerson) {
            try await Conversation.firstRun(named: brand.name).appendingReply(from: LocalStubModel(), id: agentID)
        }
    }

    @Test func renamingBeforeThePersonSpeaksUpdatesTheGreeting() throws {
        let pip = try acceptedName("Pip")
        let renamed = Conversation.firstRun(named: brand.name).renamingAgent(to: pip)
        #expect(renamed.turns.map(\.text) == [FirstConversation.opening(named: "Pip")])
        #expect(renamed.turns.map(\.id) == [FirstConversation.openingID])
        #expect(renamed.isWaitingForPerson)
        #expect(!renamed.turns[0].text.contains(brand.name))
    }

    @Test func renamingAfterThePersonSpeaksLeavesSpokenLines() throws {
        let pip = try acceptedName("Pip")
        let spoken = try Conversation.firstRun(named: brand.name).appendingPerson("Hello there", id: personID)
        #expect(spoken.renamingAgent(to: pip) == spoken)
    }

    private func acceptedName(_ proposed: String) throws -> AgentName {
        guard case .accepted(let name) = AgentName.decide(proposed) else {
            struct UnusableName: Error {}
            throw UnusableName()
        }
        return name
    }
}

private actor RecordingModel: ModelClient {
    let replyText: String
    var seen: [ChatTurn] = []

    init(replyText: String) {
        self.replyText = replyText
    }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        seen = transcript
        return replyText
    }
}
