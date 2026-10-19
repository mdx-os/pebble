import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The question asked before the agent sends, buys or shares anything.
///
/// This is the only place an `Approval` is made. "Yes" approves exactly what
/// is on screen, once.
/// Everything the confirmation sheet shows and does, kept apart from the
/// view so tests can drive it and read what is on screen.
@MainActor
final class ConfirmationState: ObservableObject {
    enum Screen: Equatable {
        /// Yes and Not now, with the promise underneath.
        case asking
        /// The question timed out: the timed out words and a Close button.
        case timedOut
        /// Answered; buttons are disabled while the sheet goes away.
        case answered
    }

    /// What a tap did.
    enum TapResult: Equatable { case approved, timedOut, closed, ignored }

    /// A tap aimed at Yes that lands just after it turns into Close must not
    /// dismiss the sheet before the person has read why.
    static let closeGrace: Duration = .milliseconds(800)

    @Published private(set) var screen: Screen = .asking
    /// Changes each time the person must hear something new.
    @Published private(set) var spoken: String?
    /// How long the yes is for. Just this once until the person picks another.
    @Published private(set) var choice: GrantChoice = .standard

    let request: ConfirmationRequest
    /// The choices this question offers, in order. One means there is
    /// nothing to choose, so none are shown.
    let choices: [GrantChoice]
    private let rule: AskFirst
    private let now: () -> ContinuousClock.Instant
    private let wallClock: () -> Date
    private let onApprove: (Approval) -> Void
    private let onGrant: ((Grant) -> Void)?
    private let onDecline: () -> Void
    private var timedOutAt: ContinuousClock.Instant?

    /// `onGrant` gets the grant for a yes wider than once, just before
    /// `onApprove` gets the approval. Without it, no choice is offered.
    init(
        request: ConfirmationRequest,
        rule: AskFirst,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallClock: @escaping () -> Date = { Date() },
        onApprove: @escaping (Approval) -> Void,
        onGrant: ((Grant) -> Void)? = nil,
        onDecline: @escaping () -> Void
    ) {
        self.request = request
        self.rule = rule
        self.now = now
        self.wallClock = wallClock
        self.onApprove = onApprove
        self.onGrant = onGrant
        self.onDecline = onDecline
        choices = onGrant == nil ? [.standard] : GrantChoice.offered(for: request.action.kind, task: request.task)
    }

    /// True while there is a choice to make.
    var showsChoices: Bool { choices.count > 1 && screen == .asking }

    /// Picks how long the yes is for. Only a choice this question offers,
    /// and only while it is still being asked.
    func choose(_ next: GrantChoice) {
        guard screen == .asking, choices.contains(next) else { return }
        choice = next
    }

    var footnote: String {
        guard screen != .timedOut, let handle = request.action.recipient.handle else {
            return ConfirmationSheet.footnote(expired: screen == .timedOut)
        }
        return GrantWords.promise(choice, kind: request.action.kind, handle: handle)
    }
    var primaryTitle: String { screen == .timedOut ? ConfirmationWords.closeTitle : ProposedAction.yesTitle }
    var showsNotNow: Bool { screen != .timedOut }

    /// The primary button: Yes while asking, Close after a timeout.
    @discardableResult
    func tapPrimary() -> TapResult {
        switch screen {
        case .asking: return tapYes()
        case .timedOut: return close(fromKeyboard: false)
        case .answered: return .ignored
        }
    }

    /// Escape or Not now. Works before and after a timeout.
    @discardableResult
    func cancel() -> TapResult {
        switch screen {
        case .asking:
            screen = .answered
            rule.withdraw(request)
            onDecline()
            return .closed
        case .timedOut: return close(fromKeyboard: true)
        case .answered: return .ignored
        }
    }

    /// Whether moving to `screen` earns the light tap: only on the way into
    /// answered, by Yes or Not now, never on the way out or on a timeout.
    nonisolated static func tapsOnChange(to screen: Screen) -> Bool { screen == .answered }

    /// Called every second while the sheet is open.
    func tick() {
        if screen == .asking, rule.isClosed(request) { timeOut() }
    }

    /// The sheet went away without an answer.
    func disappeared() {
        if screen != .answered { rule.withdraw(request) }
    }

    private func tapYes() -> TapResult {
        switch rule.sayYes(to: request) {
        case .approved(let approval):
            screen = .answered
            // The one place a grant is made: from this yes, for exactly
            // what it approved. Just this once is the approval itself.
            if choice != .justThisOnce, let onGrant,
               let grant = GrantIssuer().issue(choice, for: approval, now: wallClock()) {
                onGrant(grant)
            }
            onApprove(approval)
            return .approved
        case .timedOut:
            timeOut()
            return .timedOut
        }
    }

    private func close(fromKeyboard: Bool) -> TapResult {
        if !fromKeyboard, let timedOutAt, now() - timedOutAt < Self.closeGrace { return .ignored }
        screen = .answered
        rule.withdraw(request)
        onDecline()
        return .closed
    }

    private func timeOut() {
        screen = .timedOut
        timedOutAt = now()
        spoken = ConfirmationWords.expired
    }
}

/// The question asked before the agent sends, buys or shares anything.
///
/// This is the only place an `Approval` is made. "Yes" approves exactly what
/// is on screen, once, and a `Grant` is made here alone, when the person
/// picks a yes that lasts longer.
public struct ConfirmationSheet: View {
    let look: AgentLook
    /// True for a sample question, so the sheet says it is an example.
    /// Only what is shown changes; the rule asks and answers as always.
    let isExample: Bool
    @StateObject private var state: ConfirmationState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var footnoteFocused: Bool
    /// Room for the longest label, "What happens", growing with the text.
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = Self.labelColumn
    /// The label column's width at the usual text size, and the room
    /// between it and the value.
    static let labelColumn: CGFloat = 96
    static let labelSpacing: CGFloat = 12
    @State private var detent: PresentationDetent = .large

    public init(
        request: ConfirmationRequest,
        look: AgentLook = .startingPoint,
        rule: AskFirst = .shared,
        isExample: Bool = false,
        onApprove: @escaping (Approval) -> Void,
        onGrant: ((Grant) -> Void)? = nil,
        onDecline: @escaping () -> Void
    ) {
        self.look = look
        self.isExample = isExample
        _state = StateObject(wrappedValue: ConfirmationState(
            request: request, rule: rule, onApprove: onApprove, onGrant: onGrant, onDecline: onDecline
        ))
    }
    /// Over the details: what is shared when it is the person's own
    /// details, else what goes out.
    static func detailsLabel(_ kind: ConsequentialAction) -> String {
        kind == .sharePersonalInfo ? ConfirmationWords.sharedLabel : ConfirmationWords.whatLabel
    }

    /// The footnote under the details.
    static func footnote(expired: Bool) -> String {
        expired ? ConfirmationWords.expired : ConfirmationWords.promise
    }

    private var action: ProposedAction { state.request.action }

    private var symbol: String {
        switch action.kind {
        case .send: "paperplane.fill"
        case .purchase: "bag.fill"
        case .sharePersonalInfo: "person.text.rectangle.fill"
        }
    }

    /// False lays the words out at their full height, so a test can
    /// measure what a scroll view would hide.
    private var scrolls = true

    /// The same sheet, its words laid out without a scroll view.
    func unscrolled() -> ConfirmationSheet {
        var sheet = self
        sheet.scrolls = false
        return sheet
    }

    public var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    content
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                content
            }
        }
        // Opens tall, so what happens, to whom and what is shared are all
        // seen with the buttons before anything is decided.
        .presentationDetents([.medium, .large], selection: $detent)
        // On iPad a form sheet keeps a set height; let it grow to its words.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onDisappear {
            // A question that goes away unanswered can never be approved later.
            state.disappeared()
        }
        // One light tap when the person answers, yes or not now.
        // Only on the way into answered, never on the way out.
        .haptic(.answered, trigger: state.screen, when: ConfirmationState.tapsOnChange(to:))
        .onChange(of: state.spoken) { _, line in
            // Move VoiceOver to the timeout words so they are read first,
            // before the person meets the Close button. Moving focus reads
            // them, so there is no second announcement on top.
            guard line != nil else { return }
            footnoteFocused = true
        }
        .task {
            // Notice a timeout while the sheet sits open, not only on tap.
            // Stops the moment the sheet goes away.
            state.tick()
            while state.screen == .asking && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !Task.isCancelled { state.tick() }
            }
        }
    }

    private var content: some View {
        VStack(spacing: Theme.Space.l) {
            if isExample {
                ExampleLabel()
            }
            ZStack(alignment: .bottomTrailing) {
                CharacterView(look: look, size: 64)
                Image(systemName: symbol)
                    .font(Theme.TypeScale.footnote.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.card(scheme), lineWidth: 3))
                    .offset(x: -10, y: -10)
                    .accessibilityHidden(true)
            }
            VStack(spacing: Theme.Space.xs) {
                Text(ConfirmationWords.heading)
                    .font(Theme.TypeScale.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Text(action.question)
                    .font(Theme.TypeScale.displayTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                ForEach(Array(Self.rows(action).enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(Theme.hairline(scheme)) }
                    self.row(row.label, row.value)
                }
            }
            .cardSurface()
            if state.showsChoices {
                choicePicker
            }
            Text(state.footnote)
                .font(Theme.TypeScale.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .accessibilityFocused($footnoteFocused)
            VStack(spacing: Theme.Space.xs) {
                Button(state.primaryTitle) { state.tapPrimary() }
                    .buttonStyle(PrimaryButtonStyle())
                if state.showsNotNow {
                    Button(ProposedAction.noTitle) { state.cancel() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            .disabled(state.screen == .answered)
            .background {
                // Escape always closes, before and after a timeout.
                Button("") { state.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.gutter)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    /// How long the yes is for, one row per choice, Just this once chosen
    /// until the person picks another.
    private var choicePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(GrantWords.choiceHeading)
                .font(Theme.TypeScale.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(state.choices.enumerated()), id: \.element) { index, choice in
                    if index > 0 { Divider().overlay(Theme.hairline(scheme)) }
                    choiceRow(choice)
                }
            }
            .cardSurface()
        }
    }

    private func choiceRow(_ choice: GrantChoice) -> some View {
        let chosen = state.choice == choice
        return Button { state.choose(choice) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(Theme.TypeScale.title3)
                    .foregroundStyle(chosen ? AnyShapeStyle(Theme.accentSymbol) : AnyShapeStyle(Theme.secondaryText))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(choice.title(for: action.recipient))
                        .font(Theme.TypeScale.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(GrantWords.choiceDetail(choice))
                        .font(Theme.TypeScale.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityIdentifier("grantChoice." + choice.rawValue)
    }

    /// The sheet's rows, each a label and its value: who, where, what goes
    /// or is shared, the price, and what a yes will do, so nothing about it
    /// is left to guess.
    static func rows(_ action: ProposedAction) -> [(label: String, value: String)] {
        var out: [(String, String)] = [(action.kind == .purchase ? ConfirmationWords.fromLabel : ConfirmationWords.toLabel,
                                        action.recipient.displayName)]
        if let handle = action.recipient.handle { out.append((ConfirmationWords.whereLabel, handle)) }
        out.append((detailsLabel(action.kind), action.details))
        if let price = action.price { out.append((ConfirmationWords.priceLabel, price.formatted())) }
        if let outcome = action.outcome { out.append((ConfirmationWords.happensLabel, outcome)) }
        return out
    }

    /// What VoiceOver reads for each row: its label and value, put together
    /// as `.combine` puts them.
    static func spokenRows(_ action: ProposedAction) -> [String] {
        rows(action).map { "\($0.label), \($0.value)" }
    }

    /// At accessibility text sizes a label column would squeeze the value,
    /// the part being said yes to, so the label sits over it instead.
    static func stacksLabels(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledRow(stacked: Self.stacksLabels(at: typeSize), labelWidth: labelWidth, spacing: Self.labelSpacing) {
            Text(label)
                .font(Theme.TypeScale.subheadline)
                .foregroundStyle(Theme.secondaryText)
        } value: {
            Text(value)
                .font(Theme.TypeScale.body.weight(.medium))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
        .accessibilityElement(children: .combine)
    }

}
#endif
