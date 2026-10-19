import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The look of Today's cards: one surface, one padding, one way to show a
/// card's kind, a source and a small fact. Built only from `Theme`'s
/// tokens, so every word stays on a pair `Theme.textPairs` checks, or on
/// the warm card in dark that `FeedStyleTests` checks the same way.
enum FeedStyle {
    /// The room inside every card on Today. Kept to the height cards had,
    /// so a small phone still shows as much of the feed above the composer.
    static let cardPadding: CGFloat = 16
    /// The room between a card's parts: its kind line, title and body.
    static let cardStack: CGFloat = 10

    /// The narrowest a card on Today may be before the grid drops a column.
    /// Scaled with the text, so large text gets fewer, roomier columns.
    static let cardMinimum: CGFloat = 280
    /// The most cards side by side: three on a wide iPad in landscape.
    static let maxColumns = 3
    /// Today's column on wide screens: room for three cards at `cardMinimum`
    /// beside the sidebar, so a 13-inch iPad shows two in portrait and three
    /// in landscape. The chat and the readers keep their own, narrower ones.
    static let wideFeedWidth: CGFloat = 1180

    /// How much of the accent warms a card in dark, so it reads as a warm
    /// charcoal rather than a cool gray. None in light, where the card is
    /// already near white on the warm backdrop.
    static func warmth(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.03 : 0
    }

    /// The card in dark as it reaches the eye over `base`: the usual card,
    /// then the warmth. `FeedStyleTests` holds every word on it to 4.5 to 1.
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

/// A card's surface on Today: the card fill, a hairline, and a soft shadow
/// that lifts it off the backdrop. A card that asks for a yes gets the
/// accent edge. With Increase Contrast the edge is the field edge, which
/// clears 3 to 1, and with Reduce Transparency the card sits on a solid
/// base of the backdrop's own color, so nothing shows through it.
struct FeedCardSurface: ViewModifier {
    var asks = false
    var corner: CGFloat = Theme.corner
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    private var edge: AnyShapeStyle {
        if asks { return AnyShapeStyle(Theme.accent.opacity(contrast == .increased ? 1 : 0.55)) }
        return contrast == .increased ? AnyShapeStyle(Theme.fieldEdge) : AnyShapeStyle(Theme.hairline(scheme))
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(Theme.backdropEnds(scheme).top.color)
                    }
                    shape.fill(Theme.card(scheme))
                    shape.fill(Theme.accent.opacity(FeedStyle.warmth(scheme)))
                }
                // Two soft shadows: a close one for the edge, a wide one for depth.
                .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.04), radius: 2, y: 1)
                .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.06), radius: 14, y: 6)
            }
            .overlay(shape.strokeBorder(edge, lineWidth: asks ? 1.5 : 1))
    }
}

extension View {
    /// See `FeedCardSurface`.
    func feedCardSurface(asks: Bool = false, corner: CGFloat = Theme.corner) -> some View {
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
        HStack(spacing: 8) {
            icon
                .font(.caption.weight(.bold))
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(Theme.accentWash), in: Circle())
                .padding(.vertical, -FeedStyle.badgeOverhang)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
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
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                .font(.footnote.weight(.medium))
                if let host = Self.host(source.url) {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(Theme.fieldTint),
                    in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
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
            ForEach(Self.symbols, id: \.name) { symbol in
                Image(systemName: symbol.name)
                    .font(.system(size: size * symbol.scale, weight: .semibold))
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
