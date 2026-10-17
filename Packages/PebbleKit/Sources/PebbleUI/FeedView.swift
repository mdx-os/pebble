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
        feed = Feed.build(from: [needsYou] + sources, now: now(), calendar: calendar)
    }

    var isSample: Bool { sources.contains { $0.isSample } }
    var rule: AskFirst { needsYou.rule }

    /// Builds the feed again. Questions that timed out drop away here.
    func refresh() {
        let next = Feed.build(from: [needsYou] + sources, now: now(), calendar: calendar)
        if next != feed { feed = next }
    }

    /// What a card's button does. Talking is handed to the screen around
    /// the feed, which owns the chat.
    func perform(_ item: FeedItem, talk: (String) -> Void) {
        switch item.action {
        case .review(let request): reviewing = request
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

    /// "8:52 AM" today, "Yesterday", then the day of the week, then the date.
    func timeLabel(for time: Date) -> String {
        let today = now()
        if calendar.isDate(time, inSameDayAs: today) || time > today {
            return time.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(time, inSameDayAs: yesterday) {
            return FeedWords.yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: today)), time >= weekAgo {
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
    /// Two cards side by side once each can be at least this wide. Grows
    /// with the text size, so large text gets one roomy column.
    @ScaledMetric(relativeTo: .body) private var cardMinimum: CGFloat = 320
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = Theme.feedWidth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(model.dateLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, -12)
                if model.feed.isEmpty {
                    empty
                        .transition(.opacity)
                }
                if model.feed.showsNeedsYou {
                    section(FeedWords.needsYouHeading, detail: FeedWords.needsYouDetail, items: model.feed.needsYou)
                        .accessibilityIdentifier("needsYou")
                        .transition(Motion.arrival(reduceMotion: reduceMotion))
                }
                ForEach(model.feed.groups) { group in
                    section(group.title, detail: nil, items: group.items)
                }
                if model.isSample && !model.feed.isEmpty {
                    Text(FeedWords.sampleNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableColumn(columnWidth)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.9),
                       value: model.feed)
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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMinimum), spacing: 14, alignment: .top)]
    }

    private func section(_ title: String, detail: String?, items: [FeedItem]) -> some View {
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
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
            .accessibilityHint(action.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: action.title, perform)
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
                    .foregroundStyle(asks ? Color.white : Theme.accent)
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
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        if case .open(let text) = item.action { return text }
        return item.body
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
