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

    let request: ConfirmationRequest
    private let rule: AskFirst
    private let now: () -> ContinuousClock.Instant
    private let onApprove: (Approval) -> Void
    private let onDecline: () -> Void
    private var timedOutAt: ContinuousClock.Instant?

    init(
        request: ConfirmationRequest,
        rule: AskFirst,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        onApprove: @escaping (Approval) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.request = request
        self.rule = rule
        self.now = now
        self.onApprove = onApprove
        self.onDecline = onDecline
    }

    var footnote: String { ConfirmationSheet.footnote(expired: screen == .timedOut) }
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
/// is on screen, once.
public struct ConfirmationSheet: View {
    let look: AgentLook
    /// True for a sample question, so the sheet says it is an example.
    /// Only what is shown changes; the rule asks and answers as always.
    let isExample: Bool
    @StateObject private var state: ConfirmationState
    @Environment(\.colorScheme) private var scheme
    @AccessibilityFocusState private var footnoteFocused: Bool
    /// Room for the longest label, "What happens", growing with the text.
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 96
    @State private var detent: PresentationDetent = .large

    public init(
        request: ConfirmationRequest,
        look: AgentLook = .startingPoint,
        rule: AskFirst = .shared,
        isExample: Bool = false,
        onApprove: @escaping (Approval) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.look = look
        self.isExample = isExample
        _state = StateObject(wrappedValue: ConfirmationState(
            request: request, rule: rule, onApprove: onApprove, onDecline: onDecline
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

    public var body: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
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
        VStack(spacing: 20) {
            if isExample {
                ExampleLabel()
            }
            ZStack(alignment: .bottomTrailing) {
                CharacterView(look: look, size: 64)
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.card(scheme), lineWidth: 3))
                    .offset(x: -10, y: -10)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(ConfirmationWords.heading)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Text(action.question)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                row(action.kind == .purchase ? ConfirmationWords.fromLabel : ConfirmationWords.toLabel, action.recipient.displayName)
                if let handle = action.recipient.handle {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.whereLabel, handle)
                }
                Divider().overlay(Theme.hairline(scheme))
                row(Self.detailsLabel(action.kind), action.details)
                if let price = action.price {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.priceLabel, price.formatted())
                }
                // What a yes will do, so nothing about it is left to guess.
                if let outcome = action.outcome {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.happensLabel, outcome)
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            Text(state.footnote)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .accessibilityFocused($footnoteFocused)
            VStack(spacing: 6) {
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

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

}
#endif
