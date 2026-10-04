import Foundation
import PebbleCore

/// Turns the digest's model input into steal cards.
///
/// The only text this is allowed to read is the changes. Unchanged sources are
/// not in that string. The default drafter runs on device and calls nothing.
public protocol CardDrafting: Sendable {
    var name: String { get }
    func draft(modelInput: String) async -> [StealCard]
}

public struct CardDrafterChoice: Sendable {
    public var name: String
    public var drafter: any CardDrafting

    public init(name: String, drafter: any CardDrafting) {
        self.name = name
        self.drafter = drafter
    }
}

/// Picks the drafter. Local is the default, including when no key is set.
/// `PULSE_CARD_DRAFTER=http` plus `PULSE_CARD_DRAFTER_URL` sends the same text
/// to an https endpoint. A missing URL falls back to the local drafter.
public enum CardDrafters {
    public static func make(
        environment: [String: String],
        transport: (any HTTPSending)? = nil
    ) -> CardDrafterChoice {
        let mode = environment["PULSE_CARD_DRAFTER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mode == "http",
           let raw = environment["PULSE_CARD_DRAFTER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           url.scheme == "https" {
            let token = environment["PULSE_CARD_DRAFTER_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let drafter = HTTPCardDrafter(
                endpoint: url,
                bearerToken: (token?.isEmpty == false) ? token : nil,
                transport: transport ?? URLSessionHTTPSender()
            )
            return CardDrafterChoice(name: drafter.name, drafter: drafter)
        }
        let local = HeuristicCardDrafter()
        return CardDrafterChoice(name: local.name, drafter: local)
    }
}
