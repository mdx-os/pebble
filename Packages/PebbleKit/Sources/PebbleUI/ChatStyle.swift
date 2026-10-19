import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The chat's own look: bubble shapes and how they group, the floating
/// composer, the suggestion chips and the character's calm presence. It
/// builds on `Theme`'s tokens and never changes its colors, so every pair
/// of words and background here is one `Theme.textPairs` already holds.
/// Only values that belong to the chat alone live here, and each comes
/// from a `Theme` token where one fits.
enum ChatStyle {
    /// The round of a bubble's corners: a card's.
    static let bubbleCorner = Theme.Radius.card
    /// The corner a bubble points from, at the foot of its group: a soft
    /// tail, tighter than any of Theme's corners.
    static let tailCorner: CGFloat = 6
    /// The corners on the speaker's side between lines of one group, so a
    /// run of lines reads as one thought.
    static let groupedCorner = Theme.Space.xs
    /// The space between lines from the same speaker, and between speakers.
    static let groupedSpacing = Theme.Space.xxs
    static let speakerSpacing = Theme.Space.s
    /// A little air between the lines of one bubble.
    static let lineSpacing: CGFloat = 2
    /// How far lines fade as they scroll up under the chat's fixed header.
    static let headerFade = Theme.Space.l

    /// The fade under the header: none when the header scrolls with the
    /// lines, and none with Increase Contrast, so no words or bubble edges
    /// are ever faded below the contrast the guards hold them to.
    static func headerFadeHeight(scrolls: Bool, contrast: ColorSchemeContrast) -> CGFloat {
        scrolls || contrast == .increased ? 0 : headerFade
    }

    /// The character in the chat's header: larger on a new chat, smaller
    /// once talking so the conversation has the room.
    static let greetingFace: CGFloat = 88
    static let talkingFace: CGFloat = 64

    /// Who the header's face is, as far as SwiftUI can tell. One face that
    /// shrinks on a spring, or with Reduce Motion a new face for each size,
    /// so the change is only a cross fade and nothing grows or shrinks.
    static func faceIdentity(_ size: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? size : 0
    }

    /// The round accent send button inside the composer, before Dynamic
    /// Type: the smallest target a finger needs.
    static let sendSize: CGFloat = 44
    /// The composer's floating bar: its corners follow the send button's
    /// round, one step of the spacing grid out.
    static let composerCorner = sendSize / 2 + Theme.Space.xxs

    /// Replies, sends and the composer settle with a soft spring.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// With Reduce Motion, things only cross fade.
    static let fade = Animation.easeOut(duration: 0.18)

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : spring
    }

    /// Where a line sits in its run of lines from one speaker.
    struct Grouping: Equatable {
        var isFirst: Bool
        var isLast: Bool
    }

    /// Each turn's place in its group: a new group starts whenever the
    /// speaker changes.
    static func grouping(of turns: [ChatTurn]) -> [UUID: Grouping] {
        var result: [UUID: Grouping] = [:]
        for (index, turn) in turns.enumerated() {
            let previous = index > 0 ? turns[index - 1].speaker : nil
            let next = index + 1 < turns.count ? turns[index + 1].speaker : nil
            result[turn.id] = Grouping(isFirst: previous != turn.speaker, isLast: next != turn.speaker)
        }
        return result
    }

    /// A bubble's shape: round everywhere but on the speaker's side, where
    /// lines of one group sit close and the last one ends in a small tail.
    static func bubbleShape(_ speaker: ChatTurn.Speaker, _ grouping: Grouping) -> UnevenRoundedRectangle {
        let top = grouping.isFirst ? bubbleCorner : groupedCorner
        let bottom = grouping.isLast ? tailCorner : groupedCorner
        let radii = speaker == .agent
            ? RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: bubbleCorner, topTrailing: bubbleCorner)
            : RectangleCornerRadii(topLeading: bubbleCorner, bottomLeading: bubbleCorner, bottomTrailing: bottom, topTrailing: top)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    }

    /// How a new line arrives: it grows a touch from its speaker's corner as
    /// it rises and fades in. With Reduce Motion it only fades.
    static func arrival(_ speaker: ChatTurn.Speaker, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let corner: UnitPoint = speaker == .agent ? .bottomLeading : .bottomTrailing
        return .asymmetric(
            insertion: .scale(scale: 0.94, anchor: corner)
                .combined(with: .offset(y: Motion.entranceOffset(reduceMotion: false)))
                .combined(with: .opacity),
            removal: .opacity
        )
    }

    /// A reply's light tap: when the chat gains a line, the newest line is
    /// the agent's, and the person has said something. Not for the opening
    /// line of a new chat, nor when a line is taken away.
    static func playsReplyTap(from old: ReplyMark, to new: ReplyMark) -> Bool {
        new.count > old.count && new.lastIsReply
    }

    /// What the reply tap watches.
    struct ReplyMark: Equatable {
        var count: Int
        var lastIsReply: Bool

        init(_ turns: [ChatTurn]) {
            count = turns.count
            lastIsReply = turns.last?.speaker == .agent && turns.contains { $0.speaker == .person }
        }
    }

    /// Whether a tapped suggestion may take the composer's place. It fills
    /// an empty field, or swaps a suggestion the last tap put there that
    /// nobody has touched since, but never replaces words the person typed
    /// or pasted, even ones that read the same as a suggestion. Nothing is
    /// sent.
    static func suggestionTakes(_ draft: String, fromSuggestion: Bool) -> Bool {
        fromSuggestion || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A symbol for each starter, the same in the first run and the chat.
    static func symbol(forStarter id: String) -> String {
        switch id {
        case "morning": "sun.horizon"
        case "talk": "bubble.left.and.bubble.right"
        case "remember": "bookmark"
        default: "sparkles"
        }
    }
}

/// The character's calm presence, as numbers, so it can be checked: a slow
/// breath while it rests, and a quicker, brighter glow while a reply is on
/// its way. With Reduce Motion it holds still at rest.
enum Breath {
    /// How far through a breath the character is, from 0 to 1.
    static func phase(at time: TimeInterval, thinking: Bool) -> Double {
        let period = thinking ? 1.6 : 4.2
        return (1 - cos(2 * .pi * (time / period).truncatingRemainder(dividingBy: 1))) / 2
    }

    /// The body's scale, the glow's scale and the glow's strength.
    static func look(at time: TimeInterval, thinking: Bool, reduceMotion: Bool)
        -> (body: CGFloat, glow: CGFloat, glowOpacity: Double) {
        guard !reduceMotion else { return (1, 1, thinking ? 0.5 : 0.35) }
        let wave = phase(at: time, thinking: thinking)
        if thinking {
            return (0.995 + 0.02 * wave, 0.98 + 0.12 * wave, 0.38 + 0.22 * wave)
        }
        return (0.99 + 0.03 * wave, 0.96 + 0.10 * wave, 0.30 + 0.10 * wave)
    }
}

extension View {
    /// The reply's light tap, on iPhone only, with the system's haptics
    /// setting: the same `Haptic.answered` the question sheet plays.
    @ViewBuilder
    func replyTap(_ mark: ChatStyle.ReplyMark) -> some View {
        #if os(iOS)
        let feedback = Haptic.answered.feedback(on: .current)
        sensoryFeedback(trigger: mark) { old, new in
            ChatStyle.playsReplyTap(from: old, to: new) ? feedback : nil
        }
        #else
        self
        #endif
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full. At
/// the largest text sizes each chip takes a row of its own.
struct FlowRows: Layout {
    var spacing = Theme.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The round send button at the end of the composer: an arrow on the
/// accent, in the dark words color `Theme.textPairs` holds on it, and quiet
/// gray on a neutral fill until there is something to send. VoiceOver still
/// calls it Send.
///
/// Kept as plain as `AccentButtonStyle`: an earlier version with a hover
/// effect, an outer frame and an animation on being enabled drew a keyboard
/// focus ring around the iPad sidebar's chosen row on launch.
struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = ChatStyle.sendSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.TypeScale.body.weight(.bold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText))
            .frame(width: size, height: size)
            .background(isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(Theme.disabledTint)),
                        in: Circle())
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Circle())
    }
}
#endif
