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
    let onApprove: (Approval) -> Void
    let onDecline: () -> Void
    @Environment(\.colorScheme) private var scheme

    public init(
        request: ConfirmationRequest,
        look: AgentLook = .startingPoint,
        onApprove: @escaping (Approval) -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.request = request
        self.look = look
        self.onApprove = onApprove
        self.onDecline = onDecline
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
                Divider().overlay(Theme.hairline(scheme))
                row(ConfirmationWords.whatLabel, action.details)
                if let price = action.price {
                    Divider().overlay(Theme.hairline(scheme))
                    row(ConfirmationWords.priceLabel, Self.format(price))
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            Text(ConfirmationWords.promise)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Button(ProposedAction.yesTitle) { onApprove(request.approve()) }
                    .buttonStyle(PrimaryButtonStyle())
                Button(ProposedAction.noTitle, action: onDecline)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.gutter)
        .frame(maxWidth: 480)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    static func format(_ price: Price) -> String {
        let amount = Decimal(price.minorUnits) / 100
        return amount.formatted(.currency(code: price.currency))
    }
}
#endif
