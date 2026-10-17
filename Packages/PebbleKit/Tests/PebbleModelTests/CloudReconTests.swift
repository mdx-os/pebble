import Foundation
import PebbleCore
import PebbleModel
import Testing

struct CloudReconTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let notes = [MemoryNote(text: "Swim lessons with Priya on Tuesdays.", source: .toldMe)]
    let readOn = Date(timeIntervalSinceReferenceDate: 813_000_000)

    var task: ReconTask { ReconTask(topic: "the Riverside pool reopening")! }

    let sources = [
        ReconSource(id: "a", title: "Pool reopens", publisher: "Riverside Gazette",
                    url: URL(string: "https://gazette.example.org/pool")!, published: Date(timeIntervalSinceReferenceDate: 812_000_000),
                    text: "The pool reopens on November 3. Coach Priya runs the lessons, call 416 555 0199 to book."),
        ReconSource(id: "b", title: "Fall schedule", publisher: "City of Riverside Parks",
                    url: URL(string: "https://parks.example.org/pool")!, published: Date(timeIntervalSinceReferenceDate: 812_500_000),
                    text: "The pool reopens on November 10. Family swim is on Saturdays."),
    ]

    func cloud(_ transport: RecordingTransport, _ reviewer: RecordingReviewer) -> CloudModel {
        let notes = notes
        return CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                          redactor: { Redactor(memory: notes, privateWords: ["lemon cake"]) })
    }

    static let goodReply = """
        SUMMARY: The pool reopens in November, but the two sources give different dates. [1][2]
        POINT: The Gazette says the pool reopens on November 3. [1]
        POINT: The city says it reopens on November 10. [2]
        POINT: Family swim is on Saturdays. [2]
        DISAGREE: They give different reopening dates, November 3 and November 10. [1][2]
        """

    @Test func sendsOnlyTheRedactedBytesThePersonSaw() async throws {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .send)
        let summary = await CloudReconSummarizer(model: cloud(transport, reviewer))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        let preview = try #require(reviewer.seen.first)
        #expect(reviewer.seen.count == 1)
        #expect(transport.sent == [preview.request])
        let body = preview.request.text
        #expect(!body.contains("Priya"))
        #expect(!body.contains("416 555 0199"))
        #expect(body.contains("[name]"))
        #expect(body.contains("[phone number]"))
        #expect(body.contains("The pool reopens on November 10."))
        #expect(!summary.madeOnDevice)
        #expect(summary.overviewSourceIDs == ["a", "b"])
        #expect(summary.points.count == 3)
        #expect(summary.points.allSatisfy { !$0.sourceIDs.isEmpty })
        #expect(summary.disagreements.count == 1)
        #expect(summary.gatheredAt == readOn)
    }

    @Test func linesWithoutARealSourceAreDropped() async {
        let transport = RecordingTransport(reply: """
            SUMMARY: The pool is the best in the city.
            POINT: The pool has a new water slide.
            POINT: The pool reopens on November 10. [2]
            POINT: It has a sauna. [9]
            DISAGREE: Nobody agrees. [1]
            """)
        let summary = await CloudReconSummarizer(model: cloud(transport, RecordingReviewer(answer: .send)))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(summary.points.map(\.text) == ["The pool reopens on November 10."])
        #expect(summary.points[0].sourceIDs == ["b"])
        #expect(summary.disagreements.isEmpty)
        // An overview with no source is not used; the plain one stands in.
        #expect(summary.overview.hasPrefix("I read 2 sources"))
        #expect(summary.overviewSourceIDs.isEmpty)
    }

    @Test func notSendingKeepsItOnThisDevice() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .cancel)
        let summary = await CloudReconSummarizer(model: cloud(transport, reviewer))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(reviewer.seen.count == 1)
        #expect(transport.sent.isEmpty)
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.declinedCloud)
        #expect(!summary.points.isEmpty)
    }

    @Test func wordsOfCrisisInTheSourcesAreNeverSent() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .send)
        let heavy = [ReconSource(id: "c", title: "Pool safety", publisher: "Riverside Gazette",
                                 url: URL(string: "https://gazette.example.org/safety")!, published: readOn,
                                 text: "A sign by the pool lists a suicide prevention line. The pool reopens on November 10.")]
        let summary = await CloudReconSummarizer(model: cloud(transport, reviewer))
            .summarize(task, id: "task:1", sources: heavy, gatheredAt: readOn)
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
        #expect(summary.madeOnDevice)
    }

    @Test func anUnreadableAnswerIsPutTogetherHereInstead() async {
        let transport = RecordingTransport(reply: "Sure, the pool sounds lovely.")
        let summary = await CloudReconSummarizer(model: cloud(transport, RecordingReviewer(answer: .send)))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(transport.sent.count == 1)
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudUnreadable)
    }

    @Test func nothingLeavesWhenTheCloudIsOff() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .send)
        let chosen = ModelChoice.model(settings: .off, endpoint: endpoint, local: LocalStubModel()) { _ in
            cloud(transport, reviewer)
        }
        let summarizer = ReconSummarizers.choose(for: chosen)
        #expect(summarizer is LocalReconSummarizer)
        let summary = await summarizer.summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(summary.madeOnDevice)
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    @Test func theCloudIsUsedOnlyWhenItIsOn() {
        let on = ModelChoice.model(settings: CloudHelpSettings(isOn: true), endpoint: endpoint, local: LocalStubModel()) { _ in
            cloud(RecordingTransport(), RecordingReviewer(answer: .send))
        }
        #expect(ReconSummarizers.choose(for: on) is CloudReconSummarizer)
        #expect(ReconSummarizers.choose(for: LocalStubModel()) is LocalReconSummarizer)
    }

    @Test func thePromptReadsPlainlyAndHasNoDashes() {
        let prompt = CloudReconSummarizer.prompt(for: task, sources: sources)
        #expect(prompt.hasPrefix("Please look into the Riverside pool reopening"))
        #expect(prompt.contains("[1] Pool reopens. Riverside Gazette,"))
        #expect(prompt.contains("[2] Fall schedule. City of Riverside Parks,"))
        #expect(!prompt.contains("\u{2014}") && !prompt.contains("\u{2013}"))
    }
}
