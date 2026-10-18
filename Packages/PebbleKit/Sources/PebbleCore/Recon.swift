import Foundation

/// One document the agent read while looking into something.
public struct ReconSource: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Who published it, such as "Riverside Gazette".
    public let publisher: String
    public let url: URL
    /// When it was published.
    public let published: Date
    public let text: String

    public init(id: String, title: String, publisher: String, url: URL, published: Date, text: String) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.url = url
        self.published = published
        self.text = text
    }

    /// More than a year old when it was read, so the card says so.
    public func isOld(at date: Date) -> Bool {
        date.timeIntervalSince(published) > 365 * 86_400
    }

    /// The page to open, only when it is an https address. Any other kind,
    /// such as a phone number or another app, is never opened from a card.
    public var link: URL? {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false ? url : nil
    }
}

/// One thing the sources say, and which of them say it.
public struct ReconPoint: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    /// Never empty in a `ReconSummary`: a point without a source is dropped.
    /// Only the sources that say these words. A source that says otherwise
    /// is named in `disagreement`, never here.
    public let sourceIDs: [String]
    /// Set when the sources don't agree on this point. Its sources are
    /// every side, this point's included.
    public let disagreement: ReconDisagreement?

    public init(id: String, text: String, sourceIDs: [String], disagreement: ReconDisagreement? = nil) {
        self.id = id
        self.text = text
        self.sourceIDs = sourceIDs
        self.disagreement = disagreement
    }
}

/// Where sources don't agree, said plainly, with the sources on each side.
public struct ReconDisagreement: Sendable, Equatable {
    public let text: String
    /// At least two, or it isn't a disagreement.
    public let sourceIDs: [String]

    public init(text: String, sourceIDs: [String]) {
        self.text = text
        self.sourceIDs = sourceIDs
    }
}

/// What came of looking into something: a short summary, a few key points
/// and the sources behind each one.
///
/// No claim without a source. The initializer drops any point whose sources
/// aren't among `sources`, and any disagreement with fewer than two, so a
/// summary can't carry a line nobody said, whoever wrote it.
public struct ReconSummary: Identifiable, Sendable, Equatable {
    public static let maxPoints = 5

    /// The task it came from.
    public let id: String
    public let topic: String
    /// A short plain summary. It describes what was read and makes no claim
    /// of its own, unless `overviewSourceIDs` says where it came from. Always
    /// the plain one when the summary was put into words in the cloud.
    public let overview: String
    public let overviewSourceIDs: [String]
    public let points: [ReconPoint]
    public let sources: [ReconSource]
    /// When the sources were read.
    public let gatheredAt: Date
    /// True when every word was put together on this device.
    public let madeOnDevice: Bool
    /// A line about how it was made, such as when the person chose not to
    /// send it to the cloud. Never nil when it was put into words in the
    /// cloud, so its points are never taken for the sources' own words.
    public let note: String?

    public init(id: String, topic: String, overview: String, overviewSourceIDs: [String] = [],
                points: [ReconPoint], sources: [ReconSource], gatheredAt: Date,
                madeOnDevice: Bool, note: String? = nil) {
        let known = Set(sources.map(\.id))
        self.id = id
        self.topic = topic
        self.sources = sources
        self.gatheredAt = gatheredAt
        self.madeOnDevice = madeOnDevice
        self.note = note ?? (madeOnDevice ? nil : ReconWords.wordedInCloud)
        self.points = Array(points.compactMap { point -> ReconPoint? in
            let ids = Self.unique(point.sourceIDs.filter(known.contains))
            let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ids.isEmpty, !text.isEmpty else { return nil }
            let disagreement = point.disagreement.flatMap { found -> ReconDisagreement? in
                let sides = Self.unique(found.sourceIDs.filter(known.contains))
                return sides.count >= 2 ? ReconDisagreement(text: found.text, sourceIDs: sides) : nil
            }
            return ReconPoint(id: point.id, text: text, sourceIDs: ids, disagreement: disagreement)
        }.prefix(Self.maxPoints))
        let overviewIDs = Self.unique(overviewSourceIDs.filter(known.contains))
        // An overview that names sources must name real ones. One put into
        // words in the cloud is never used at all: the card shows no source
        // numbers beside it, so it would sit on top as a claim no one made.
        // The plain one stands in, which only says what was read. For the
        // cloud's points it doesn't count which have more than one source:
        // those numbers are the cloud's own, not something read here.
        if !madeOnDevice || (!overviewSourceIDs.isEmpty && overviewIDs.isEmpty) {
            let backedTwice = madeOnDevice ? self.points.filter { $0.sourceIDs.count > 1 && $0.disagreement == nil }.count : 0
            self.overview = ReconWords.overview(topic: topic, sources: sources.count,
                                                backedTwice: backedTwice,
                                                disagreements: self.points.filter { $0.disagreement != nil }.count,
                                                old: sources.filter { $0.isOld(at: gatheredAt) }.count)
            self.overviewSourceIDs = []
        } else {
            self.overview = overview
            self.overviewSourceIDs = overviewIDs
        }
    }

    public var disagreements: [ReconDisagreement] { points.compactMap(\.disagreement) }

    public func source(_ id: String) -> ReconSource? { sources.first { $0.id == id } }

    /// The number the card shows next to a source, counting from 1.
    public func number(of id: String) -> Int? {
        sources.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Sources more than a year old when they were read.
    public var oldSources: [ReconSource] { sources.filter { $0.isOld(at: gatheredAt) } }

    /// What a point becomes as a memory note: its words, the sources that
    /// say them, and, when the sources don't agree, that they don't and what
    /// each says. A disputed point is never kept as if it were settled.
    ///
    /// Words put into words in the cloud say so in the note, so a retelling
    /// is never kept as the publisher's own words. When the whole
    /// disagreement would make the note too long to keep, it names only the
    /// sides, since the person can't shorten a note they didn't write.
    public func note(for point: ReconPoint) -> String {
        let from = point.sourceIDs.compactMap(source).map {
            "\($0.publisher), \($0.published.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
        let full = ReconWords.memoryNote(point.text, from: from, disagreement: point.disagreement?.text,
                                         wordedInCloud: !madeOnDevice)
        guard let disagreement = point.disagreement, !Self.fits(full) else { return full }
        let sides = disagreement.sourceIDs.compactMap(source).map(\.publisher)
        return ReconWords.memoryNote(point.text, from: from, disagreement: ReconWords.disputedBy(sides),
                                     wordedInCloud: !madeOnDevice)
    }

    /// Where a remembered point says it came from. A point worded on this
    /// device is a sentence its first source says, so it names that source.
    /// One worded in the cloud is a retelling, so it names no publisher.
    public func memorySource(for point: ReconPoint) -> MemorySource {
        guard madeOnDevice else { return .lookedUp("") }
        return .lookedUp(point.sourceIDs.first.flatMap(source)?.publisher ?? "")
    }

    private static func fits(_ note: String) -> Bool {
        note.count <= MemoryStore.maxLength && note.utf8.count <= MemoryStore.maxBytes
    }

    /// True when every source behind the point was more than a year old
    /// when it was read.
    public func restsOnOldPages(_ point: ReconPoint) -> Bool {
        let behind = point.sourceIDs.compactMap(source)
        return !behind.isEmpty && behind.allSatisfy { $0.isOld(at: gatheredAt) }
    }

    /// The whole summary as plain text, for a reader that shows only text.
    public var plainText: String {
        var lines = [overview, ""]
        for point in points {
            let refs = point.sourceIDs.compactMap(number).map { "[\($0)]" }.joined()
            lines.append("\(point.text) \(refs)")
            if let disagreement = point.disagreement { lines.append(disagreement.text) }
        }
        lines.append("")
        for (index, source) in sources.enumerated() {
            lines.append("[\(index + 1)] \(source.title). \(source.publisher), \(source.published.formatted(date: .abbreviated, time: .omitted)).")
        }
        return lines.joined(separator: "\n")
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Something the person asked the agent to look into, run as a task:
/// plan a few questions, gather from sources, then summarize.
public struct ReconTask: Sendable, Equatable {
    public static let maxTopicLength = 120

    /// What to look into, in the person's words, such as "the Riverside pool reopening".
    public let topic: String
    /// The questions the agent asks of the sources.
    public let questions: [String]

    /// Nil for an empty or very long topic, and for anything with words of
    /// crisis: those get care, never a task.
    public init?(topic proposed: String) {
        let topic = proposed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .?!,;:"))
        guard topic.count >= 2, topic.count <= Self.maxTopicLength, !CareCheck.needsCare(topic) else { return nil }
        self.topic = topic
        questions = ReconWords.questions(about: topic)
    }

    /// The card's title, such as "Look into the Riverside pool reopening".
    public var title: String { ReconWords.title(topic) }

    /// The steps the card shows, played by the task engine.
    public func script(sources: Int) -> TaskScript {
        guard sources > 0 else {
            return TaskScript(title: title, steps: [
                .init(ReconWords.planning, duration: 3, kept: ReconWords.keptQuestions, todo: ReconWords.planTodo),
                .init(ReconWords.looking, duration: 4, todo: ReconWords.readTodo),
            ], doneLine: ReconWords.nothingFoundLine)
        }
        return TaskScript(title: title, steps: [
            .init(ReconWords.planning, duration: 3, kept: ReconWords.keptQuestions, todo: ReconWords.planTodo),
            .init(ReconWords.reading(sources), duration: 6, kept: ReconWords.keptSources(sources), todo: ReconWords.readTodo),
            .init(ReconWords.checkingDates, duration: 3, todo: ReconWords.datesTodo),
            .init(ReconWords.puttingTogether, duration: 3, kept: ReconWords.keptSummary, todo: ReconWords.summaryTodo),
        ], doneLine: ReconWords.doneLine)
    }
}

/// Finds "look into ..." and the like in what the person said, so the chat
/// can offer to start it. It never starts anything by itself.
public enum ReconIntent {
    /// The topic, or nil when this isn't a request to look into something.
    /// Words of crisis are never a topic.
    public static func topic(in text: String) -> String? {
        guard !CareCheck.needsCare(text) else { return nil }
        var said = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let lower = { said.lowercased() }
        // Kind openers come off first, any number of them, in any order, and
        // so does a name before a comma, as in "Hey Pip, look into ...".
        var trimmed = true
        // "Would you mind" takes the verb as "looking into", so only after
        // it do those forms count. On their own they start a statement.
        var minding = false
        while trimmed {
            trimmed = false
            for opener in openers where lower().hasPrefix(opener + " ") || lower().hasPrefix(opener + ",") {
                said = String(said.dropFirst(opener.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if opener == "would you mind" { minding = true }
                trimmed = true
                break
            }
            if !trimmed, let first = said.split(separator: " ").first, first.hasSuffix(","),
               !verbs.contains(where: { lower().hasPrefix($0 + " ") }) {
                said = String(said.dropFirst(first.count)).trimmingCharacters(in: CharacterSet(charactersIn: " "))
                trimmed = true
            }
        }
        let asked = minding ? gerunds + verbs : verbs
        guard let verb = asked.first(where: { lower().hasPrefix($0 + " ") }) else { return nil }
        var topic = String(said.dropFirst(verb.count + 1))
        topic = topic.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
        for ending in endings where topic.lowercased().hasSuffix(ending) {
            topic = String(topic.dropLast(ending.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        let first = topic.split(separator: " ").first.map { $0.lowercased() } ?? ""
        // "Research shows ..." is a statement, and "look into it" has no topic.
        guard !notTopics.contains(topic.lowercased()), !statementWords.contains(first) else { return nil }
        return ReconTask(topic: topic)?.topic
    }

    /// Longest first, so "would you mind" comes off whole rather than
    /// leave "mind" behind as if it were the start of the request.
    private static let openers = [
        "hey", "hi", "ok", "okay", "so", "please", "pls", "can you", "could you", "would you",
        "will you", "i'd like you to", "i want you to", "i need you to", "would you mind",
        "help me", "go and", "go",
    ].sorted { $0.count > $1.count }
    private static let verbs = [
        "look into", "research", "find out more about", "find out about", "dig into", "read up on",
    ]
    private static let gerunds = [
        "looking into", "researching", "finding out more about", "finding out about", "digging into", "reading up on",
    ]
    private static let endings = ["for me please", "for me", "please", "if you can", "when you can"]
    private static let notTopics: Set<String> = ["it", "this", "that", "them", "these", "those", "that for me", "something"]
    /// A word right after "research" that makes the sentence a statement.
    private static let statementWords: Set<String> = [
        "shows", "says", "suggests", "is", "are", "was", "were", "has", "have", "found", "finds",
        "indicates", "proves", "papers", "paper",
    ]
}

/// Where a recon gets its sources.
///
/// `PebbleCore` doesn't do networking, so the providers here read documents
/// already on this device. A provider that reaches the network would live in
/// another layer, and `ReconRunner` refuses any provider that doesn't run on
/// this device.
public protocol SourceProvider: Sendable {
    /// The documents worth reading for `task`, most useful first.
    func sources(for task: ReconTask) throws -> [ReconSource]
    /// True only when reading never leaves this device.
    var runsOnDevice: Bool { get }
    /// True when the documents are examples.
    var isSample: Bool { get }
}

extension SourceProvider {
    public var runsOnDevice: Bool { false }
    public var isSample: Bool { false }
}

/// Sample documents kept on this device, for the showcase, tests, and the
/// app until a real provider is plugged in. Nothing here goes to the network.
///
/// Each page is dated a set number of days before it is read, so a page
/// never looks as if it came from the future, whenever the app runs.
public struct SampleSources: SourceProvider {
    public static let limit = 4
    /// When the pages are read. The wall clock, unless a test or the
    /// showcase holds it still.
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public var runsOnDevice: Bool { true }
    public var isSample: Bool { true }

    /// Every page, dated as of now.
    public var documents: [ReconSource] { Self.documents(readOn: now()) }

    public func sources(for task: ReconTask) throws -> [ReconSource] {
        let wanted = ReconText.keywords(task.topic)
        guard !wanted.isEmpty else { return [] }
        let needed = min(2, wanted.count)
        let scored = documents.map { doc in
            (doc, ReconText.keywords(doc.title + " " + doc.text).intersection(wanted).count)
        }
        return scored.filter { $0.1 >= needed }
            .sorted { ($0.1, $0.0.published) > ($1.1, $1.0.published) }
            .prefix(Self.limit)
            .map(\.0)
    }

    /// The topic the showcase looks into. Its sources disagree on one date.
    public static let poolTopic = "the Riverside pool reopening"
    /// A topic whose sources agree.
    public static let libraryTopic = "the library's new Sunday hours"

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 9
        return Calendar(identifier: .gregorian).date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// Made up documents on domains kept for examples, each dated `daysOld`
    /// days before `readOn`. One is more than a year old.
    public static func documents(readOn: Date) -> [ReconSource] {
        func page(_ id: String, _ title: String, _ publisher: String, _ url: String, daysOld: Int, _ text: String) -> ReconSource {
            ReconSource(id: id, title: title, publisher: publisher, url: URL(string: url)!,
                        published: readOn - TimeInterval(daysOld) * 86_400, text: text)
        }
        return [
            page("sample:gazette-pool", "Riverside Pool reopens after repairs", "Riverside Gazette",
                 "https://gazette.example.org/riverside-pool-reopens", daysOld: 7,
                 "The Riverside community pool will reopen on November 3 after six months of roof repairs. The city says the new roof lets in more daylight and keeps the hall warmer in winter. Swim lessons for children restart the same week, and sign up opens online on October 20."),
            page("sample:parks-pool", "Pool schedule for the fall season", "City of Riverside Parks",
                 "https://parks.example.org/riverside-pool/fall", daysOld: 3,
                 "Riverside Pool reopens on November 10, a week later than first planned, because the final safety check moved. Family swim runs on Saturdays from 9 to noon. Swim lessons for children start in the week of November 10, and sign up opens on October 20."),
            page("sample:parents-pool", "What families should know about the Riverside pool", "Northside Parents",
                 "https://parents.example.org/riverside-pool-guide", daysOld: 5,
                 "The new changing rooms at the Riverside pool have family stalls and a step free entrance. Parents say the Saturday family swim fills up fast, so arrive early. A day pass costs 6 dollars for adults and 3 dollars for children."),
            page("sample:council-pool", "Council approves pool repair budget", "Riverside Gazette",
                 "https://gazette.example.org/council-pool-budget", daysOld: 594,
                 "City council approved 2.4 million dollars to repair the Riverside pool roof. Work was expected to take six months."),
            page("sample:gazette-library", "Library adds Sunday hours", "Riverside Gazette",
                 "https://gazette.example.org/library-sundays", daysOld: 16,
                 "The Riverside Library will open on Sundays from noon to 5, starting in November. Weekday hours stay the same, from 9 to 8. Reading programs for children will run on Sunday afternoons."),
            page("sample:library-hours", "Hours and holidays", "Riverside Public Library",
                 "https://library.example.org/hours", daysOld: 14,
                 "From November, the library is open on Sundays from noon to 5. The library is closed on November 11 for Remembrance Day. Weekend reading programs for children run on Sunday afternoons."),
            page("sample:school-lunch", "November lunch menu", "Elm Street School",
                 "https://school.example.org/lunch/november", daysOld: 2,
                 "Pizza day moves to Thursdays in November. Every lunch now comes with fruit."),
        ]
    }
}

/// Words for looking into something: the offer in the chat, the steps on the
/// card, and the summary.
public enum ReconWords {
    // The offer in the chat.
    /// `examples` while the only pages there are to read are the sample
    /// ones, so the offer never promises real sources it doesn't have. It
    /// says where they are kept only when `place` says every word stays here.
    public static func offer(_ topic: String, examples: Bool = false, place: PrivacyPlace = .mayLeaveDevice) -> String {
        guard examples else {
            return "Want me to look into \(topic)? I'll read a few sources and bring a short summary to Today, with where each point came from."
        }
        let pages = place.staysOnDevice ? "a few example pages kept on this device" : "a few example pages"
        return "Want me to look into \(topic)? For now I can only read \(pages), so it will be an example, not real news. I'll bring a short summary to Today, with where each point came from."
    }
    public static let offerYes = "Look into it"
    public static let offerNo = "Not now"
    /// What VoiceOver says each choice does.
    public static let offerYesHint = "Starts looking into it. It shows up in Today when it's ready."
    public static let offerNoHint = "Nothing starts."
    public static let started = "I'm on it. You'll find it in Today when it's ready."
    public static let offerDeclined = "Okay, I'll leave it. Just ask if you change your mind."
    public static let couldNotStart = "Sorry, I couldn't start that just now. You can ask me again in a moment."

    // The task.
    public static func title(_ topic: String) -> String { "Look into \(topic)" }
    public static func questions(about topic: String) -> [String] {
        ["What is happening with \(topic)?", "What has changed lately?", "Do the sources agree?"]
    }
    public static let planning = "Planning a few questions"
    public static let looking = "Looking for sources"
    public static func reading(_ count: Int) -> String { count == 1 ? "Reading 1 source" : "Reading \(count) sources" }
    public static let checkingDates = "Checking the dates"
    public static let puttingTogether = "Putting it together"
    public static let doneLine = "Here's what I found."
    public static let nothingFoundLine = "I couldn't find anything on this."
    /// The sources couldn't be read at all. A failure, not an empty result.
    public static let couldNotRead = "I couldn't read my sources just now, so I have nothing to tell you yet. You can ask me again in a moment."
    public static let planTodo = "plan the questions"
    public static let readTodo = "read the sources"
    public static let datesTodo = "check the dates"
    public static let summaryTodo = "put the summary together"
    public static let keptQuestions = "a few questions"
    public static func keptSources(_ count: Int) -> String { count == 1 ? "1 source" : "\(count) sources" }
    public static let keptSummary = "a short summary"

    // The summary.
    public static func overview(topic: String, sources: Int, backedTwice: Int, disagreements: Int, old: Int) -> String {
        guard sources > 0 else { return nothingFound(topic) }
        var lines = [sources == 1 ? "I read 1 source on \(topic)." : "I read \(sources) sources on \(topic)."]
        if backedTwice == 1 {
            lines.append("One point comes from more than one of them.")
        } else if backedTwice > 1 {
            lines.append("\(backedTwice) points come from more than one of them.")
        }
        if disagreements == 1 {
            lines.append("They don't agree on one thing, so I marked it.")
        } else if disagreements > 1 {
            lines.append("They don't agree on \(disagreements) things, so I marked them.")
        }
        if old == 1 {
            lines.append("One of them is more than a year old.")
        } else if old > 1 {
            lines.append("\(old) of them are more than a year old.")
        }
        return lines.joined(separator: " ")
    }
    public static func nothingFound(_ topic: String) -> String {
        "I couldn't find anything about \(topic) in the sources I can read yet, so there's nothing to report."
    }
    /// "Sources don't agree on this. Riverside Gazette says November 3. City of
    /// Riverside Parks says November 10, and theirs is the newer page."
    public static func disagreement(_ sides: [(publisher: String, says: String)], newest: String?) -> String {
        var lines = ["Sources don't agree on this."]
        for side in sides {
            if side.publisher == newest {
                lines.append("\(side.publisher) says \(side.says), and theirs is the newer page.")
            } else {
                lines.append("\(side.publisher) says \(side.says).")
            }
        }
        return lines.joined(separator: " ")
    }
    public static let sourcesHeading = "Sources"
    public static let pointsHeading = "What I found"
    /// Under the points a card has room for.
    public static func morePoints(_ count: Int) -> String {
        count == 1 ? "1 more point is in Open sources." : "\(count) more points are in Open sources."
    }
    public static let olderLabel = "More than a year old"
    public static func gathered(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Gathered today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Gathered yesterday at \(time)"
        }
        return "Gathered on \(date.formatted(.dateTime.month(.wide).day()))"
    }
    /// What VoiceOver says after a point, such as "From Riverside Gazette and City of Riverside Parks."
    public static func from(_ publishers: [String]) -> String {
        var seen: Set<String> = []
        let names = publishers.filter { seen.insert($0).inserted }
        return "From \(TaskWords.list(names, joiner: "and"))."
    }
    public static func sourceNumber(_ number: Int) -> String { "Source \(number)" }
    // Shown only on a summary the cloud was asked for, so they name the
    // cloud, not the device: docs/VOICE.md keeps device lines for when the
    // flag says every word stays here.
    public static let declinedCloud = "You chose not to send it, so I put this together without the cloud."
    public static let cloudUnreadable = "I couldn't use the answer from the cloud, so I put this together without it."
    public static let cloudUnavailable = "I couldn't reach the cloud just now, so I put this together without it."
    /// The preview was taken away before anyone answered it, as when the
    /// cloud was turned off or the screen went away. No one chose anything.
    public static let cloudWithdrawn = "Nothing went to the cloud, so I put this together without it."
    /// Under a summary put into words in the cloud: its points are a
    /// retelling, not the sources' own words.
    public static let wordedInCloud = "Put into words in the cloud, from these sources. Open sources to read what each one says."
    /// Kept on Today after Forget everything, when a summary was being put
    /// together in the cloud. What may already have gone can't be called back.
    public static let forgotWhileInCloud = "If I'd already sent sources to the cloud for a summary, that can't be called back. Nothing else was sent."

    // The actions.
    public static let openSourcesTitle = "Open sources"
    public static let followUpTitle = "Ask a follow-up"
    public static let rememberTitle = "Remember a point"
    public static let openSourcesHint = "Shows each source and what it says."
    public static let followUpHint = "Opens the chat with a question ready. Nothing is sent."
    public static let rememberHint = "Lets you choose a point to keep in your notes."
    public static func followUpDraft(_ topic: String) -> String { "Tell me more about \(topic)." }
    public static let rememberQuestion = "Which point should I remember?"
    /// Promises the device only when `place` says every word stays here,
    /// like `MemoryWords.saved`. A kept point is the person's own note: it
    /// stays when the card goes, or when the tasks are forgotten, until
    /// they delete it or forget everything.
    public static func rememberDetail(_ place: PrivacyPlace) -> String {
        place.staysOnDevice
            ? "I'll keep it in your notes with where it came from. It's still there after this card goes, until you delete it or forget everything. Notes stay on this device."
            : "I'll keep it in your notes with where it came from. It's still there after this card goes, until you delete it or forget everything."
    }
    public static let rememberThis = "Remember this"
    public static let remembered = "Remembered"
    /// What VoiceOver says for one point's button, so a button heard on its
    /// own still says which point it keeps.
    public static func rememberThisLabel(_ point: String) -> String { "Remember this: \(point)" }
    public static func rememberedLabel(_ point: String) -> String { "Remembered: \(point)" }
    /// A second tap on Look into it, while that one is going or ready.
    public static let alreadyOn = "I'm already on that one. Its card is here in Today."
    public static let pageLinkTitle = "Open the page"
    /// The point, who says it, and any disagreement after it. When it was
    /// `wordedInCloud`, the brackets say so, so the words are never kept as
    /// the publisher's own.
    public static func memoryNote(_ point: String, from sources: [String], disagreement: String? = nil,
                                  wordedInCloud: Bool = false) -> String {
        let said: String
        if wordedInCloud {
            said = sources.isEmpty ? "\(point) (put into words in the cloud)"
                : "\(point) (put into words in the cloud from \(sources.joined(separator: "; ")))"
        } else {
            said = sources.isEmpty ? point : "\(point) (\(sources.joined(separator: "; ")))"
        }
        guard let disagreement else { return said }
        return "\(said) \(disagreement)"
    }
    /// A disagreement cut down to its sides, for a note that would
    /// otherwise be too long to keep.
    public static func disputedBy(_ publishers: [String]) -> String {
        var seen: Set<String> = []
        let names = publishers.filter { seen.insert($0).inserted }
        return names.count < 2 ? "Sources don't agree on this."
            : "\(TaskWords.list(names, joiner: "and")) don't agree on this."
    }

    // A feed card that offers to look into something.
    public static let lookIntoTitle = "Look into it"
    public static let lookIntoHint = "Starts looking into it. It shows up here when it's ready."
    /// What the person would say, put in the chat when the feed can't start it.
    public static func askLine(_ topic: String) -> String { "Look into \(topic) for me." }

    /// Every fixed line, for the dash and tone checks.
    public static var all: [String] {
        [offer("the pool"), offer("the pool", examples: true, place: .onDevice),
         offer("the pool", examples: true, place: .mayLeaveDevice), offerYes, offerNo, offerYesHint, offerNoHint,
         started, offerDeclined,
         couldNotStart, title("the pool"),
         planning, looking, reading(1), reading(4), checkingDates, puttingTogether, doneLine, nothingFoundLine,
         couldNotRead, wordedInCloud, forgotWhileInCloud,
         memoryNote("The pool opens.", from: ["A", "B"], disagreement: "Sources don't agree on this."),
         memoryNote("The pool opens.", from: ["A", "B"], wordedInCloud: true),
         memoryNote("The pool opens.", from: [], wordedInCloud: true),
         disputedBy(["A", "B"]), disputedBy(["A"]), rememberThisLabel("The pool opens."), rememberedLabel("The pool opens."),
         alreadyOn,
         planTodo, readTodo, datesTodo, summaryTodo, keptQuestions, keptSources(1), keptSources(4), keptSummary,
         overview(topic: "the pool", sources: 4, backedTwice: 2, disagreements: 1, old: 1),
         overview(topic: "the pool", sources: 1, backedTwice: 1, disagreements: 2, old: 2),
         nothingFound("the pool"),
         disagreement([("Riverside Gazette", "November 3"), ("City of Riverside Parks", "November 10")],
                      newest: "City of Riverside Parks"),
         sourcesHeading, pointsHeading, morePoints(1), morePoints(2), olderLabel, gathered(Date(), now: Date()), from(["A", "B"]), sourceNumber(1),
         declinedCloud, cloudUnreadable, cloudUnavailable, cloudWithdrawn, openSourcesTitle, followUpTitle, rememberTitle,
         openSourcesHint, followUpHint, rememberHint, followUpDraft("the pool"), rememberQuestion,
         rememberDetail(.onDevice), rememberDetail(.mayLeaveDevice),
         rememberThis, remembered, pageLinkTitle, lookIntoTitle, lookIntoHint, askLine("the pool")]
            + questions(about: "the pool")
    }
}
