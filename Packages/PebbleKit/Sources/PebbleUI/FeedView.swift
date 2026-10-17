import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// Everything the Today screen shows and does, kept apart from the view so
/// tests can drive it.
///
/// Questions are answered only through `ConfirmationSheet`, with the rule
/// that asked them. Nothing here can approve anything.
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var feed: Feed
    /// The question open in the confirmation sheet.
    @Published var reviewing: ConfirmationRequest?
    /// The result open to read.
    @Published var reading: FeedItem?
    /// A summary whose sources are open to read.
    @Published var readingSources: ReconSummary?
    /// A summary whose points are open to choose one to remember.
    @Published var choosingPoint: ReconSummary?
    /// Points kept in memory from this screen, by `rememberKey`.
    @Published private(set) var remembered: Set<String> = []
    /// What happened to the last Remember tap, such as "Saved. It stays on this device."
    @Published private(set) var rememberStatus: String?

    let needsYou: NeedsYou
    /// Runs "look into this" as tasks. The same object as `tasks` when set.
    let recon: ReconRunner?
    /// Where a point goes when the person taps Remember. Nothing is saved any other way.
    private let memory: MemoryStore?
    /// Chooses how the next summary is put together: on this device, or
    /// through the cloud's preview when the person turned the cloud on.
    var summarizer: @MainActor () -> any ReconSummarizer = { LocalReconSummarizer() }
    /// Long work shown on live task cards. Nil when nothing is running. Its
    /// questions reach the feed only when it asks through the rule of
    /// `needsYou`.
    let tasks: (any TaskEngine)?
    /// Moves a scripted engine's clock with real time, for the live showcase.
    let drivesTasks: Bool
    private let sources: [any FeedSource]
    private let calendar: Calendar
    let now: () -> Date
    private var watching: TaskObservation?
    private var announcer = TaskAnnouncer()
    private let clock: () -> ContinuousClock.Instant
    /// Says a line to VoiceOver. Tests replace it to hear what would be said.
    var announce: @MainActor (TaskAnnouncer.Line) -> Void = FeedModel.post

    init(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)? = nil,
         drivesTasks: Bool = false, memory: MemoryStore? = nil, calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() },
         clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.sources = sources
        self.needsYou = needsYou
        self.tasks = tasks
        self.recon = tasks as? ReconRunner
        self.memory = memory
        self.drivesTasks = drivesTasks
        self.calendar = calendar
        self.now = now
        self.clock = clock
        feed = Feed.build(from: sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        _ = announcer.lines(for: tasks?.tasks ?? [], at: clock())
        watching = tasks?.observe { [weak self] list in
            // Engines tell us on whatever thread they run. Hop to the main
            // one, without a wait when already there.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.tasksChanged(list) }
            } else {
                Task { @MainActor in self?.tasksChanged(list) }
            }
        }
    }

    var isSample: Bool { sources.contains { $0.isSample } || tasks?.isSample == true }

    /// True when this card came from an example source or a scripted engine.
    func isSample(_ item: FeedItem) -> Bool {
        if let tasks, tasks.isSample, tasks.tasks.contains(where: { $0.id == item.id }) { return true }
        return sources.contains { $0.isSample && $0.items(now: now()).contains { $0.id == item.id } }
    }

    /// The rule for every question in the sheet, a task's included.
    var rule: AskFirst { needsYou.rule }

    /// Builds the feed again. Questions that timed out drop away here.
    func refresh() {
        tasks?.refresh()
        rebuild()
    }

    private func rebuild() {
        let next = Feed.build(from: sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        if next != feed { feed = next }
    }

    /// Moves a scripted engine along, for the live showcase and for recons
    /// played on the scripted engine.
    func tick(_ seconds: TimeInterval) {
        if let recon {
            recon.advance(by: seconds)
        } else {
            (tasks as? LocalFakeEngine)?.advance(by: seconds)
        }
    }

    private func tasksChanged(_ list: [AgentTask]) {
        rebuild()
        for line in announcer.lines(for: list, at: clock()) { announce(line) }
    }

    /// What a card's button does. Talking is handed to the screen around
    /// the feed, which owns the chat. Only a question pinned by `NeedsYou`
    /// opens the question sheet.
    func perform(_ item: FeedItem, talk: (String) -> Void) {
        switch item.action {
        case .review(let request):
            if feed.needsYou.contains(where: { $0.request?.id == request.id }) { reviewing = request }
        case .open: reading = item
        case .talk(let line): talk(line)
        case .task(let task):
            if task.question != nil { review(task) } else { open(task) }
        case .lookInto(let topic):
            // Without a runner, the chat offers it instead, still one tap away.
            if recon == nil || !lookInto(topic) { talk(ReconWords.askLine(topic)) }
        case nil: break
        }
    }

    // MARK: Looking into something

    /// Starts looking into `topic`, after the person's tap. False when
    /// nothing started, as for words of crisis.
    @discardableResult
    func lookInto(_ topic: String) -> Bool {
        guard let recon, recon.lookInto(topic, with: summarizer()) != nil else { return false }
        refresh()
        return true
    }

    /// The summary a finished recon card shows.
    func summary(for task: AgentTask) -> ReconSummary? {
        recon?.summary(for: task.id)
    }

    /// A recon reads for one topic, so its card offers Stop but not Change course.
    func canRedirect(_ task: AgentTask) -> Bool {
        recon?.isRecon(task.id) != true
    }

    /// Opens the chat with a follow-up ready. Nothing is sent until the person sends it.
    func followUp(_ summary: ReconSummary, talk: (String) -> Void) {
        talk(ReconWords.followUpDraft(summary.topic))
    }

    static func rememberKey(_ summary: ReconSummary, _ point: ReconPoint) -> String {
        "\(summary.id)/\(point.id)"
    }

    func isRemembered(_ point: ReconPoint, in summary: ReconSummary) -> Bool {
        remembered.contains(Self.rememberKey(summary, point))
    }

    /// Keeps one point in memory, with where it came from, through the same
    /// store the memory screen uses. Only a tap on Remember this calls it.
    @discardableResult
    func remember(_ point: ReconPoint, in summary: ReconSummary) -> Bool {
        guard summary.points.contains(point), !isRemembered(point, in: summary) else { return false }
        guard let memory else {
            rememberStatus = MemoryWords.couldNotOpen
            return false
        }
        let publisher = point.sourceIDs.first.flatMap(summary.source)?.publisher ?? ""
        do {
            switch try memory.remember(summary.note(for: point), source: .lookedUp(publisher)) {
            case .saved:
                remembered.insert(Self.rememberKey(summary, point))
                rememberStatus = MemoryWords.saved
                return true
            case .tooLong:
                rememberStatus = MemoryWords.tooLong
            case .needsWords, .notFound:
                rememberStatus = MemoryWords.needsWords
            }
        } catch is MemoryStore.Unavailable {
            rememberStatus = MemoryWords.unavailable
        } catch is MemoryStore.Unreadable {
            rememberStatus = MemoryWords.unreadable
        } catch {
            rememberStatus = MemoryWords.couldNotOpen
        }
        return false
    }

    func clearRememberStatus() {
        rememberStatus = nil
    }

    // MARK: Task cards

    /// Approve opens the same question sheet as any other question, with the
    /// rule of `needsYou`. Only the engine's own task, with its question
    /// pinned in Needs you, opens it. Only a yes there, checked by
    /// `AskFirst`, lets the task go on.
    func review(_ task: AgentTask) {
        guard let question = current(task)?.question,
              feed.needsYou.contains(where: { $0.task?.question?.id == question.id }) else { return }
        reviewing = question
    }

    /// New instructions. Never needs a yes. Any open question is withdrawn.
    @discardableResult
    func redirect(_ task: AgentTask, with words: String) -> Bool {
        let done = tasks?.redirect(task.id, with: words) ?? false
        if let reviewing, reviewing.id == task.question?.id { self.reviewing = nil }
        refresh()
        return done
    }

    /// Stops at once. Never needs a yes.
    func stop(_ task: AgentTask) {
        tasks?.stop(task.id)
        if let reviewing, reviewing.id == task.question?.id { self.reviewing = nil }
        refresh()
    }

    func retry(_ task: AgentTask) {
        tasks?.retry(task.id)
        refresh()
    }

    /// The finished result, in the same reader as other results.
    func open(_ task: AgentTask) {
        guard let result = task.result else { return }
        reading = FeedItem(id: task.id, kind: .ready, time: task.updatedAt, title: task.title,
                           body: task.step, action: .open(result))
    }

    private func current(_ task: AgentTask) -> AgentTask? {
        tasks?.tasks.first { $0.id == task.id }
    }

    /// The sheet said yes. The card goes and the approval is handed on:
    /// to the task that asked, which checks it with `AskFirst`, or to
    /// `NeedsYou`.
    func approved(_ approval: Approval) {
        if let task = tasks?.tasks.first(where: { $0.question?.id == approval.id }) {
            _ = tasks?.resume(task.id, with: approval)
        } else {
            needsYou.approved(approval)
        }
        reviewing = nil
        refresh()
    }

    /// The sheet closed without a yes, by Not now, Close, or going away.
    /// The sheet has already withdrawn the question.
    func closedQuestion(_ request: ConfirmationRequest) {
        needsYou.dismissed(request)
        tasks?.questionClosed(request)
        if reviewing?.id == request.id { reviewing = nil }
        refresh()
    }

    /// Posts a line to VoiceOver: politely for a new step, so it waits its
    /// turn, and at the usual priority when the person is needed or a task ends.
    static func post(_ line: TaskAnnouncer.Line) {
        var text = AttributedString(line.text)
        text.accessibilitySpeechAnnouncementPriority = line.urgent ? .default : .low
        AccessibilityNotification.Announcement(text).post()
    }

    /// "8:52 AM" today, "Yesterday", then the day of the week in the past
    /// week, then the date. Any day but today says which day.
    func timeLabel(for time: Date) -> String {
        let today = now()
        if calendar.isDate(time, inSameDayAs: today) {
            return time.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(time, inSameDayAs: yesterday) {
            return FeedWords.yesterday
        }
        if time < today, let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: today)),
           time >= weekAgo {
            return time.formatted(.dateTime.weekday(.wide))
        }
        return time.formatted(.dateTime.month(.abbreviated).day())
    }

    var dateLine: String {
        now().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// The home screen after the first run: a calm feed of what the agent did,
/// made and noticed, with anything that needs a yes pinned on top.
struct FeedView: View {
    @ObservedObject var model: FeedModel
    let look: AgentLook
    let onTalk: (String) -> Void
    let onChat: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Two cards side by side once each can be at least this wide. Grows
    /// with the text size, so large text gets one roomy column.
    @ScaledMetric(relativeTo: .body) private var cardMinimum: CGFloat = 320
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = Theme.feedWidth

    static let cardSpacing: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.dateLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        // Said first, so no example is ever taken for real work.
                        if model.isSample && !model.feed.isEmpty {
                            Text(FeedWords.sampleNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("sampleNote")
                        }
                    }
                    .padding(.bottom, -12)
                    if model.feed.isEmpty {
                        empty
                            .transition(.opacity)
                    }
                    let columns = Self.columns(
                        for: Self.contentWidth(in: proxy.size.width, column: columnWidth),
                        minimum: cardMinimum, accessibilityText: typeSize.isAccessibilitySize)
                    if model.feed.showsNeedsYou {
                        section(FeedWords.needsYouHeading, detail: FeedWords.needsYouDetail,
                                items: model.feed.needsYou, columns: columns)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("needsYou")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if model.feed.showsWorking {
                        section(TaskWords.workingHeading, detail: TaskWords.workingDetail,
                                items: model.feed.working, columns: columns)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("working")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    ForEach(model.feed.groups) { group in
                        section(group.title, detail: nil, items: group.items, columns: columns)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableColumn(columnWidth)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.9),
                           value: model.feed)
            }
        }
        .background(Backdrop())
        .navigationTitle(FeedWords.title)
        .task {
            // Questions time out on their own, so look again now and then.
            // Stops when the screen goes away.
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    /// The room the cards have: the window's width, held to the reading
    /// column, less the gutters `readableColumn` adds.
    static func contentWidth(in width: CGFloat, column: CGFloat) -> CGFloat {
        max(0, min(width, column) - 2 * Theme.gutter)
    }

    /// How many cards fit side by side, each at least `minimum` wide. One
    /// plain column at accessibility text sizes or when even one card at
    /// `minimum` would not fit, and never more than two.
    static func columnCount(for width: CGFloat, minimum: CGFloat, accessibilityText: Bool) -> Int {
        guard !accessibilityText, minimum > 0 else { return 1 }
        let fit = Int((width + cardSpacing) / (minimum + cardSpacing))
        return min(2, max(1, fit))
    }

    /// Flexible columns share whatever width there is, so a card is never
    /// wider than the screen, whatever the text size.
    static func columns(for width: CGFloat, minimum: CGFloat, accessibilityText: Bool) -> [GridItem] {
        let count = columnCount(for: width, minimum: minimum, accessibilityText: accessibilityText)
        return Array(repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top), count: count)
    }

    private func section(_ title: String, detail: String?, items: [FeedItem], columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(items) { item in
                    Group {
                        if let task = item.task, let summary = model.summary(for: task) {
                            ReconCard(summary: summary, time: model.timeLabel(for: item.time),
                                      gathered: ReconWords.gathered(summary.gatheredAt, now: model.now()),
                                      onOpenSources: { model.readingSources = summary },
                                      onFollowUp: { model.followUp(summary, talk: onTalk) },
                                      onRemember: { model.choosingPoint = summary })
                        } else if let task = item.task {
                            TaskCard(task: task, time: model.timeLabel(for: item.time),
                                     canRedirect: model.canRedirect(task),
                                     onApprove: { model.review(task) },
                                     onRedirect: { model.redirect(task, with: $0) },
                                     onStop: { model.stop(task) },
                                     onRetry: { model.retry(task) },
                                     onOpen: { model.open(task) })
                        } else {
                            FeedCard(item: item, time: model.timeLabel(for: item.time)) {
                                model.perform(item, talk: onTalk)
                            }
                        }
                    }
                    .transition(Motion.arrival(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            CharacterView(look: look, size: 72)
            Text(FeedWords.emptyTitle)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(FeedWords.empty)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.readableWidth)
            Button(FeedWords.emptyActionTitle, action: onChat)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .padding(.top, 4)
                .pointerHover(in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .contain)
    }
}

/// One card. A card with something to do is one button: VoiceOver reads the
/// kind, the title, the body and the time as one thought, then what the
/// button does.
struct FeedCard: View {
    let item: FeedItem
    let time: String
    let perform: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let action = item.action {
            Button(action: perform) {
                content(actionTitle: action.title)
            }
            .buttonStyle(SoftPressStyle())
            .pointerHover(in: shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint(action.hint)
            // Voice Control users can say the words they see on the card.
            .accessibilityInputLabels([Text(action.title), Text(item.title)])
            .accessibilityAddTraits(.isButton)
        } else {
            content(actionTitle: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    private var asks: Bool { item.kind == .needsYou }

    var spoken: String {
        [item.spokenKind, item.title, item.body, time].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func content(actionTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(item.spokenKind)
                } icon: {
                    Image(systemName: Self.symbol(item.kind))
                        .foregroundStyle(Theme.accent)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(asks ? Theme.onAccent : Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(asks ? Theme.accent : Theme.accent.opacity(0.14), in: Capsule())
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: shape)
        .overlay(shape.stroke(asks ? Theme.accent.opacity(0.55) : Theme.hairline(scheme), lineWidth: asks ? 1.5 : 1))
        .contentShape(shape)
    }

    static func symbol(_ kind: FeedItem.Kind) -> String {
        switch kind {
        case .did: "checkmark.circle.fill"
        case .ready: "doc.text.fill"
        case .noticed: "lightbulb.fill"
        case .needsYou: "hand.raised.fill"
        case .task: "circle.fill"
        }
    }
}

/// A finished result, opened from its card.
struct FeedReader: View {
    let item: FeedItem
    let time: String
    /// True when the card was an example, so the reader says so too.
    var isSample = false
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        if case .open(let text) = item.action { return text }
        return item.body
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isSample {
                        Text(FeedWords.sampleLabel)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .accessibilityIdentifier("sampleLabel")
                    }
                    Label(item.spokenKind, systemImage: FeedCard.symbol(item.kind))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableColumn(Theme.readableWidth)
            }
            .background(Backdrop())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FeedWords.doneTitle) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
