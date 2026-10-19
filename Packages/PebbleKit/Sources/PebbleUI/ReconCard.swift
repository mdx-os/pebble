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
    /// False when its points can't go in the notes, as for an example, so
    /// the card offers no Remember. See `ReconRunner.keepsPoints`.
    var canRemember = true
    var onOpenSources: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onRemember: () -> Void = {}
    /// Takes the card away, with the summary and everything it read.
    var onDismiss: () -> Void = {}

    /// The card keeps to the main points, so it stays easy to scroll past.
    /// Every point is in Open sources.
    static let pointsOnCard = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if !summary.points.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(summary.points.prefix(Self.pointsOnCard)) { point in
                        ReconPointRow(point: point, summary: summary)
                    }
                    if summary.points.count > Self.pointsOnCard {
                        Text(ReconWords.morePoints(summary.points.count - Self.pointsOnCard))
                            .font(Theme.TypeScale.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, Theme.Space.m)
                    }
                }
            }
            if !summary.sources.isEmpty {
                sourcesList
            }
            footer
            buttons
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recon:\(summary.id)")
    }

    /// What VoiceOver reads for the line above the title: example or not,
    /// that it's ready, and when.
    var spoken: String {
        [isSample ? FeedWords.exampleMarker : "", FeedWords.readyLabel, time]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Only the title is a heading. The overview under it is read as body text.
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.xs) {
                KindBadge(text: FeedWords.readyLabel) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Theme.accentSymbol)
                }
                if isSample {
                    // The same capsule as a scripted task's card.
                    Text(FeedWords.exampleMarker)
                        .font(Theme.TypeScale.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, Theme.Space.xs)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
                        .accessibilityIdentifier("exampleTag")
                }
                Spacer(minLength: Theme.Space.xs)
                Text(time)
                    .font(Theme.TypeScale.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Text(ReconWords.title(summary.topic))
                .font(Theme.TypeScale.displayHeadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            // Never a blank line under the title for VoiceOver to land on.
            if let overview = shownOverview {
                Text(overview)
                    .font(Theme.TypeScale.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The overview under the title, or nil when there are no words in it.
    var shownOverview: String? {
        summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary.overview
    }

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(ReconWords.sourcesHeading)
                .font(Theme.TypeScale.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(summary.sources.enumerated()), id: \.element.id) { index, source in
                SourceChip(number: index + 1, source: source,
                           line: Self.sourceLine(source, gatheredAt: summary.gatheredAt))
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

    /// What VoiceOver reads for the footer: when it was gathered, then how
    /// it was made, such as worded in the cloud, not sent, or withdrawn. A
    /// full stop between them, so VoiceOver pauses.
    var footerSpoken: String {
        [gathered, summary.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ProofChip(text: gathered, symbol: "clock")
            if let note = summary.note {
                Text(note)
                    .font(Theme.TypeScale.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(footerSpoken)
    }

    enum Action: Hashable { case sources, followUp, remember, dismiss }

    /// Remember shows only when there is a point to keep, and never on an
    /// example: made up news must never reach the notes as if it were real.
    /// Dismiss is always last, as on every ended task card.
    var actions: [Action] {
        guard !summary.sources.isEmpty else { return [.followUp, .dismiss] }
        let keeps = !summary.points.isEmpty && canRemember && !isSample && !summary.isSample
        return keeps ? [.sources, .followUp, .remember, .dismiss] : [.sources, .followUp, .dismiss]
    }

    @ViewBuilder
    private var buttons: some View {
        let row = actions
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xs) { buttonViews(row) }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) { buttonViews(Array(row.prefix(2))) }
                HStack(spacing: Theme.Space.xs) { buttonViews(Array(row.dropFirst(2))) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) { buttonViews(row) }
        }
        .padding(.top, 2)
    }

    /// The words on each action's button. Lines that send the person to
    /// one, such as `ReconWords.pointTooLong`, name it by these.
    static func title(_ action: Action) -> String {
        switch action {
        case .sources: ReconWords.openSourcesTitle
        case .followUp: ReconWords.followUpTitle
        case .remember: ReconWords.rememberTitle
        case .dismiss: TaskWords.dismissTitle
        }
    }

    @ViewBuilder
    private func buttonViews(_ row: [Action]) -> some View {
        ForEach(row, id: \.self) { action in
            switch action {
            case .sources:
                Button(Self.title(action), action: onOpenSources)
                    .buttonStyle(CardButtonStyle(kind: .secondary))
                    .accessibilityHint(ReconWords.openSourcesHint)
            case .followUp:
                Button(Self.title(action), action: onFollowUp)
                    .buttonStyle(CardButtonStyle(kind: .secondary))
                    .accessibilityHint(ReconWords.followUpHint)
            case .remember:
                Button(Self.title(action), action: onRemember)
                    .buttonStyle(CardButtonStyle(kind: .quiet))
                    .accessibilityHint(ReconWords.rememberHint)
            case .dismiss:
                Button(Self.title(action), action: onDismiss)
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

    /// "More than a year old" when every page behind the point is.
    var oldLabel: String? {
        summary.restsOnOldPages(point) ? ReconWords.olderLabel : nil
    }

    /// A disagreement no point could carry is a point of its own, with the
    /// same words. Those words then show once, in the disagreement's box.
    var standsAlone: Bool {
        point.disagreement?.text == point.text
    }

    /// The point's own line, above any disagreement. None when it stands alone.
    var pointLine: String? {
        standsAlone ? nil : point.text
    }

    var spoken: String {
        let from = ReconWords.from(point.sourceIDs.compactMap(summary.source).map(\.publisher))
        return [pointLine, point.disagreement?.text, from, oldLabel.map { "\($0)." }]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// The source numbers, after the words on the same line.
    private func withRefs(_ words: String) -> Text {
        Text("\(words) \(Text(refs).font(Theme.TypeScale.caption.weight(.bold)).foregroundStyle(Theme.accentText))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let pointLine {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    withRefs(pointLine)
                        .font(Theme.TypeScale.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let oldLabel {
                Label(oldLabel, systemImage: "clock.arrow.circlepath")
                    .font(Theme.TypeScale.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, Theme.Space.m)
            }
            if let disagreement = point.disagreement {
                Label {
                    (standsAlone ? withRefs(disagreement.text) : Text(disagreement.text))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Theme.accentSymbol)
                }
                .font(Theme.TypeScale.footnote)
                .foregroundStyle(.primary)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The accent wash `Theme.textPairs` checks the words against.
                .background(Theme.accent.opacity(Theme.accentWash),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .padding(.leading, Theme.Space.m)
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
            .font(Theme.TypeScale.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 2)
            .background(Theme.accent.opacity(Theme.accentWash), in: Capsule())
            .accessibilityLabel(ReconWords.sourceNumber(number))
    }
}

/// Every source behind a summary: who published it, when, what it says,
/// and a link to the page.
struct ReconSourcesSheet: View {
    let summary: ReconSummary
    var isSample = false
    @Environment(\.dismiss) private var dismiss

    /// Under the points: how they were made. Here above all, beside each
    /// source's own text, a retelling from the cloud must never read as a quote.
    var pointsNote: String? { summary.points.isEmpty ? nil : summary.note }

    /// Every point, each in its own whole words, with none held back as
    /// the card holds some. "Open sources has it in full" rests on this.
    var points: [ReconPointRow] {
        summary.points.map { ReconPointRow(point: $0, summary: summary) }
    }

    /// The page a source's Open the page goes to: only an https one, and
    /// never for an example, whose made up pages have nowhere real to go.
    func link(for source: ReconSource) -> URL? {
        isSample || summary.isSample || source.isSample ? nil : source.link
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if isSample {
                        SampleTag()
                    }
                    Text(ReconWords.title(summary.topic))
                        .font(Theme.TypeScale.displayTitle)
                        .accessibilityAddTraits(.isHeader)
                    if !summary.points.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(ReconWords.pointsHeading)
                                .font(Theme.TypeScale.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(points, id: \.point.id) { row in
                                row
                            }
                            if let pointsNote {
                                Text(pointsNote)
                                    .font(Theme.TypeScale.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("pointsNote")
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    }
                    Text(ReconWords.sourcesHeading)
                        .font(Theme.TypeScale.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(summary.sources.enumerated()), id: \.element.id) { index, source in
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                                SourceNumber(number: index + 1)
                                Text(source.title)
                                    .font(Theme.TypeScale.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(ReconCard.sourceLine(source, gatheredAt: summary.gatheredAt))
                                .font(Theme.TypeScale.footnote)
                                .foregroundStyle(Theme.secondaryText)
                            Text(source.text)
                                .font(Theme.TypeScale.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            // Only an https page opens. Any other kind of
                            // address a provider gives is never followed,
                            // and an example's page isn't either.
                            if let link = link(for: source) {
                                Link(destination: link) {
                                    Label(ReconWords.pageLinkTitle, systemImage: "safari")
                                        .font(Theme.TypeScale.subheadline.weight(.semibold))
                                }
                                .tint(Theme.accentText)
                                .frame(minHeight: 44)
                                .accessibilityHint(ReconWords.pageLinkHint(link.host))
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(.vertical, Theme.Space.l)
                .readableColumn(Theme.readableWidth)
            }
            .background(Backdrop())
            .navigationTitle(ReconWords.sourcesHeading)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton(title: FeedWords.doneTitle) { dismiss() }
                }
                .sharedBackgroundVisibility(.hidden)
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

    static let title = ReconWords.rememberTitle

    /// What VoiceOver says for a point's button: the point's own words with
    /// it, so a button heard alone says which point it keeps.
    static func buttonLabel(_ point: ReconPoint, kept: Bool) -> String {
        kept ? ReconWords.rememberedLabel(point.text) : ReconWords.rememberThisLabel(point.text)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(ReconWords.rememberQuestion)
                            .font(Theme.TypeScale.displayTitle)
                            .accessibilityAddTraits(.isHeader)
                        Text(ReconWords.rememberDetail(model.place))
                            .font(Theme.TypeScale.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(summary.points) { point in
                        let kept = model.isRemembered(point, in: summary)
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            ReconPointRow(point: point, summary: summary)
                            Button {
                                model.remember(point, in: summary)
                            } label: {
                                Label(kept ? ReconWords.remembered : ReconWords.rememberThis,
                                      systemImage: kept ? "checkmark" : "bookmark")
                            }
                            .buttonStyle(CardButtonStyle(kind: kept ? .quiet : .secondary))
                            .disabled(kept)
                            .accessibilityLabel(Self.buttonLabel(point, kept: kept))
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                        .accessibilityElement(children: .contain)
                    }
                    if let status = model.rememberStatus {
                        GentleNotice(text: status)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, Theme.Space.l)
                .readableColumn(Theme.readableWidth)
            }
            .background(Backdrop())
            // So VoiceOver lands on a sheet with a name.
            .navigationTitle(Self.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton(title: FeedWords.doneTitle) { dismiss() }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .presentationDragIndicator(.visible)
        .onDisappear { model.clearRememberStatus() }
        // On each tap's answer, so a second "Saved" in a row is said too.
        .onChange(of: model.rememberTold) {
            if let status = model.rememberStatus { AccessibilityNotification.Announcement(status).post() }
        }
    }
}

/// "This is an example. Nothing here was really done."
struct SampleTag: View {
    var body: some View {
        Text(FeedWords.sampleLabel)
            .font(Theme.TypeScale.footnote.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
            .accessibilityIdentifier("sampleLabel")
    }
}
#endif
