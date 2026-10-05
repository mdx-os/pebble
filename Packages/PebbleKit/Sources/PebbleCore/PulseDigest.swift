import Foundation

/// One competitor-watch run.
///
/// `modelInput` contains only sources whose text changed after normalization.
/// Ratings and relative dates are removed before that comparison, so a page
/// that merely got older does not show up here.
/// `ideaCards` are drafted from `modelInput` alone.
public struct PulseDigest: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var observations: [SourceObservation]
    public var modelInput: String
    public var ideaCards: [IdeaCard]

    public init(
        generatedAt: Date,
        observations: [SourceObservation],
        modelInput: String,
        ideaCards: [IdeaCard]
    ) {
        self.generatedAt = generatedAt
        self.observations = observations
        self.modelInput = modelInput
        self.ideaCards = ideaCards
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PulseDigest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PulseDigest.self, from: data)
    }
}

public struct SourceObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var outcome: Outcome
    public var detail: String?

    public enum Outcome: String, Codable, Sendable {
        case changed
        case unchanged
        case skipped
        case failed
    }

    public init(id: String, name: String, url: String, outcome: Outcome, detail: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.outcome = outcome
        self.detail = detail
    }
}

public struct ModelSection: Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var body: String

    public init(id: String, name: String, url: String, body: String) {
        self.id = id
        self.name = name
        self.url = url
        self.body = body
    }
}

public enum ModelInput {
    public static func assemble(_ sections: [ModelSection]) -> String {
        sections.map { section in
            """
            source: \(section.id)
            name: \(section.name)
            url: \(section.url)

            \(section.body)
            """
        }.joined(separator: "\n\n")
    }
}
