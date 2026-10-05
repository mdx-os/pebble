import Foundation

/// A feature worth considering from the competitor watch.
///
/// `pattern` is a behavior worth taking on. It does not name a brand and it
/// does not include anyone else's code.
public struct IdeaCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// What the change is, in plain words.
    public var summary: String
    public var sourceName: String
    public var sourceURL: URL
    /// The user problem this would answer.
    public var complaint: String
    public var pattern: String
    public var effort: IdeaEffort
    public var fit: IdeaFit

    public init(
        id: String,
        title: String,
        summary: String,
        sourceName: String,
        sourceURL: URL,
        complaint: String,
        pattern: String,
        effort: IdeaEffort,
        fit: IdeaFit
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.complaint = complaint
        self.pattern = pattern
        self.effort = effort
        self.fit = fit
    }
}

public enum IdeaEffort: String, Codable, Sendable, Equatable {
    case small
    case medium
    case large
}

/// How an idea sits with the product's rules.
///
/// `privacy` is 0 when the idea would send personal content off the device.
/// A 0 means adapt the idea or reject it.
public struct IdeaFit: Codable, Sendable, Equatable {
    public var privacy: Int
    public var localFirst: Int
    public var openWeights: Int

    public init(privacy: Int, localFirst: Int, openWeights: Int) {
        self.privacy = privacy
        self.localFirst = localFirst
        self.openWeights = openWeights
    }

    public var blocksOnPrivacy: Bool {
        privacy == 0
    }
}
