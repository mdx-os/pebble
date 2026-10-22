import Foundation
import PebbleCore
import PebbleModel
import Testing

/// A limit for the whole suite: `HeldYes` and `HeldTransport` park their
/// callers, so a change that never resumes them fails rather than hangs CI.
@Suite(.timeLimit(.minutes(1)))
struct CloudReconTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let notes = [MemoryNote(text: "Swim lessons with Priya on Tuesdays.", source: .toldMe)]
    let readOn = Date(timeIntervalSinceReferenceDate: 813_000_000)

    var task: ReconTask { ReconTask(topic: "the Riverside pool reopening")! }

    let sources = [
        ReconSource(id: "a", title: "Pool reopens", publisher: "Riverside Gazette",
                    url: URL(string: "https://gazette.example.org/pool")!, published: Date(timeIntervalSinceReferenceDate: 812_000_000),
                    text: "The pool reopens on November 3. Coach Priya runs the lessons, call 416 555 0199 to book. The snack bar sells lemon cake."),
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
        // A private word inside a fetched page is masked too, in the preview
        // and in the bytes that went.
        #expect(!body.localizedCaseInsensitiveContains("lemon cake"))
        #expect(body.contains("[private]"))
        #expect(transport.sent.allSatisfy { !$0.text.localizedCaseInsensitiveContains("lemon cake") })
        #expect(transport.sent.allSatisfy { $0.text.contains("[private]") })
        #expect(body.contains("The pool reopens on November 10."))
        #expect(!summary.madeOnDevice)
        // The model's SUMMARY line has no source numbers on the card, so the
        // plain overview stands in, which only says what was read.
        #expect(summary.overviewSourceIDs.isEmpty)
        #expect(summary.overview.hasPrefix("I read 2 sources"))
        #expect(!summary.overview.contains("but the two sources give different dates"))
        #expect(summary.points.count == 3)
        #expect(summary.points.allSatisfy { !$0.sourceIDs.isEmpty })
        #expect(summary.disagreements.count == 1)
        #expect(summary.gatheredAt == readOn)
        // The cloud's own words, so the card says so.
        #expect(summary.note == ReconWords.wordedInCloud)
    }

    /// A point keeps only the sources it named. The disagreement's other
    /// side is never merged in as backing what it contradicts.
    @Test func aPointCitesOnlyTheSourcesThatSayIt() async throws {
        let transport = RecordingTransport(reply: Self.goodReply)
        let summary = await CloudReconSummarizer(model: cloud(transport, RecordingReviewer(answer: .send)))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(summary.points.map(\.sourceIDs) == [["a"], ["b"], ["b"]])
        let disputed = try #require(summary.points.first { $0.disagreement != nil })
        #expect(disputed.disagreement?.sourceIDs == ["a", "b"])
        #expect(disputed.sourceIDs.count == 1)
        // Remembering it keeps the disagreement with it.
        let note = try #require(summary.note(for: disputed))
        #expect(note.contains("They give different reopening dates"))
    }

    func parsed(_ reply: String, sources: [ReconSource]? = nil) -> ReconSummary? {
        CloudReconSummarizer.parse(reply, task: task, id: "task:1", sources: sources ?? self.sources,
                                   gatheredAt: readOn)
    }

    /// The model cites both sides on one side's words. The card never shows
    /// both beside it, and remembering it never says both said it.
    @Test func aPointCitingEverySideOfADisputeNeverCarriesIt() throws {
        let summary = try #require(parsed("""
            POINT: The pool reopens on November 10. [1][2]
            POINT: Family swim is on Saturdays. [2]
            DISAGREE: The Gazette says November 3 and the city says November 10. [1][2]
            """))
        #expect(!summary.points.contains { $0.text == "The pool reopens on November 10." })
        let dispute = try #require(summary.points.first { $0.disagreement != nil })
        #expect(dispute.text == "The Gazette says November 3 and the city says November 10.")
        #expect(dispute.sourceIDs == ["a", "b"])
        let swim = try #require(summary.points.first { $0.text.hasPrefix("Family swim") })
        #expect(swim.sourceIDs == ["b"])
        #expect(swim.disagreement == nil)
        // No undisputed point names both sides of the dispute.
        #expect(!summary.points.contains { $0.disagreement == nil && Set($0.sourceIDs).isSuperset(of: ["a", "b"]) })
    }

    /// A point with a source beside the dispute keeps only that one; a
    /// point whose only source is one side keeps it, as that is its side.
    ///
    /// So a point cited [2][3] lets go of source 2, while one cited [2]
    /// alone keeps it. With [3] beside it, the point has a source no side
    /// of the dispute claims, so it needn't name a side at all. With [2]
    /// alone, dropping it would leave the point with no source, and a
    /// point that names one side and carries the dispute says plainly
    /// whose words it is.
    @Test func aPointLetsGoOfTheSourcesInADispute() throws {
        let third = ReconSource(id: "c", title: "Swim notes", publisher: "Riverside Swim Club",
                                url: URL(string: "https://swim.example.org/pool")!, published: readOn,
                                text: "The pool reopens on November 10.")
        let summary = try #require(parsed("""
            POINT: The pool reopens on November 10. [2][3]
            DISAGREE: The Gazette says November 3 and the city says November 10. [1][2]
            """, sources: sources + [third]))
        let point = try #require(summary.points.first)
        #expect(point.sourceIDs == ["c"])
        #expect(point.disagreement?.sourceIDs == ["a", "b"])
        let only = try #require(parsed("""
            POINT: The city says it reopens on November 10. [2]
            DISAGREE: The Gazette says November 3 and the city says November 10. [1][2]
            """))
        #expect(only.points.map(\.sourceIDs) == [["b"]])
        #expect(only.points.first?.disagreement != nil)
    }

    /// A point the cloud put into words is a retelling. Kept as a note, it
    /// says so, and neither it nor its label names a publisher: which page
    /// each line came from is the cloud's word, never checked here, so the
    /// Gazette is never credited with words it didn't write.
    @Test func aCloudWordedPointIsNeverKeptAsThePublishersOwnWords() throws {
        let summary = try #require(parsed(Self.goodReply))
        let gazette = try #require(summary.points.first { $0.sourceIDs == ["a"] })
        let note = try #require(summary.note(for: gazette))
        #expect(note.hasPrefix(gazette.text))
        #expect(note.contains("(put into words in the cloud, from the sources it was given)"))
        #expect(!note.contains("Riverside Gazette"))
        #expect(!note.contains("City of Riverside Parks"))
        let source = try #require(summary.memorySource(for: gazette))
        #expect(source == .lookedUp(""))
        #expect(source.label == "From something I looked into")
        #expect(!source.label.contains("Riverside Gazette"))
    }

    /// Only the label and its colon count. A reply that writes "POINTS:"
    /// or "DISAGREEMENT:" never leaves "S:" or "MENT:" on the card.
    @Test func aLabelMustBeTheWholeWordAndAColon() throws {
        let summary = try #require(parsed("""
            POINTS: The pool reopens on November 10. [2]
            POINT: Family swim is on Saturdays. [2]
            DISAGREEMENT: The Gazette says November 3 and the city says November 10. [1][2]
            POINTER The snack bar is open. [1]
            POINT The pool has a sauna. [1]
            point: Lessons start the same week. [1]
            """))
        #expect(summary.points.map(\.text) == ["Family swim is on Saturdays.", "Lessons start the same week."])
        #expect(summary.disagreements.isEmpty)
        #expect(!summary.points.contains { $0.text.hasPrefix("S:") || $0.text.hasPrefix("MENT:") || $0.text.hasPrefix("ER") })
        #expect(parsed("POINTS: The pool reopens on November 10. [2]") == nil)
        // The prompt asks for exactly that.
        let prompt = CloudReconSummarizer.prompt(for: task, sources: sources)
        #expect(prompt.contains("SUMMARY:") && prompt.contains("POINT:") && prompt.contains("DISAGREE:"))
    }

    @Test func noSourcesMeansNothingToRead() {
        #expect(parsed("POINT: The pool reopens on November 10. [1]", sources: []) == nil)
    }

    /// A preview taken away before the person answered, as when the cloud
    /// was turned off or the screen went, never says they chose it.
    @Test func aWithdrawnPreviewGetsANeutralNote() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let summary = await CloudReconSummarizer(model: cloud(transport, RecordingReviewer(answer: .withdrawn)))
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(transport.sent.isEmpty)
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudWithdrawn)
        #expect(summary.note != ReconWords.declinedCloud)
    }

    /// Once the sign-in hop has gone, a summary whose request then didn't
    /// go says only the sign-in went, never that nothing did.
    @Test func aSummaryStoppedAfterTheSignInWentSaysTheSignInWent() async {
        let words = Words()
        let transport = SignInAddsAWordTransport(words: words, word: "Riverside")
        let model = CloudModel(endpoint: URL(string: "https://cloud.example.com")!, transport: transport,
                               reviewer: ScriptedReviewer(answers: [.send, .withdrawn]),
                               auth: SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8))),
                               redactor: { Redactor(privateWords: words.list) })
        let summary = await CloudReconSummarizer(model: model)
            .summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(transport.sent.map(\.url.path) == ["/v1/sign-in"])
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudSignInOnly)
    }

    @Test func aChatModelOnTheDeviceNeverMayLeaveIt() {
        #expect(!CloudReconSummarizer(model: LocalStubModel()).mayUseCloud)
        #expect(CloudReconSummarizer(model: cloud(RecordingTransport(), RecordingReviewer(answer: .send))).mayUseCloud)
        #expect(!LocalReconSummarizer().mayUseCloud)
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
        #expect(summary.note != ReconWords.wordedInCloud)
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
        // No one chose this, and nothing was put into words in the cloud, so
        // the card says neither. It says why, plainly.
        #expect(summary.note != ReconWords.declinedCloud)
        #expect(summary.note != ReconWords.wordedInCloud)
        #expect(summary.note == ReconWords.keptForCare)
    }

    // MARK: A yes, then something else

    /// The person said send, and the cloud was off by the time it would
    /// go. A yes was given, so the card never says nothing went because
    /// the preview was taken away.
    @Test func aYesThenTheCloudOffNeverSaysWithdrawn() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let power = Power()
        let reviewer = SwitchingReviewer(turningOff: power)
        let notes = notes
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               redactor: { Redactor(memory: notes, privateWords: []) }, isOn: { power.on })
        let summary = await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(reviewer.asked == 1)
        #expect(transport.sent.isEmpty)
        #expect(summary.note == ReconWords.cloudOff)
        #expect(summary.note != ReconWords.cloudWithdrawn)
        #expect(summary.note?.contains("Nothing went to the cloud") != true)
    }

    /// Off before any preview: nothing was asked, so nothing was taken
    /// away either. A plain line, not the withdrawn one.
    @Test func offBeforeAnyPreviewGetsAPlainOffLine() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .send)
        let notes = notes
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               redactor: { Redactor(memory: notes, privateWords: []) }, isOn: { false })
        let summary = await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
        #expect(summary.note == ReconWords.cloudOff)
        #expect(summary.note != ReconWords.cloudWithdrawn)
    }

    /// The person said send, and the work was stopped before an answer
    /// came. Never "nothing went to the cloud": after a yes, that isn't known.
    @Test func aYesThenAStopNeverSaysNothingWent() async {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = HeldYes()
        let notes = notes
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               redactor: { Redactor(memory: notes, privateWords: []) })
        let task = task, sources = sources, readOn = readOn
        let work = Task { await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn) }
        await reviewer.asked()
        work.cancel()
        reviewer.sayYes()
        let summary = await work.value
        // Stop came before the yes, so nothing was sent, ever: a send never
        // starts after Stop.
        #expect(transport.sent.isEmpty)
        #expect(summary.note == ReconWords.cloudStopped)
        #expect(summary.note != ReconWords.cloudWithdrawn)
        #expect(summary.note?.contains("Nothing went") != true)
        #expect(summary.note != ReconWords.declinedCloud)
    }

    /// The other order: Send, the request leaves, and Stop comes while it
    /// is on its way. It may have arrived, so the line never says nothing
    /// went, and it doesn't say anyone chose.
    @Test func aStopWhileTheSendIsOnItsWaySaysItWasStopped() async {
        let transport = HeldTransport(reply: Self.goodReply)
        let notes = notes
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send),
                               redactor: { Redactor(memory: notes, privateWords: []) })
        let task = task, sources = sources, readOn = readOn
        let work = Task { await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn) }
        await transport.sending()
        work.cancel()
        let summary = await work.value
        #expect(transport.sentCount == 1)
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudStopped)
        #expect(summary.note != ReconWords.cloudWithdrawn)
        for word in ["chose", "declined", "Nothing went"] {
            #expect(summary.note?.contains(word) != true, "says: \(word)")
        }
    }

    /// The request was handed over and the server answered with an error.
    /// It went, so the card never says the cloud couldn't be reached, as if
    /// nothing did.
    @Test func aServerErrorAfterTheSendNeverSaysNothingWent() async {
        let loads = Count()
        let transport = URLSessionCloudTransport(load: { request in
            _ = loads.next()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        let notes = notes
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send),
                               redactor: { Redactor(memory: notes, privateWords: []) })
        let summary = await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(loads.next() == 2, "the request never reached the transport")
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudFailedAfterSend)
        #expect(summary.note != ReconWords.cloudUnavailable)
        #expect(summary.note?.contains("may already have gone") == true)
    }

    /// A send the system cut short after the hand over, as a chat ended
    /// while it was on the wire, reads as a stop, never as nothing went.
    @Test func aSendCancelledOnTheWireSaysItWasStopped() async {
        let transport = HopThenThrowsTransport(error: URLError(.cancelled), hops: 0)
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send))
        let summary = await CloudReconSummarizer(model: model).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(transport.paths == ["/v1/reply"])
        #expect(summary.note == ReconWords.cloudStopped)
    }

    /// Refused on this device before anything was handed over: the notes
    /// couldn't be read, or the send couldn't be noted. Nothing went, and
    /// the card says so.
    @Test func aRefusalOnTheDeviceSaysNothingWent() async {
        struct Unreadable: Error {}
        let unread = RecordingTransport(reply: Self.goodReply)
        let unreadable = CloudModel(endpoint: endpoint, transport: unread, reviewer: RecordingReviewer(answer: .send),
                                    redactor: { throw Unreadable() })
        let first = await CloudReconSummarizer(model: unreadable).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(unread.sent.isEmpty)
        #expect(first.note == ReconWords.cloudWithdrawn)
        let unnoted = RecordingTransport(reply: Self.goodReply)
        let notRecorded = CloudModel(endpoint: endpoint, transport: unnoted, reviewer: RecordingReviewer(answer: .send),
                                     session: CloudChatSession(handingOver: { throw Unreadable() }))
        let second = await CloudReconSummarizer(model: notRecorded).summarize(task, id: "task:1", sources: sources, gatheredAt: readOn)
        #expect(unnoted.sent.isEmpty)
        #expect(second.note == ReconWords.cloudWithdrawn)
    }

    /// Both lines for a yes that couldn't be used, word for word, so a
    /// change to either is a choice someone made.
    @Test func theYesPathLinesAreTheseExactly() {
        #expect(ReconWords.cloudOff == "Help from the cloud was off by then, so I put this together without it.")
        #expect(ReconWords.cloudStopped
                == "It was stopped after you said send, so some of what I read may already have gone to the cloud. I put this together without it.")
        for line in [ReconWords.cloudOff, ReconWords.cloudStopped] {
            #expect(line != ReconWords.cloudWithdrawn)
            #expect(!line.contains("chose") && !line.contains("declined") && !line.contains("Nothing went"))
        }
    }

    /// A reply that dresses its labels as a list or in bold is still read,
    /// and the marks never reach the card.
    @Test func aDecoratedLabelIsStillRead() throws {
        let summary = try #require(parsed("""
            **SUMMARY:** The pool reopens in November. [1][2]
            - POINT: The pool reopens on November 10. [2]
            * **POINT:** Family swim is on Saturdays. [2]
            • POINT: Lessons start the same week. [1]
            **DISAGREE:** The Gazette says November 3 and the city says November 10. [1][2]
            - POINTS: Not a label. [1]
            """))
        #expect(summary.points.map(\.text).contains("Family swim is on Saturdays."))
        #expect(summary.points.map(\.text).contains("Lessons start the same week."))
        #expect(summary.disagreements.count == 1)
        #expect(!summary.points.contains { $0.text.contains("*") || $0.text.hasPrefix("-") || $0.text.contains("Not a label") })
    }

    /// The topic a summary's request asks about is read back from what was
    /// sent, so Today's preview can say what it is for.
    @Test func theTopicIsReadBackFromTheRequest() async throws {
        let reviewer = RecordingReviewer(answer: .cancel)
        let asked = try #require(ReconTask(topic: "Priya's lemon cake order"))
        _ = await CloudReconSummarizer(model: cloud(RecordingTransport(), reviewer))
            .summarize(asked, id: "task:1", sources: sources, gatheredAt: readOn)
        let preview = try #require(reviewer.seen.first)
        #expect(preview.forSummary)
        // As it was sent: masked.
        #expect(CloudReconSummarizer.topic(asked: preview) == "[name]'s [private] order")
        // A chat's own message is no summary.
        let chat = try CloudModel.preview(for: [ChatTurn(id: UUID(), speaker: .person, text: "Plan my week.")],
                                          endpoint: endpoint, redactor: Redactor())
        #expect(CloudReconSummarizer.topic(asked: chat) == nil)
    }

    /// A chat whose words are a summary's own, typed or pasted, is still a
    /// chat: its preview is never marked as a summary's, so Today's line
    /// about a summary can't label it.
    @Test func aChatInASummarysWordsIsNoSummary() async throws {
        let asked = try #require(ReconTask(topic: "the pool"))
        for text in ["Please look into the pool using only the sources below, and answer in plain words.",
                     CloudReconSummarizer.prompt(for: asked, sources: sources)] {
            let reviewer = RecordingReviewer(answer: .cancel)
            let transport = RecordingTransport()
            let chat = Conversation(turns: [ChatTurn(id: UUID(), speaker: .person, text: text)], place: .mayLeaveDevice)
            _ = try? await chat.appendingReply(from: cloud(transport, reviewer))
            let preview = try #require(reviewer.seen.first)
            #expect(preview.request.text.contains("Please look into the pool using only the sources below"))
            #expect(!preview.forSummary)
            #expect(CloudReconSummarizer.topic(asked: preview) == nil)
            #expect(transport.sent.isEmpty)
        }
    }

    /// The overview of a summary worded in the cloud is never blank: the
    /// plain one stands in, so the card never shows an empty line.
    @Test func aCloudSummaryAlwaysHasAnOverview() throws {
        let summary = try #require(parsed("POINT: Family swim is on Saturdays. [2]"))
        #expect(!summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(summary.overview == "I read 2 sources on the Riverside pool reopening.")
    }

    // MARK: The topic is the person's own words

    /// The topic goes in the request, so it is redacted like everything
    /// else: a name from the notes and a private word are masked in the
    /// preview and in the bytes that went.
    @Test func theTopicIsMaskedInThePreviewAndTheBytesSent() async throws {
        let transport = RecordingTransport(reply: Self.goodReply)
        let reviewer = RecordingReviewer(answer: .send)
        let asked = try #require(ReconTask(topic: "Priya's lemon cake order"))
        _ = await CloudReconSummarizer(model: cloud(transport, reviewer))
            .summarize(asked, id: "task:1", sources: sources, gatheredAt: readOn)
        let preview = try #require(reviewer.seen.first)
        #expect(transport.sent == [preview.request])
        let payload = try JSONDecoder().decode(CloudPayload.self, from: preview.request.body)
        let first = try #require(payload.messages.first { $0.role == "person" })
        #expect(first.text.hasPrefix("Please look into [name]"))
        for text in [preview.request.text] + transport.sent.map(\.text) {
            #expect(!text.contains("Priya"))
            #expect(!text.localizedCaseInsensitiveContains("lemon cake"))
        }
        // A private word alone in the topic is masked too.
        let reviewer2 = RecordingReviewer(answer: .send)
        let transport2 = RecordingTransport(reply: Self.goodReply)
        let cake = try #require(ReconTask(topic: "the lemon cake contest"))
        _ = await CloudReconSummarizer(model: cloud(transport2, reviewer2))
            .summarize(cake, id: "task:2", sources: sources, gatheredAt: readOn)
        let body = try #require(reviewer2.seen.first).request.text
        #expect(body.contains("Please look into the [private] contest"))
        #expect(transport2.sent.allSatisfy { !$0.text.localizedCaseInsensitiveContains("lemon cake") })
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
        let on = ModelChoice.model(settings: CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, local: LocalStubModel()) { _ in
            cloud(RecordingTransport(), RecordingReviewer(answer: .send))
        }
        #expect(ReconSummarizers.choose(for: on) is CloudReconSummarizer)
        #expect(ReconSummarizers.choose(for: LocalStubModel()) is LocalReconSummarizer)
    }

    /// A yes given for another address is no yes here, so a summary is put
    /// together on this device and no cloud model is made for it.
    @Test func aSummaryUsesTheCloudOnlyWithTheYesForThisAddress() {
        let elsewhere = URL(string: "https://other.example.com")!
        var made = 0
        let model = ModelChoice.model(settings: CloudHelpSettings(isOn: true, for: elsewhere), endpoint: endpoint,
                                      local: LocalStubModel()) { _ in
            made += 1
            return cloud(RecordingTransport(), RecordingReviewer(answer: .send))
        }
        #expect(ReconSummarizers.choose(for: model) is LocalReconSummarizer)
        #expect(made == 0)
    }

    @Test func thePromptReadsPlainlyAndHasNoDashes() {
        let prompt = CloudReconSummarizer.prompt(for: task, sources: sources)
        #expect(prompt.hasPrefix("Please look into the Riverside pool reopening"))
        #expect(prompt.contains("[1] Pool reopens. Riverside Gazette,"))
        #expect(prompt.contains("[2] Fall schedule. City of Riverside Parks,"))
        #expect(!prompt.contains("\u{2014}") && !prompt.contains("\u{2013}"))
    }
}

/// Whether the cloud setting is on, turned off by a test.
final class Power: @unchecked Sendable {
    private let lock = NSLock()
    private var isOn = true
    var on: Bool { lock.withLock { isOn } }
    func turnOff() { lock.withLock { isOn = false } }
}

/// Says send, and turns the cloud off as it does, as when another window
/// turned it off right after the yes.
final class SwitchingReviewer: CloudReviewing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let power: Power
    init(turningOff power: Power) { self.power = power }
    var asked: Int { lock.withLock { count } }
    func review(_ preview: CloudPreview) async -> CloudConsent {
        lock.withLock { count += 1 }
        power.turnOff()
        return .send
    }
}

/// Takes the request, then holds the answer until the work is cancelled,
/// as a send cut short on its way would be. Never touches the network.
final class HeldTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var watcher: CheckedContinuation<Void, Never>?
    let reply: String
    init(reply: String) { self.reply = reply }
    var sentCount: Int { lock.withLock { count } }

    func start(_ request: CloudRequest) -> Task<Data, Error> { Task { try await send(request) } }

    func send(_ request: CloudRequest) async throws -> Data {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            count += 1
            defer { watcher = nil }
            return watcher
        }
        waiting?.resume()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw CancellationError()
    }

    /// Waits until a request has been handed over.
    func sending() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if count > 0 { return true }
                watcher = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Holds its yes until the test gives it, whatever happens meanwhile, so
/// a test can stop the work between the preview and the yes landing.
final class HeldYes: CloudReviewing, @unchecked Sendable {
    private let lock = NSLock()
    private var yes: CheckedContinuation<Void, Never>?
    private var given = false
    private var seen: CheckedContinuation<Void, Never>?
    private var wasAsked = false

    func review(_ preview: CloudPreview) async -> CloudConsent {
        let watcher: CheckedContinuation<Void, Never>? = lock.withLock {
            wasAsked = true
            defer { seen = nil }
            return seen
        }
        watcher?.resume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if given { return true }
                yes = continuation
                return false
            }
            if now { continuation.resume() }
        }
        return .send
    }

    /// Waits until a preview has been asked about.
    func asked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if wasAsked { return true }
                seen = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func sayYes() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            given = true
            defer { yes = nil }
            return yes
        }
        waiting?.resume()
    }
}
