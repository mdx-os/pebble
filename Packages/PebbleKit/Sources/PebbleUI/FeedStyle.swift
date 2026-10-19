import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// What only Today's cards need beyond `Theme`: the grid, the kind badge,
/// and the card surface's few extras. Built only from `Theme`'s tokens and
/// colors, so every word stays on a pair `Theme.textPairs` checks, or on
/// the card in dark that `FeedStyleTests` checks the same way. Paddings,
/// spacings, corners and type come straight from `Theme`.
enum FeedStyle {
    /// The narrowest a card on Today may be before the grid drops a column.
    /// Scaled with the text, so large text gets fewer, roomier columns.
    static let cardMinimum: CGFloat = 280
    /// The most cards side by side: three on a wide iPad in landscape.
    static let maxColumns = 3
    /// Today's column on wide screens: room for three cards at `cardMinimum`
    /// beside the sidebar, so a 13-inch iPad shows two in portrait and three
    /// in landscape. The chat and the readers keep their own, narrower ones.
    static let wideFeedWidth: CGFloat = 1180

    /// How much of the accent tints a card. None in either scheme: the
    /// backdrop is already a warm off-white in light and a warm charcoal in
    /// dark, and the blue accent laid over a dark card would cool it.
    static func warmth(_ scheme: ColorScheme) -> Double {
        0
    }

    /// The card as it reaches the eye over `base`: the usual card, then the
    /// warmth. `FeedStyleTests` holds every word on it to 4.5 to 1.
    static func warmCard(over base: Contrast.RGB, _ scheme: ColorScheme) -> Contrast.RGB {
        let card = Contrast.RGB.white.over(base, opacity: Theme.cardOpacity(scheme))
        return Theme.accentRGB.over(card, opacity: warmth(scheme))
    }

    /// The size of the round badge that holds a card's kind symbol.
    static let badge: CGFloat = 24
    /// How far the badge reaches past its line, above and below, so the
    /// kind line is no taller than its words.
    static let badgeOverhang: CGFloat = 3
}

/// A card's surface on Today: a raised `Theme` card. A card that asks for a
/// yes gets the accent edge. With Increase Contrast the edge is the field
/// edge, which clears 3 to 1, and with Reduce Transparency the card sits on
/// a solid base of the backdrop's own color, so nothing shows through it.
struct FeedCardSurface: ViewModifier {
    var asks = false
    var corner: CGFloat = Theme.Radius.card
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    private var edge: Color? {
        if asks { return Theme.accent.opacity(contrast == .increased ? 1 : 0.55) }
        return contrast == .increased ? Theme.fieldEdge.rgb(scheme, increasedContrast: true).color : nil
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Theme.accent.opacity(FeedStyle.warmth(scheme))))
            .elevation(.raised, in: shape, edge: edge, edgeWidth: asks ? 1.5 : 1)
            .background {
                if reduceTransparency {
                    shape.fill(Theme.backdropEnds(scheme).top.color)
                }
            }
    }
}

extension View {
    /// See `FeedCardSurface`.
    func feedCardSurface(asks: Bool = false, corner: CGFloat = Theme.Radius.card) -> some View {
        modifier(FeedCardSurface(asks: asks, corner: corner))
    }
}

/// A card's kind: its symbol in a soft round badge, then the words. The
/// symbol is decoration beside words that say the same thing.
struct KindBadge<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: Icon
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = FeedStyle.badge

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            icon
                .font(Theme.TypeScale.caption.weight(.bold))
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(Theme.accentWash), in: Circle())
                .padding(.vertical, -FeedStyle.badgeOverhang)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.TypeScale.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small fact on a card, such as when a summary was gathered: a symbol
/// and quiet words on a neutral capsule.
struct ProofChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
        }
        .font(Theme.TypeScale.caption.weight(.medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xxs)
        .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
    }
}

/// One source on a summary's card: its number, a page symbol, who published
/// it and the site it is on, and the date. Nothing is fetched to draw it.
/// VoiceOver reads it as a whole, with the label the card gives it.
struct SourceChip: View {
    let number: Int
    let source: ReconSource
    let line: String

    /// "riverside.example", without a leading "www.".
    static func host(_ url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            SourceNumber(number: number)
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(line)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(Theme.TypeScale.footnote.weight(.medium))
                if let host = Self.host(source.url) {
                    Text(host)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(Theme.fieldTint),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

/// What Today shows with nothing on it: the character on a soft glow, with
/// a few calm symbols drifting around it. All of it decoration.
struct QuietIllustration: View {
    let look: AgentLook
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 72

    /// Where each symbol sits around the character, as a share of `size`.
    private static let symbols: [(name: String, x: CGFloat, y: CGFloat, scale: CGFloat)] = [
        ("sun.max.fill", -0.95, -0.55, 0.30),
        ("sparkle", 0.95, -0.70, 0.24),
        ("leaf.fill", 1.05, 0.45, 0.26),
        ("heart.fill", -1.05, 0.50, 0.24),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(Theme.accentWash))
                .frame(width: size * 1.9, height: size * 1.9)
            Circle()
                .fill(Theme.accent.opacity(Theme.accentWash * 0.6))
                .frame(width: size * 2.6, height: size * 2.6)
            // Each symbol is drawn to a frame that grows with `size`, so it
            // scales with the text like the rest without a fixed font size.
            ForEach(Self.symbols, id: \.name) { symbol in
                Image(systemName: symbol.name)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .frame(width: size * symbol.scale, height: size * symbol.scale)
                    .foregroundStyle(Theme.accentSymbol.opacity(0.7))
                    .offset(x: symbol.x * size, y: symbol.y * size)
            }
            CharacterView(look: look, size: size)
        }
        .frame(height: size * 2.6)
        .accessibilityHidden(true)
    }
}
#endif
