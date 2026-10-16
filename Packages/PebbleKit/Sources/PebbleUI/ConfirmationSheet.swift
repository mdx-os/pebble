import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The question asked before the agent sends, buys or shares anything.
///
/// This is the only place an `Approval` is made. "Yes" approves exactly what
/// is on screen, once.
public struct ConfirmationSheet: View {
    let request: ConfirmationRequest
    let look: AgentLook
    let rule: AskFirst
    let onApprove: (Approval) -> Void
    let onDecline: () -> Void
    @Environment(\.colorScheme) private var scheme
    /// Set on the first tap, so a second tap on either button does nothing.
    @State private var answered = false

    public init(
        request: ConfirmationRequest,
        look: AgentLook = .startingPoint,
        rule: AskFirst = .shared,
        onApprove: @escaping (Approval) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.request = request
        self.look = look
        self.rule = rule
        self.onApprove = onApprove
        self.onDecline = onDecline
    }

    func approve() {
        guard !answered else { return }
        answered = true
        onApprove(request.approve())
    }

    func decline() {
        guard !answered else { return }
        answered = true
        rule.withdraw(request)
        onDecline()
    }

    private var action: ProposedAction { request.action }

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
            if !answered { rule.withdraw(request) }
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
                row(action.kind == .purchase ? ConfirmationWords.fromLabel : ConfirmationWords.toLabel, action.recipient.shownAs)
                Divider().overlay(Theme.hairline(scheme))
                row(ConfirmationWords.whatLabel, action.details)
                if let price = action.price {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.priceLabel, price.formatted())
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            Text(ConfirmationWords.promise)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Button(ProposedAction.yesTitle) { approve() }
                    .buttonStyle(PrimaryButtonStyle())
                Button(ProposedAction.noTitle) { decline() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .disabled(answered)
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
