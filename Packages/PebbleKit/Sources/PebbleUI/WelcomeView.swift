import PebbleCore
import SwiftUI

/// The first screen: the agent introduces itself.
public struct WelcomeView: View {
    let brand: Brand

    public init(brand: Brand) {
        self.brand = brand
    }

    public var body: some View {
        VStack(spacing: 28) {
            AvatarView(initial: WelcomeCopy.initial(for: brand))
            VStack(spacing: 12) {
                Text(WelcomeCopy.greeting(for: brand))
                    .font(.largeTitle.weight(.semibold))
                Text(WelcomeCopy.intro)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Words on the welcome screen, kept apart from layout so they can be tested.
public enum WelcomeCopy {
    public static func greeting(for brand: Brand) -> String {
        "Hi, I'm \(brand.name)."
    }

    public static func initial(for brand: Brand) -> String {
        String(brand.name.prefix(1)).uppercased()
    }

    public static let intro =
        "I'm new here. Soon I'll keep up with what's new in AI, get a little better every day, and tell you what changed."
}

struct AvatarView: View {
    let initial: String

    var body: some View {
        Circle()
            .fill(Color.orange.gradient)
            .frame(width: 112, height: 112)
            .overlay {
                Text(initial)
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    WelcomeView(brand: Brand(name: "Preview"))
}
