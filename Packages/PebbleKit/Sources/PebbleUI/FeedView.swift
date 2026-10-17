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

    let needsYou: NeedsYou
    private let sources: [any FeedSource]
    private let calendar: Calendar
    let now: () -> Date

    init(sources: [any FeedSource], needsYou: NeedsYou, calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() }) {
        self.sources = sources
        self.needsYou = needsYou
        self.calendar = calendar
        self.now = now
        feed = Feed.build(from: sources, needsYou: needsYou, now: now(), calendar: calendar)
    }

    var isSample: Bool { sources.contains { $0.isSample } }

    /// True when this card came from an example source.
    func isSample(_ item: FeedItem) -> Bool {
        sources.contains { $0.isSample && $0.items(now: now()).contains { $0.id == item.id } }
    }
    var rule: AskFirst { needsYou.rule }

    /// Builds the feed again. Questions that timed out drop away here.
    func refresh() {
        let next = Feed.build(from: sources, needsYou: needsYou, now: now(), calendar: calendar)
        if next != feed { feed = next }
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
        case nil: break
        }
    }

    /// The sheet said yes. The card goes and the approval is handed on.
    func approved(_ approval: Approval) {
        needsYou.approved(approval)
        reviewing = nil
        refresh()
    }

    /// The sheet closed without a yes, by Not now, Close, or going away.
    /// The sheet has already withdrawn the question.
    func closedQuestion(_ request: ConfirmationRequest) {
        needsYou.dismissed(request)
        if reviewing?.id == request.id { reviewing = nil }
        refresh()
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
                    FeedCard(item: item, time: model.timeLabel(for: item.time)) {
                        model.perform(item, talk: onTalk)
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
