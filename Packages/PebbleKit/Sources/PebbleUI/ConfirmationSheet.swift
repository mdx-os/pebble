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
    @StateObject private var state: ConfirmationState
    @Environment(\.colorScheme) private var scheme
    @AccessibilityFocusState private var footnoteFocused: Bool

    public init(
        request: ConfirmationRequest,
        look: AgentLook = .startingPoint,
        rule: AskFirst = .shared,
        onApprove: @escaping (Approval) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.look = look
        _state = StateObject(wrappedValue: ConfirmationState(
            request: request, rule: rule, onApprove: onApprove, onDecline: onDecline
        ))
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onDisappear {
            // A question that goes away unanswered can never be approved later.
            state.disappeared()
        }
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
            ZStack(alignment: .bottomTrailing) {
                CharacterView(look: look, size: 64)
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.card(scheme), lineWidth: 3))
                    .offset(x: -10, y: -10)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(ConfirmationWords.heading)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
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
                row(ConfirmationWords.whatLabel, action.details)
                if let price = action.price {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.priceLabel, price.formatted())
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            Text(state.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
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
