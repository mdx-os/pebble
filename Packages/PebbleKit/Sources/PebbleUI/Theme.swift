import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// Shared spacing, shapes and colors so every screen feels like one place.
enum Theme {
    static let corner: CGFloat = 20
    static let smallCorner: CGFloat = 14
    static let gutter: CGFloat = 24
    static let readableWidth: CGFloat = 560

    /// The warm accent used for primary actions.
    static let accent = Color(red: 0.96, green: 0.52, blue: 0.29)

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

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Theme.backdrop(scheme).ignoresSafeArea() }
}
#endif
