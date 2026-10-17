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

    /// The warm accent used for primary actions.
    static let accent = Color(red: accentRGB.red, green: accentRGB.green, blue: accentRGB.blue)
    static let accentRGB = RGB(red: 0.96, green: 0.52, blue: 0.29)

    /// Small words on an accent fill. White there is too faint to read
    /// (about 2.5 to 1), so it is a deep brown of the same warmth, well over
    /// the 4.5 to 1 small text needs.
    static let onAccent = Color(red: onAccentRGB.red, green: onAccentRGB.green, blue: onAccentRGB.blue)
    static let onAccentRGB = RGB(red: 0.20, green: 0.10, blue: 0.04)

    /// An sRGB color by its parts, so contrast can be checked in tests.
    struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        /// Relative luminance, as WCAG defines it.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// The WCAG contrast ratio between two colors, from 1 to 21.
        func contrast(with other: RGB) -> Double {
            let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
            return (light + 0.05) / (dark + 0.05)
        }

        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    /// A soft wash behind every screen. Adapts to light and dark.
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        let top = scheme == .dark
            ? Color(red: 0.11, green: 0.10, blue: 0.12)
            : Color(red: 1.00, green: 0.97, blue: 0.94)
        let bottom = scheme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.08)
            : Color(red: 0.99, green: 0.99, blue: 0.98)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

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
            // Dark words on the accent read at about 6.4 to 1; white was 2.5.
            .foregroundStyle(Theme.onAccent)
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

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Theme.backdrop(scheme).ignoresSafeArea() }
}
#endif
