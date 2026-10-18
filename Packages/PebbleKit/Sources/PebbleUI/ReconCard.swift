import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// What came back from looking into something: a short summary, the key
/// points with the sources behind each, any place the sources disagree,
/// and when it was gathered.
///
/// Every point shows its source numbers, and VoiceOver reads who said it.
/// Nothing is remembered unless the person picks a point and taps Remember this.
struct ReconCard: View {
    let summary: ReconSummary
    let time: String
    let gathered: String
    /// Read from example sources, so the card says so, as a scripted task's does.
    var isSample = false
    var onOpenSources: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onRemember: () -> Void = {}
    /// Takes the card away, with the summary and everything it read.
    var onDismiss: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    /// The card keeps to the main points, so it stays easy to scroll past.
    /// Every point is in Open sources.
    static let pointsOnCard = 3

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !summary.points.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.points.prefix(Self.pointsOnCard)) { point in
                        ReconPointRow(point: point, summary: summary)
                    }
                    if summary.points.count > Self.pointsOnCard {
                        Text(ReconWords.morePoints(summary.points.count - Self.pointsOnCard))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }
                }
            }
            if !summary.sources.isEmpty {
                sourcesList
            }
            footer
            buttons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: shape)
        .overlay(shape.stroke(Theme.hairline(scheme)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recon:\(summary.id)")
    }

    var spoken: String {
        [isSample ? FeedWords.exampleTag : "", FeedWords.readyLabel, ReconWords.title(summary.topic), summary.overview, time]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(FeedWords.readyLabel)
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Theme.accent)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                if isSample {
                    // The same capsule as a scripted task's card.
                    Text(FeedWords.exampleTag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .accessibilityIdentifier("exampleTag")
                }
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(ReconWords.title(summary.topic))
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.overview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isHeader)
    }

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ReconWords.sourcesHeading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(summary.sources.enumerated()), id: \.element.id) { index, source in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SourceNumber(number: index + 1)
                    Text(Self.sourceLine(source, gatheredAt: summary.gatheredAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(ReconWords.sourceNumber(index + 1)). \(Self.sourceLine(source, gatheredAt: summary.gatheredAt))")
            }
        }
    }

    /// "Riverside Gazette, Oct 10", with a word when it is old.
    static func sourceLine(_ source: ReconSource, gatheredAt: Date) -> String {
        let date = source.published.formatted(.dateTime.month(.abbreviated).day().year())
        let line = "\(source.publisher), \(date)"
        return source.isOld(at: gatheredAt) ? "\(line). \(ReconWords.olderLabel)" : line
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gathered)
            if let note = summary.note {
                Text(note)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    enum Action: Hashable { case sources, followUp, remember, dismiss }

    /// Remember shows only when there is a point to keep. Dismiss is always
    /// last, as on every ended task card.
    var actions: [Action] {
        guard !summary.sources.isEmpty else { return [.followUp, .dismiss] }
        return summary.points.isEmpty ? [.sources, .followUp, .dismiss] : [.sources, .followUp, .remember, .dismiss]
    }

    @ViewBuilder
    private var buttons: some View {
        let row = actions
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttonViews(row) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { buttonViews(Array(row.prefix(2))) }
                HStack(spacing: 8) { buttonViews(Array(row.dropFirst(2))) }
            }
            VStack(alignment: .leading, spacing: 8) { buttonViews(row) }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func buttonViews(_ row: [Action]) -> some View {
        ForEach(row, id: \.self) { action in
            switch action {
            case .sources:
                Button(ReconWords.openSourcesTitle, action: onOpenSources)
                    .buttonStyle(CardButtonStyle(kind: .secondary))
                    .accessibilityHint(ReconWords.openSourcesHint)
            case .followUp:
                Button(ReconWords.followUpTitle, action: onFollowUp)
                    .buttonStyle(CardButtonStyle(kind: .secondary))
                    .accessibilityHint(ReconWords.followUpHint)
            case .remember:
                Button(ReconWords.rememberTitle, action: onRemember)
                    .buttonStyle(CardButtonStyle(kind: .quiet))
                    .accessibilityHint(ReconWords.rememberHint)
            case .dismiss:
                Button(TaskWords.dismissTitle, action: onDismiss)
                    .buttonStyle(CardButtonStyle(kind: .quiet))
            }
        }
    }
}

/// One point and the numbers of its sources, with a plain line under it
/// when the sources disagree.
struct ReconPointRow: View {
    let point: ReconPoint
    let summary: ReconSummary
    @Environment(\.colorScheme) private var scheme

    /// "[1][2]", as the sources list numbers them.
    var refs: String {
        point.sourceIDs.compactMap(summary.number).map { "[\($0)]" }.joined()
    }

    var spoken: String {
        let from = ReconWords.from(point.sourceIDs.compactMap(summary.source).map(\.publisher))
        return [point.text, point.disagreement?.text, from].compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                // The source numbers follow the words on the same line.
                Text("\(point.text) \(Text(refs).font(.caption.weight(.bold)).foregroundStyle(Theme.accent))")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let disagreement = point.disagreement {
                Label {
                    Text(disagreement.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Theme.accent)
                }
                .font(.footnote)
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(scheme == .dark ? 0.16 : 0.1),
                            in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
                .padding(.leading, 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// A source's number, as a small tag.
struct SourceNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent.opacity(0.14), in: Capsule())
            .accessibilityLabel(ReconWords.sourceNumber(number))
    }
}

/// Every source behind a summary: who published it, when, what it says,
/// and a link to the page.
struct ReconSourcesSheet: View {
    let summary: ReconSummary
    var isSample = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isSample {
                        SampleTag()
                    }
                    Text(ReconWords.title(summary.topic))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if !summary.points.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(ReconWords.pointsHeading)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(summary.points) { point in
                                ReconPointRow(point: point, summary: summary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(scheme)
                    }
                    Text(ReconWords.sourcesHeading)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(summary.sources.enumerated()), id: \.element.id) { index, source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                SourceNumber(number: index + 1)
                                Text(source.title)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(ReconCard.sourceLine(source, gatheredAt: summary.gatheredAt))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(source.text)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Link(destination: source.url) {
                                Label(ReconWords.pageLinkTitle, systemImage: "safari")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .tint(Theme.accent)
                            .frame(minHeight: 44)
                            .accessibilityHint(source.url.host ?? "")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(scheme)
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(.vertical, 20)
                .readableColumn(Theme.readableWidth)
            }
            .background(Backdrop())
            .navigationTitle(ReconWords.sourcesHeading)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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

/// "Which point should I remember?" Each point has its own Remember this.
/// A tap saves that one point through the memory store, and nothing else.
struct ReconRememberSheet: View {
    @ObservedObject var model: FeedModel
    let summary: ReconSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ReconWords.rememberQuestion)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(ReconWords.rememberDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(summary.points) { point in
                        let kept = model.isRemembered(point, in: summary)
                        VStack(alignment: .leading, spacing: 10) {
                            ReconPointRow(point: point, summary: summary)
                            Button {
                                model.remember(point, in: summary)
                            } label: {
                                Label(kept ? ReconWords.remembered : ReconWords.rememberThis,
                                      systemImage: kept ? "checkmark" : "bookmark")
                            }
                            .buttonStyle(CardButtonStyle(kind: kept ? .quiet : .secondary))
                            .disabled(kept)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(scheme)
                        .accessibilityElement(children: .contain)
                    }
                    if let status = model.rememberStatus {
                        GentleNotice(text: status)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 20)
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
        .onDisappear { model.clearRememberStatus() }
        .onChange(of: model.rememberStatus) { _, status in
            if let status { AccessibilityNotification.Announcement(status).post() }
        }
    }
}

/// "This is an example. Nothing here was really done."
struct SampleTag: View {
    var body: some View {
        Text(FeedWords.sampleLabel)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityIdentifier("sampleLabel")
    }
}
#endif
