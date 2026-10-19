import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The design system every screen draws from: type, spacing, corners,
/// depth and color. Views use these tokens, never literal sizes or colors,
/// so every screen feels like one place.
enum Theme {
    // MARK: Type

    /// The type scale: SF Pro through the Dynamic Type text styles, so every
    /// size grows with the person's setting, accessibility sizes too. The
    /// `display` styles are the rounded design, kept for big warm words such
    /// as a name or a screen's greeting; everything else reads in plain SF Pro.
    enum TypeScale {
        static let largeTitle = Font.largeTitle
        static let title = Font.title
        static let title2 = Font.title2
        static let title3 = Font.title3
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let subheadline = Font.subheadline
        static let footnote = Font.footnote
        static let caption = Font.caption
        static let caption2 = Font.caption2

        /// The biggest warm words: a screen's greeting or the agent's name.
        static let displayLarge = Font.system(.largeTitle, design: .rounded).weight(.bold)
        /// A screen or card title that should feel friendly.
        static let displayTitle = Font.system(.title2, design: .rounded).weight(.bold)
        /// A smaller friendly title.
        static let displayTitle3 = Font.system(.title3, design: .rounded).weight(.semibold)
        /// A friendly heading at the size of a headline.
        static let displayHeadline = Font.system(.headline, design: .rounded)

        /// The only fixed sizes: a glyph drawn inside a badge of fixed size,
        /// which would spill out of it if it grew. Each badge is hidden from
        /// VoiceOver and sits beside words that do grow.
        ///
        /// A symbol in the 64 point accent circle at the top of a sheet.
        static let badgeSymbol = Font.system(size: 30, weight: .semibold)
        /// An initial in the 88 point avatar circle.
        static let avatarInitial = Font.system(size: 40, weight: .semibold, design: .rounded)
    }

    // MARK: Spacing

    /// The spacing scale, on a 4 point grid. Paddings and stack spacings
    /// come from here.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
    }

    // MARK: Corners

    /// Corner radii, always drawn continuous.
    enum Radius {
        /// Fields, chips, small notes and bubbles.
        static let small: CGFloat = 14
        /// Cards.
        static let card: CGFloat = 20
        /// A sheet or a large panel.
        static let sheet: CGFloat = 28
    }

    static let gutter = Space.xl
    static let readableWidth: CGFloat = 560
    /// The chat column on wide screens: about 75 characters a line at the
    /// default text size, so lines never run edge to edge on a big iPad.
    static let chatWidth: CGFloat = 680
    static let bubbleWidth: CGFloat = 520
    /// The Today feed on wide screens: room for two cards side by side,
    /// each about as wide as a phone.
    static let feedWidth: CGFloat = 880

    typealias RGB = Contrast.RGB

    /// The brand accent, a clear friendly blue, for fills, strokes and the
    /// washes below. Never for words: on a light card it reads at about 2.7
    /// to 1. Words in the accent's color use `accentText`.
    /// `ContrastGuardTests` checks both.
    static let accent = accentRGB.color
    static let accentRGB = RGB(red: 0.40, green: 0.62, blue: 0.97)

    /// The accent for a symbol beside words, such as a card's kind icon.
    /// Only ever on an `Image`; `ContrastGuardTests` checks.
    ///
    /// This is the raw accent, about 2.7 to 1 on a light card. That is fine
    /// while the symbol is decoration next to words that say the same thing.
    /// A symbol that carries meaning on its own needs 3 to 1 (WCAG 1.4.11),
    /// so give it a deeper color, such as `accentText`, rather than this.
    static let accentSymbol = accent

    /// Words in the accent's color, such as "Open" on a card: a deeper blue
    /// in light and a lighter one in dark, so they clear 4.5 to 1 on the
    /// backdrop, the cards and the accent wash. Deeper still with Increase
    /// Contrast on.
    static let accentText = Ink(light: RGB(0.11, 0.36, 0.78), dark: RGB(0.56, 0.74, 1.00),
                                increased: (RGB(0.05, 0.26, 0.62), RGB(0.72, 0.84, 1.00)))

    /// Quieter words, such as times and details: a warm gray. The system's
    /// secondary gray reads at about 3.5 to 1 on white, under the 4.5 small
    /// text needs, so this one is a little deeper in light.
    static let secondaryText = Ink(light: RGB(0.38, 0.36, 0.34), dark: RGB(0.72, 0.70, 0.67),
                                   increased: (RGB(0.26, 0.25, 0.24), RGB(0.85, 0.83, 0.80)))

    /// The tint for system controls that fill with it and write white words
    /// on top: the selected row in the iPad sidebar and a confirmation
    /// button such as Done. `accentText` is light in dark mode, so white on
    /// it reads near 2 to 1; this deep blue keeps white over 4.5 to 1 in
    /// both schemes. Use it only where the tint is a fill, never for words.
    ///
    /// The sidebar's tint also colors the icons of the rows not chosen. So
    /// in dark mode it is a touch lighter, enough to clear the 3 to 1 an
    /// icon needs (WCAG 1.4.11) on the sidebar, while white on it still
    /// clears 4.5. Words in it would need 4.5 on dark and can't have both,
    /// which is why it is never for words. `ContrastLint` keeps it to the
    /// sidebar and `DoneButton`.
    static let tintFill = Ink(light: RGB(0.13, 0.37, 0.80), dark: RGB(0.16, 0.42, 0.86))

    /// The edge of a text field, so the field can be found on the bar or
    /// the backdrop it sits on: 3 to 1 against both, as WCAG 1.4.11 asks
    /// of a control's boundary.
    static let fieldEdge = Ink(light: RGB(0.48, 0.46, 0.44), dark: RGB(0.52, 0.50, 0.47),
                               increased: (RGB(0.30, 0.29, 0.28), RGB(0.72, 0.70, 0.67)))

    /// Words for a choice that removes something, such as Forget everything.
    static let dangerText = Ink(light: RGB(0.74, 0.12, 0.10), dark: RGB(1.00, 0.58, 0.55),
                                increased: (RGB(0.58, 0.06, 0.05), RGB(1.00, 0.72, 0.70)))

    /// Small words on an accent fill. White there is too faint to read
    /// (about 2.7 to 1), so it is a deep navy of the same blue, well over
    /// the 4.5 to 1 small text needs.
    static let onAccent = onAccentRGB.color
    static let onAccentRGB = RGB(red: 0.03, green: 0.09, blue: 0.24)

    /// Words on `tintFill`, as on the sidebar's chosen row: white, which
    /// reads at over 4.5 to 1 there in both schemes. Only ever on that fill:
    /// `ContrastLint` keeps it to `FillButtonStyle` and HomeSplit's chosen row.
    static let onTintFill = RGB.white.color

    /// How strongly the accent tints a soft button, a chip or a pill.
    static let accentWash = 0.14
    /// How strongly the accent tints the person's own chat bubbles.
    static let personBubbleWash = 0.18
    /// How strongly the primary ink tints a text field or a neutral chip.
    static let fieldTint = 0.06
    /// How strongly the primary ink tints a button that can't be pressed yet.
    static let disabledTint = 0.08

    /// How strongly the accent marks what was taken out of a cloud preview,
    /// such as `[name]`, behind the primary words on the payload card.
    static func maskWash(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.45 : 0.28
    }

    /// A color for words that reads well in light and dark: `light` in
    /// light mode and `dark` in dark mode, and the `increased` pair, when it
    /// has one, with Increase Contrast on.
    struct Ink: ShapeStyle {
        let light: RGB
        let dark: RGB
        var increased: (light: RGB, dark: RGB)?

        init(light: RGB, dark: RGB, increased: (light: RGB, dark: RGB)? = nil) {
            self.light = light
            self.dark = dark
            self.increased = increased
        }

        func rgb(_ scheme: ColorScheme, increasedContrast: Bool = false) -> RGB {
            if increasedContrast, let increased { return scheme == .dark ? increased.dark : increased.light }
            return scheme == .dark ? dark : light
        }

        func resolve(in environment: EnvironmentValues) -> Color {
            rgb(environment.colorScheme, increasedContrast: environment.colorSchemeContrast == .increased).color
        }
    }

    /// Words and what they sit on, by name, for `textPairs`.
    struct TextPair {
        let text: String
        let background: String
        let textColor: RGB
        let backgroundColor: RGB
        /// 4.5 to 1 for words. A field's edge is not words, so it needs the
        /// 3 to 1 WCAG asks of a control's boundary.
        var minimum = 4.5

        var contrast: Double { textColor.contrast(with: backgroundColor) }
    }

    /// Every pair of words and background the screens use, worked out as the
    /// colors that reach the eye. Add a pair here whenever a screen puts
    /// words on something new; `ContrastGuardTests` holds each to 4.5 to 1.
    ///
    /// The primary ink is the system label: black in light, white in dark.
    /// Each surface is checked over both ends of the backdrop and over a
    /// sheet, the system background a question or a reader opens on.
    ///
    /// With `increasedContrast`, each ink is the one Increase Contrast draws.
    static func textPairs(_ scheme: ColorScheme, increasedContrast: Bool = false) -> [TextPair] {
        let ink: RGB = scheme == .dark ? .white : .black
        let secondaryText = secondaryText.rgb(scheme, increasedContrast: increasedContrast)
        let accentText = accentText.rgb(scheme, increasedContrast: increasedContrast)
        let dangerText = dangerText.rgb(scheme, increasedContrast: increasedContrast)
        let fieldEdge = fieldEdge.rgb(scheme, increasedContrast: increasedContrast)
        let tintFill = tintFill.rgb(scheme, increasedContrast: increasedContrast)
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
                // A task card's Send before there are words to send.
                ("disabled button on the card on \(name)", ink.over(card, opacity: disabledTint)),
            ]
        }
        let inks: [(String, RGB)] = [
            ("primary", ink),
            ("secondaryText", secondaryText),
            ("accentText", accentText),
            ("dangerText", dangerText),
        ]
        var pairs = inks.flatMap { text in
            surfaces.map { TextPair(text: text.0, background: $0.0, textColor: text.1, backgroundColor: $0.1) }
        }
        // Words on the accent fill: the primary button, "Have a look", Send.
        pairs.append(TextPair(text: "onAccent", background: "accent", textColor: onAccentRGB, backgroundColor: accentRGB))
        for (name, base) in bases {
            let card = RGB.white.over(base, opacity: cardOpacity(scheme))
            // A mask such as [name] in the cloud preview's payload card.
            pairs.append(TextPair(text: "primary", background: "mask on the card on \(name)",
                                  textColor: ink, backgroundColor: accentRGB.over(card, opacity: maskWash(scheme))))
        }
        // White words a system control writes on its tint fill: the selected
        // sidebar row and a confirmation button (`DoneButton`).
        pairs.append(TextPair(text: "white", background: "tintFill", textColor: .white, backgroundColor: tintFill))
        // The sidebar's unchosen rows draw their icons in its tint, beside
        // words in the primary ink. An icon needs 3 to 1.
        for (name, base) in sidebarRGBs(scheme) {
            pairs.append(TextPair(text: "tintFill icon", background: name,
                                  textColor: tintFill, backgroundColor: base, minimum: 3))
        }
        // The composer, on Today and in the chat: its placeholder, and its
        // edge against the field and against what the field sits on (Today's
        // bar is the bottom of the backdrop).
        for (name, base) in bases {
            let field = ink.over(base, opacity: fieldTint)
            pairs.append(TextPair(text: "placeholder", background: "field on \(name)",
                                  textColor: secondaryText, backgroundColor: field))
            pairs.append(TextPair(text: "field edge", background: name,
                                  textColor: fieldEdge, backgroundColor: base, minimum: 3))
            pairs.append(TextPair(text: "field edge", background: "field on \(name)",
                                  textColor: fieldEdge, backgroundColor: field, minimum: 3))
        }
        return pairs
    }

    /// The system background a sheet opens on.
    static func sheetRGB(_ scheme: ColorScheme) -> RGB {
        scheme == .dark ? RGB(0.11, 0.11, 0.12) : .white
    }

    /// What the iPad sidebar can sit on: the system's plain and grouped
    /// backgrounds, the lightest and darkest it draws in each scheme.
    static func sidebarRGBs(_ scheme: ColorScheme) -> [(String, RGB)] {
        scheme == .dark
            ? [("sidebar", .black), ("sidebar, grouped", RGB(0.11, 0.11, 0.12))]
            : [("sidebar", .white), ("sidebar, grouped", RGB(0.95, 0.95, 0.97))]
    }

    /// A soft wash behind every screen. Adapts to light and dark.
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        let ends = backdropEnds(scheme)
        return LinearGradient(colors: [ends.top.color, ends.bottom.color], startPoint: .top, endPoint: .bottom)
    }

    /// The two ends of the backdrop, as numbers so contrast can be checked:
    /// a warm off-white settling into cream in light, and a warm charcoal in
    /// dark, never pure black across a whole screen.
    static func backdropEnds(_ scheme: ColorScheme) -> (top: Contrast.RGB, bottom: Contrast.RGB) {
        scheme == .dark
            ? (Contrast.RGB(0.14, 0.13, 0.12), Contrast.RGB(0.10, 0.095, 0.09))
            : (Contrast.RGB(0.99, 0.97, 0.94), Contrast.RGB(0.97, 0.95, 0.92))
    }

    /// How strongly the chat bubbles and the thinking bubble are tinted with
    /// the primary ink over the backdrop.
    static let bubbleTint = 0.06

    /// Card surface that reads well in light and dark: a lighter layer over
    /// the backdrop.
    static func card(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(cardOpacity(scheme))
    }

    /// How much white a card lays over what is behind it.
    static func cardOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.07 : 0.80
    }

    /// The thin edge around a card: a warm brown in light, white in dark,
    /// and a little firmer with Increase Contrast on.
    static func hairline(_ scheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        let strength = increasedContrast ? 2.5 : 1
        return scheme == .dark
            ? Color.white.opacity(0.10 * strength)
            : RGB(0.35, 0.24, 0.14).color.opacity(0.10 * strength)
    }

    /// The soft shadow under a raised or floating surface: warm and faint
    /// in light, deeper in dark where a shadow has less to show against.
    static func shadowColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.35) : RGB(0.35, 0.24, 0.14).color.opacity(0.08)
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
            .font(Theme.TypeScale.headline)
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
            .font(Theme.TypeScale.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText))
            .padding(.horizontal, Theme.Space.m)
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
            .font(Theme.TypeScale.subheadline.weight(.semibold))
            .foregroundStyle(!isEnabled ? AnyShapeStyle(Theme.secondaryText)
                             : neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Theme.accentText))
            .padding(.horizontal, Theme.Space.m)
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
            .font(Theme.TypeScale.subheadline.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

/// Done, for a sheet's toolbar, filled with `Theme.tintFill` and written in
/// white, where white reads at over 4.5 to 1. Its words are never drawn in
/// the tint itself.
///
/// It draws its own fill. Left to the system, iOS 26 draws a plain glass
/// capsule with the word in the tint, about 2 to 1 on a dark sheet; the
/// prominent glass style fills it but picks black words, about 3 to 1, and
/// ignores a foreground style; and the Mac draws it gray. `make
/// screenshots` takes the dark sheet and `scripts/check-screenshots.sh`
/// looks for the fill with white words on it.
/// Its toolbar item hides the shared background with
/// `.sharedBackgroundVisibility(.hidden)`, or iOS 26 draws a glass ring
/// around the fill.
/// `ContrastGuardTests` makes every confirmation button one of these.
struct DoneButton: View {
    var title = MemoryWords.doneTitle
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(FillButtonStyle())
            .keyboardShortcut(.cancelAction)
            .tint(Theme.tintFill)
    }
}

/// White words on a capsule of `Theme.tintFill`, for `DoneButton`. Not
/// ready yet, it goes quiet gray on a neutral fill, as the other buttons do.
///
/// A style of its own gets no focus ring and no pointer highlight from the
/// system, so it draws a ring of the fill around itself while the keyboard
/// is on it (Full Keyboard Access on the Mac, a hardware keyboard on iPad)
/// and takes the iPad pointer's highlight.
struct FillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        FocusRing {
            configuration.label
                .font(Theme.TypeScale.body.weight(.semibold))
                // Not ready yet, the same look as the other buttons: its
                // words and fill are the "disabled button" pairs in textPairs.
                .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.onTintFill) : AnyShapeStyle(Theme.secondaryText))
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 44)
                .background(isEnabled ? AnyShapeStyle(Theme.tintFill) : AnyShapeStyle(Color.primary.opacity(Theme.disabledTint)),
                            in: Capsule())
        }
        .contentShape(Capsule())
        .pointerHover(in: Capsule())
        .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A ring of `Theme.tintFill` around a capsule button while the keyboard is
/// on it. A view of its own inside the button, because `isFocused` read on
/// the style itself is resolved outside the button and stays false.
struct FocusRing<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @ViewBuilder let content: Content

    var body: some View {
        content.overlay {
            if isFocused {
                Capsule().strokeBorder(Theme.tintFill, lineWidth: 2).padding(-Theme.Space.xxs)
            }
        }
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
    func pointerHover(in shape: some Shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)) -> some View {
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

/// How far a surface sits above the backdrop.
///
/// - `flat`: a card layer resting on the page, with its thin edge.
/// - `raised`: the same layer lifted by a soft, warm shadow. Cards.
/// - `floating`: a layered material that lets what is under it glow
///   through, with a wider shadow, for something that hovers over
///   content.
///
/// With Reduce Transparency or Increase Contrast on, the shadows go, the
/// material becomes a solid card color, and the edge firms up, so every
/// surface is a plain shape with a clear boundary.
enum Elevation {
    case flat, raised, floating
}

struct ElevatedSurface<S: Shape>: ViewModifier {
    let level: Elevation
    let shape: S
    /// The edge's color, when it should say something, such as a card that
    /// asks; otherwise the hairline.
    var edge: Color?
    var edgeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var plain: Bool { reduceTransparency || contrast == .increased }

    func body(content: Content) -> some View {
        content
            .background { surface }
            .overlay(shape.stroke(edge ?? Theme.hairline(scheme, increasedContrast: contrast == .increased),
                                  lineWidth: edgeWidth))
    }

    @ViewBuilder private var surface: some View {
        switch level {
        case .flat:
            shape.fill(Theme.card(scheme))
        case .raised:
            shape.fill(Theme.card(scheme))
                .shadow(color: plain ? .clear : Theme.shadowColor(scheme), radius: Theme.Space.s, y: Theme.Space.xxs)
        case .floating:
            Group {
                if plain {
                    shape.fill(Theme.RGB.white.over(Theme.backdropEnds(scheme).top, opacity: Theme.cardOpacity(scheme)).color)
                } else {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(Theme.card(scheme).opacity(0.5)))
                }
            }
            .shadow(color: plain ? .clear : Theme.shadowColor(scheme), radius: Theme.Space.l, y: Theme.Space.xs)
        }
    }
}

extension View {
    /// Lays this view on a surface at `level`, in `shape`, with its edge.
    func elevation<S: Shape>(_ level: Elevation, in shape: S, edge: Color? = nil, edgeWidth: CGFloat = 1) -> some View {
        modifier(ElevatedSurface(level: level, shape: shape, edge: edge, edgeWidth: edgeWidth))
    }

    /// A card: raised, in the card's rounded corners.
    func cardSurface(_ level: Elevation = .raised, radius: CGFloat = Theme.Radius.card) -> some View {
        elevation(level, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
#endif
