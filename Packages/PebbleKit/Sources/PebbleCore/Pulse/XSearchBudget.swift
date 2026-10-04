import Foundation

/// How many X posts one pulse run is allowed to fetch.
///
/// X Search bills about five dollars per 1,000 posts. The API has no server-side
/// maximum, so this ceiling is enforced here: a config cannot ask for more, and
/// a response that reports more posts is discarded.
public struct XSearchBudget: Sendable, Equatable {
    public static let hardCeiling = 25
    public static let dollarsPerThousandPosts = 5

    public var postCap: Int

    public init(postCap: Int) throws {
        guard (1...Self.hardCeiling).contains(postCap) else {
            throw PulseError(
                message: "X search post cap must be from 1 to \(Self.hardCeiling). "
                    + "\(Self.hardCeiling) posts cost about \(Self.estimatedCost(for: Self.hardCeiling)) dollars "
                    + "at \(Self.dollarsPerThousandPosts) dollars per 1,000 posts."
            )
        }
        self.postCap = postCap
    }

    /// Cost in dollars for `posts`, printed with three decimal places.
    /// Integer math, so 25 posts is "0.125" and 10 posts is "0.050".
    public static func estimatedCost(for posts: Int) -> String {
        let thousandths = posts * dollarsPerThousandPosts
        let whole = thousandths / 1000
        let fraction = thousandths % 1000
        return String(format: "%d.%03d", whole, fraction)
    }
}
