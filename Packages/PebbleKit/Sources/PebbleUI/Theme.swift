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

    /// The warm accent used for primary actions.
    static let accent = Color(red: 0.96, green: 0.52, blue: 0.29)

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
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.85)
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet text button for secondary choices.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
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
