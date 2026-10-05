import Foundation

/// The product's public name.
///
/// It is set once, in `Config/Brand.xcconfig`, and reaches the app through the
/// `PebbleBrandName` Info.plist key. Code never spells the name itself, so a
/// rename is a config change.
public struct Brand: Sendable, Equatable {
    public static let infoKey = "PebbleBrandName"

    public let name: String

    public init(name: String) {
        self.name = name
    }

    /// Reads the brand from an Info.plist dictionary. Returns nil when the key
    /// is missing, blank, or still an unexpanded build setting like `$(BRAND_NAME)`.
    public init?(infoDictionary: [String: Any]?) {
        guard let raw = infoDictionary?[Self.infoKey] as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("$(") else { return nil }
        self.name = name
    }
}
