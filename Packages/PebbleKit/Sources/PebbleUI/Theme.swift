import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// Shared spacing, shapes and colors so every screen feels like one place.
enum Theme {
    static let corner: CGFloat = 20
    static let smallCorner: CGFloat = 14
    static let gutter: CGFloat = 24
    static let readableWidth: CGFloat = 560
    /// The chat column on wide screens: about 75 characters a line at the
    /// default text size, so lines never run edge to edge on a big iPad.
    static let chatWidth: CGFloat = 680
    static let bubbleWidth: CGFloat = 520
    /// The Today feed on wide screens: room for two cards side by side,
    /// each about as wide as a phone.
    static let feedWidth: CGFloat = 880

    typealias RGB = Contrast.RGB

    /// The warm brand accent, for fills, strokes and the washes below. Never
    /// for words: on a light card it reads at about 2.4 to 1. Words in the
    /// accent's warmth use `accentText`. `ContrastGuardTests` checks both.
    static let accent = accentRGB.color
    static let accentRGB = RGB(red: 0.96, green: 0.52, blue: 0.29)

    /// The accent for a symbol beside words, such as a card's kind icon.
    /// Only ever on an `Image`; `ContrastGuardTests` checks.
    ///
    /// This is the raw accent, about 2.4 to 1 on a light card. That is fine
    /// while the symbol is decoration next to words that say the same thing.
    /// A symbol that carries meaning on its own needs 3 to 1 (WCAG 1.4.11),
    /// so give it a deeper color, such as `accentText`, rather than this.
    static let accentSymbol = accent

    /// Words in the accent's warmth, such as "Open" on a card: a deeper
    /// orange in light and a lighter one in dark, so they clear 4.5 to 1 on
    /// the backdrop, the cards and the accent wash.
    static let accentText = Ink(light: RGB(0.66, 0.29, 0.07), dark: RGB(0.98, 0.64, 0.44))

    /// Quieter words, such as times and details. The system's secondary
    /// gray reads at about 3.5 to 1 on white, under the 4.5 small text
    /// needs, so this one is a little deeper in light.
    static let secondaryText = Ink(light: RGB(0.36, 0.36, 0.38), dark: RGB(0.68, 0.68, 0.71))

    /// Words for a choice that removes something, such as Forget everything.
    static let dangerText = Ink(light: RGB(0.74, 0.12, 0.10), dark: RGB(1.00, 0.54, 0.51))

    /// Small words on an accent fill. White there is too faint to read
    /// (about 2.5 to 1), so it is a deep brown of the same warmth, well over
    /// the 4.5 to 1 small text needs.
    static let onAccent = onAccentRGB.color
    static let onAccentRGB = RGB(red: 0.20, green: 0.10, blue: 0.04)

    /// How strongly the accent tints a soft button, a chip or a pill.
    static let accentWash = 0.14
    /// How strongly the accent tints the person's own chat bubbles.
    static let personBubbleWash = 0.18
    /// How strongly the primary ink tints a text field or a neutral chip.
    static let fieldTint = 0.06
    /// How strongly the primary ink tints a button that can't be pressed yet.
    static let disabledTint = 0.08

    /// A color for words that reads well in light and dark: `light` in
    /// light mode and `dark` in dark mode.
    struct Ink: ShapeStyle {
        let light: RGB
        let dark: RGB

        func rgb(_ scheme: ColorScheme) -> RGB { scheme == .dark ? dark : light }

        func resolve(in environment: EnvironmentValues) -> Color { rgb(environment.colorScheme).color }
    }

    /// Words and what they sit on, by name, for `textPairs`.
    struct TextPair {
        let text: String
        let background: String
        let textColor: RGB
        let backgroundColor: RGB

        var contrast: Double { textColor.contrast(with: backgroundColor) }
    }

    /// Every pair of words and background the screens use, worked out as the
    /// colors that reach the eye. Add a pair here whenever a screen puts
    /// words on something new; `ContrastGuardTests` holds each to 4.5 to 1.
    ///
    /// The primary ink is the system label: black in light, white in dark.
    /// Each surface is checked over both ends of the backdrop and over a
    /// sheet, the system background a question or a reader opens on.
    static func textPairs(_ scheme: ColorScheme) -> [TextPair] {
        let ink: RGB = scheme == .dark ? .white : .black
        let ends = backdropEnds(scheme)
        let bases: [(String, RGB)] = [
            ("backdrop top", ends.top),
            ("backdrop bottom", ends.bottom),
            ("sheet", sheetRGB(scheme)),
        ]
        var surfaces: [(String, RGB)] = []
        for (name, base) in bases {
            let card = RGB.white.over(base, opacity: cardOpacity(scheme))
            surfaces += [
                (name, base),
                ("card on \(name)", card),
                ("accent wash on \(name)", accentRGB.over(base, opacity: accentWash)),
                ("accent wash on the card on \(name)", accentRGB.over(card, opacity: accentWash)),
                ("your bubble on \(name)", accentRGB.over(base, opacity: personBubbleWash)),
                ("agent bubble on \(name)", ink.over(base, opacity: bubbleTint)),
                ("field on \(name)", ink.over(base, opacity: fieldTint)),
                ("field on the card on \(name)", ink.over(card, opacity: fieldTint)),
                ("disabled button on \(name)", ink.over(base, opacity: disabledTint)),
            ]
        }
        let inks: [(String, RGB)] = [
            ("primary", ink),
            ("secondaryText", secondaryText.rgb(scheme)),
            ("accentText", accentText.rgb(scheme)),
            ("dangerText", dangerText.rgb(scheme)),
        ]
        var pairs = inks.flatMap { text in
            surfaces.map { TextPair(text: text.0, background: $0.0, textColor: text.1, backgroundColor: $0.1) }
        }
        // Words on the accent fill: the primary button, "Have a look", Send.
        pairs.append(TextPair(text: "onAccent", background: "accent", textColor: onAccentRGB, backgroundColor: accentRGB))
        return pairs
    }

    /// The system background a sheet opens on.
    static func sheetRGB(_ scheme: ColorScheme) -> RGB {
        scheme == .dark ? RGB(0.11, 0.11, 0.12) : .white
    }

    /// A soft wash behind every screen. Adapts to light and dark.
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        let ends = backdropEnds(scheme)
        return LinearGradient(colors: [ends.top.color, ends.bottom.color], startPoint: .top, endPoint: .bottom)
    }

    /// The two ends of the backdrop, as numbers so contrast can be checked.
    static func backdropEnds(_ scheme: ColorScheme) -> (top: Contrast.RGB, bottom: Contrast.RGB) {
        scheme == .dark
            ? (Contrast.RGB(0.11, 0.10, 0.12), Contrast.RGB(0.07, 0.07, 0.08))
            : (Contrast.RGB(1.00, 0.97, 0.94), Contrast.RGB(0.99, 0.99, 0.98))
    }

    /// How strongly the chat bubbles and the thinking bubble are tinted with
    /// the primary ink over the backdrop.
    static let bubbleTint = 0.06

    /// Card surface that reads well in light and dark.
    static func card(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(cardOpacity(scheme))
    }

    /// How much white a card lays over what is behind it.
    static func cardOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.07 : 0.85
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func colors(for look: AgentLook) -> [Color] {
        switch look {
        case .sunrise: [Color(red: 1.00, green: 0.71, blue: 0.42), Color(red: 0.95, green: 0.42, blue: 0.36)]
        case .meadow: [Color(red: 0.62, green: 0.86, blue: 0.55), Color(red: 0.24, green: 0.62, blue: 0.47)]
        case .tide: [Color(red: 0.55, green: 0.80, blue: 0.98), Color(red: 0.27, green: 0.45, blue: 0.86)]
        case .dusk: [Color(red: 0.80, green: 0.66, blue: 0.98), Color(red: 0.47, green: 0.33, blue: 0.78)]
        }
    }
}

/// Full width primary button with a gentle press response.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            // Dark words on the accent read at about 6.4 to 1; white was 2.5.
            // Not ready yet, it goes quiet gray on a neutral fill, which still
            // reads in dark mode where a faded accent would not.
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(Theme.disabledTint)),
                        in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The primary button's look at the size of its words, such as Send.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(Theme.disabledTint)),
                        in: Capsule())
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A soft button for a second choice: accent words on the accent wash, or
/// plain words on a neutral one.
struct SoftButtonStyle: ButtonStyle {
    var neutral = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(!isEnabled ? AnyShapeStyle(Theme.secondaryText)
                             : neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Theme.accentText))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(neutral || !isEnabled ? AnyShapeStyle(Color.primary.opacity(Theme.fieldTint))
                        : AnyShapeStyle(Theme.accent.opacity(Theme.accentWash)), in: Capsule())
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet text button for secondary choices.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Centers content in a column no wider than `width`, with the usual
    /// gutter, while whatever holds it (a scroll view) stays full width.
    func readableColumn(_ width: CGFloat) -> some View {
        padding(.horizontal, Theme.gutter)
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }

    /// The pointer's highlight on iPad. Elsewhere this does nothing.
    @ViewBuilder
    func pointerHover(in shape: some Shape = RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)) -> some View {
        #if os(iOS)
        contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

/// WCAG contrast math for checking that small marks, like the thinking
/// dots, stay visible against what is behind them.
enum Contrast {
    struct RGB: Equatable {
        let red, green, blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(red: Double, green: Double, blue: Double) {
            self.init(red, green, blue)
        }

        /// The WCAG contrast ratio between two colors, from 1 to 21.
        func contrast(with other: RGB) -> Double { Contrast.ratio(self, other) }

        static let black = RGB(0, 0, 0)
        static let white = RGB(1, 1, 1)

        var color: Color { Color(red: red, green: green, blue: blue) }

        /// This color laid at `opacity` over `base`.
        func over(_ base: RGB, opacity: Double) -> RGB {
            RGB(base.red + (red - base.red) * opacity,
                base.green + (green - base.green) * opacity,
                base.blue + (blue - base.blue) * opacity)
        }

        /// Relative luminance in sRGB.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    /// From 1 (none) to 21 (black on white).
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// A thinking dot at `opacity` against the bubble behind it, over the
    /// lightest-contrast end of the backdrop. The primary ink is black in
    /// light and white in dark.
    static func thinkingDot(_ scheme: ColorScheme, opacity: Double) -> Double {
        let ink: RGB = scheme == .dark ? .white : .black
        let ends = Theme.backdropEnds(scheme)
        return [ends.top, ends.bottom].map { end in
            let bubble = ink.over(end, opacity: Theme.bubbleTint)
            return ratio(ink.over(bubble, opacity: opacity), bubble)
        }.min() ?? 1
    }
}

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Theme.backdrop(scheme).ignoresSafeArea() }
}
#endif
