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
    /// Never fainter than `dotFloor`, so a dot keeps 3:1 against its bubble
    /// (see `Contrast`), and fully solid with Increase Contrast on.
    static func dot(_ index: Int, at time: TimeInterval, reduceMotion: Bool,
                    increasedContrast: Bool = false) -> (opacity: Double, lift: CGFloat) {
        guard !reduceMotion else { return (increasedContrast ? 1 : dotFloor, 0) }
        let period = 1.6
        let phase = (time / period - Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
        let wave = (sin(2 * .pi * phase) + 1) / 2
        let opacity = increasedContrast ? 1 : dotFloor + (1 - dotFloor) * wave
        return (opacity, CGFloat(wave) * 3)
    }

    /// The faintest a thinking dot ever gets.
    static let dotFloor = 0.6

    /// Where the soft glow sits on a progress bar that can't say how far
    /// along it is, from 0 to 1. It drifts slowly across and back. With
    /// Reduce Motion on it rests in the middle.
    static func sweep(at time: TimeInterval, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0.5 }
        let period = 3.2
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        return CGFloat((1 - cos(2 * .pi * phase)) / 2)
    }

    /// How a task's live dot breathes, as an opacity. Still with Reduce Motion.
    static func breath(at time: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        let phase = (time / 2.4).truncatingRemainder(dividingBy: 1)
        return 0.45 + 0.55 * (sin(2 * .pi * phase) + 1) / 2
    }

    /// Progress moves to its new place gently; with Reduce Motion it just goes there.
    static func progress(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.6)
    }

    /// Messages slide up a touch and fade in; with Reduce Motion they only fade.
    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: entranceOffset(reduceMotion: false)).combined(with: .opacity),
            removal: .opacity
        )
    }
}

extension EnvironmentValues {
    /// Whether things that arrive one by one, like the starter chips, play
    /// their entrance. Off unless a live screen turns it on, so previews and
    /// still renders, which may never call `onAppear`, show everything.
    @Entry var animatesEntrances = false

    /// Whether the things that move on their own, like the character's
    /// breath and the thinking dots, hold still as they do with Reduce
    /// Motion. Only the screenshots turn it on, so a screen can settle and
    /// two shots of it match.
    @Entry public var holdsStill = false
}

/// Three soft dots in a bubble while a reply is on its way. VoiceOver reads
/// it as one calm line rather than three dots.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill
    @Environment(\.colorSchemeContrast) private var contrast
    /// Set by tests; otherwise the system setting decides.
    var stillOverride: Bool?

    private var reduceMotion: Bool { stillOverride ?? (systemReduceMotion || holdsStill) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Theme.Space.xxs) {
                ForEach(0..<3, id: \.self) { index in
                    let dot = Motion.dot(index, at: time, reduceMotion: reduceMotion,
                                         increasedContrast: contrast == .increased)
                    // Full strength ink, so the floor opacity alone sets the contrast.
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 7, height: 7)
                        .opacity(dot.opacity)
                        .offset(y: -dot.lift)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            // The agent's bubble, tail and all, so the dots read as its
            // next line on the way.
            .background(Color.primary.opacity(Theme.bubbleTint),
                        in: ChatStyle.bubbleShape(.agent, ChatStyle.Grouping(isFirst: true, isLast: true)))
        }
        .accessibilityElement()
        .accessibilityLabel(FirstConversation.thinking)
        .accessibilityIdentifier("thinking")
    }
}

/// A calm progress bar for long work. A known fraction fills gently; an
/// unknown one shows a soft glow drifting along the track. With Reduce
/// Motion on nothing drifts and the fill just moves to its place.
/// VoiceOver hears the progress from the card, so the bar itself is quiet.
struct CalmProgress: View {
    let progress: TaskProgress
    /// False once the work has paused or ended, so nothing drifts.
    var isLive = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill
    @Environment(\.colorScheme) private var scheme
    /// Set by tests; otherwise the system setting decides.
    var stillOverride: Bool?

    private var reduceMotion: Bool { stillOverride ?? (systemReduceMotion || holdsStill) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(scheme == .dark ? 0.22 : 0.16))
                if let fraction = progress.fraction {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(6, width * fraction))
                        .animation(Motion.progress(reduceMotion: reduceMotion), value: fraction)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isLive)) { context in
                        let glow = width * 0.32
                        let spot = Motion.sweep(at: context.date.timeIntervalSinceReferenceDate,
                                                reduceMotion: reduceMotion || !isLive)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: glow)
                            .offset(x: (width - glow) * spot)
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// A small dot that breathes while a task is live, and holds still with
/// Reduce Motion on or once the task pauses.
struct LiveDot: View {
    var isLive = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill

    private var reduceMotion: Bool { systemReduceMotion || holdsStill }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || !isLive)) { context in
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
                .opacity(Motion.breath(at: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion || !isLive))
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// What a light tap should mark. Felt only on iPhone; iPad and Mac have no
/// haptics engine, so there it does nothing.
enum Haptic: Equatable {
    case sent, answered, saved, forgotten
    /// The microphone has started listening.
    case listening

    /// The kinds of device the app runs on, as far as haptics care.
    enum Device: Equatable, CaseIterable {
        case phone, pad, mac

        /// The device this is running on.
        @MainActor static var current: Device {
            #if os(iOS)
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: .phone
            case .mac: .mac
            default: .pad
            }
            #else
            .mac
            #endif
        }
    }

    /// The tap to play on `device`: only a phone, felt in the hand, gets one.
    func feedback(on device: Device) -> SensoryFeedback? {
        device == .phone ? feedback : nil
    }

    var feedback: SensoryFeedback {
        switch self {
        case .sent: .impact(weight: .light, intensity: 0.5)
        case .answered: .impact(weight: .light, intensity: 0.7)
        case .saved: .success
        case .forgotten: .impact(weight: .light, intensity: 0.6)
        case .listening: .impact(weight: .light, intensity: 0.4)
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes, on iPhone only.
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T) -> some View {
        self.haptic(haptic, trigger: trigger, when: { _ in true })
    }

    /// A light tap only when the trigger changes to a value that passes `when`.
    @ViewBuilder
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T, when: @escaping (T) -> Bool) -> some View {
        #if os(iOS)
        let feedback = haptic.feedback(on: .current)
        sensoryFeedback(trigger: trigger) { _, new in when(new) ? feedback : nil }
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
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.TypeScale.largeTitle)
                .foregroundStyle(Theme.accentSymbol)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.TypeScale.displayTitle3)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Theme.TypeScale.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(SoftButtonStyle())
                .padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxxl)
        .accessibilityElement(children: .contain)
    }
}

/// A short note that something didn't work, in plain words, with what
/// happens next. Never shows a raw error.
struct GentleNotice: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(Theme.accentSymbol)
            }
            .font(Theme.TypeScale.subheadline)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SoftButtonStyle())
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(.flat, radius: Theme.Radius.small)
    }
}
#endif
