import Foundation
import PebbleCore
import PebbleModel
import Testing

struct ConversationTests {
    let brand = Brand(name: "Nova")
    let personID = UUID(uuidString: "B2000000-0000-4000-8000-000000000002")!
    let agentID = UUID(uuidString: "C3000000-0000-4000-8000-000000000003")!

    @Test func firstRunNamesTheAgentOnce() {
        let conversation = Conversation.firstRun(for: brand)
        #expect(conversation.turns.map(\.speaker) == [.agent])
        #expect(conversation.turns.map(\.text) == [FirstConversation.opening(for: brand)])
        #expect(conversation.turns.map(\.id) == [FirstConversation.openingID])
        #expect(conversation.isWaitingForPerson)
    }

    @Test func blankLineIsRefused() async {
        let start = Conversation.firstRun(for: brand)
        await #expect(throws: ConversationError.blank) {
            try await start.sending("  \n", with: LocalStubModel(), personID: personID, agentID: agentID)
        }
        #expect(start.turns.count == 1)
    }

    @Test func personLineAppearsBeforeTheModelIsAsked() throws {
        let next = try Conversation.firstRun(for: brand).appendingPerson("Hello there", id: personID)
        #expect(next.turns.map(\.text) == [
            FirstConversation.opening(for: brand),
            "Hello there",
        ])
        #expect(!next.isWaitingForPerson)
    }

    @Test func sendingUsesTheModelReply() async throws {
        let model = RecordingModel(replyText: "Noted.")
        let next = try await Conversation.firstRun(for: brand).sending(
            "Hello there",
            with: model,
            personID: personID,
            agentID: agentID
        )
        let seen = await model.seen
        #expect(seen.map(\.text) == [
            FirstConversation.opening(for: brand),
            "Hello there",
        ])
        #expect(next.turns.map(\.id) == [FirstConversation.openingID, personID, agentID])
        #expect(next.turns.map(\.text).last == "Noted.")
    }

    @Test func emptyModelReplyIsRefused() async {
        let start = Conversation.firstRun(for: brand)
        await #expect(throws: ConversationError.emptyReply) {
            try await start.sending("Hello there", with: RecordingModel(replyText: "  "), personID: personID, agentID: agentID)
        }
    }

    @Test func replyBeforeThePersonSpeaksIsRefused() async {
        await #expect(throws: ConversationError.missingPerson) {
            try await Conversation.firstRun(for: brand).appendingReply(from: LocalStubModel(), id: agentID)
        }
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
