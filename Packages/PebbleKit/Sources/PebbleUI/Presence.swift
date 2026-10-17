import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The small motions that make the app feel alive: things arriving, the
/// thinking dots, a press. With Reduce Motion on, nothing moves or scales;
/// things only fade, and the dots hold still.
enum Motion {
    /// How far a new message or chip rises as it arrives.
    static func entranceOffset(reduceMotion: Bool) -> CGFloat { reduceMotion ? 0 : 10 }

    /// How small a pressed chip gets.
    static func pressedScale(reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 0.98 }

    /// The pause before each starter chip arrives, so they land one by one.
    static func stagger(_ index: Int, reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.06 * Double(index) }

    /// How each thinking dot looks at a moment: its opacity and how far it
    /// lifts. The dots rise and fall in a slow wave, one after another.
    /// With Reduce Motion on they hold still, all three the same.
    static func dot(_ index: Int, at time: TimeInterval, reduceMotion: Bool) -> (opacity: Double, lift: CGFloat) {
        guard !reduceMotion else { return (0.55, 0) }
        let period = 1.4
        let phase = (time / period - Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
        let wave = (sin(2 * .pi * phase) + 1) / 2
        return (0.3 + 0.6 * wave, CGFloat(wave) * 3)
    }

    /// Messages slide up a touch and fade in; with Reduce Motion they only fade.
    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: entranceOffset(reduceMotion: false)).combined(with: .opacity),
            removal: .opacity
        )
    }
}

/// Three soft dots in a bubble while a reply is on its way. VoiceOver reads
/// it as one calm line rather than three dots.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Set by tests; otherwise the system setting decides.
    var stillOverride: Bool?

    private var reduceMotion: Bool { stillOverride ?? systemReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let dot = Motion.dot(index, at: time, reduceMotion: reduceMotion)
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(dot.opacity)
                        .offset(y: -dot.lift)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement()
        .accessibilityLabel(FirstConversation.thinking)
        .accessibilityIdentifier("thinking")
    }
}

/// What a light tap should mark. Felt only on iPhone; iPad and Mac have no
/// haptics engine, so there it does nothing.
enum Haptic: Equatable {
    case sent, answered, saved, forgotten

    /// True only where a phone can be felt in the hand.
    @MainActor static var isAvailable: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var feedback: SensoryFeedback {
        switch self {
        case .sent: .impact(weight: .light, intensity: 0.5)
        case .answered: .impact(weight: .light, intensity: 0.7)
        case .saved: .success
        case .forgotten: .impact(weight: .light, intensity: 0.6)
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes, on iPhone only.
    @ViewBuilder
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T) -> some View {
        #if os(iOS)
        let feedback = Haptic.isAvailable ? haptic.feedback : nil
        sensoryFeedback(trigger: trigger) { _, _ in feedback }
        #else
        self
        #endif
    }
}

/// A gentle press: a touch smaller, never with Reduce Motion.
struct SoftPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A kind empty screen: a symbol, a short title, what will show up here,
/// and one thing to do next.
struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
    }
}

/// A short note that something didn't work, in plain words, with what
/// happens next. Never shows a raw error.
struct GentleNotice: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "heart.text.square").foregroundStyle(Theme.accent)
            }
            .font(.subheadline)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).stroke(Theme.hairline(scheme)))
    }
}
#endif
