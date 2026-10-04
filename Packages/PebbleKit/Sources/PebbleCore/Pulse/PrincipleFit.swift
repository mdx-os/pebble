import Foundation

/// How an idea sits with the three rules that decide whether to take it.
///
/// Each score is 0, 1, or 2. Zero means the idea conflicts and must be adapted
/// or rejected. One means it can be adapted. Two means it already fits.
public struct PrincipleFit: Sendable, Equatable, Codable {
    public var privacy: Int
    public var localFirst: Int
    public var openWeights: Int

    public init(privacy: Int, localFirst: Int, openWeights: Int) throws {
        try Self.check("privacy", privacy)
        try Self.check("localFirst", localFirst)
        try Self.check("openWeights", openWeights)
        self.privacy = privacy
        self.localFirst = localFirst
        self.openWeights = openWeights
    }

    /// A privacy score of 0 means adapt the idea or reject it.
    public var rejectsPrivacy: Bool { privacy == 0 }

    public func label(for score: Int) -> String {
        switch score {
        case 0: "0 (adapt or reject)"
        case 1: "1 (adapt)"
        case 2: "2 (fits)"
        default: "\(score)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            privacy: try container.decode(Int.self, forKey: .privacy),
            localFirst: try container.decode(Int.self, forKey: .localFirst),
            openWeights: try container.decode(Int.self, forKey: .openWeights)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privacy, forKey: .privacy)
        try container.encode(localFirst, forKey: .localFirst)
        try container.encode(openWeights, forKey: .openWeights)
    }

    private static func check(_ name: String, _ value: Int) throws {
        guard (0...2).contains(value) else {
            throw PulseError(message: "\(name) fit must be 0, 1, or 2.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case privacy
        case localFirst
        case openWeights
    }
}
