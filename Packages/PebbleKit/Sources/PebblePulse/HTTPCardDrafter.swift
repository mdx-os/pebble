import Foundation
import PebbleCore

/// Sends the change text to an https endpoint the caller chose.
///
/// This is not the default. It runs only when `PULSE_CARD_DRAFTER=http` and
/// `PULSE_CARD_DRAFTER_URL` are both set. The key, if any, is `PULSE_CARD_DRAFTER_KEY`.
public struct HTTPCardDrafter: CardDrafting {
    public let name = "http"
    public var endpoint: URL
    public var bearerToken: String?
    public var transport: any HTTPSending

    public init(endpoint: URL, bearerToken: String?, transport: any HTTPSending) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.transport = transport
    }

    public func draft(modelInput: String) async -> [StealCard] {
        let input = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return [] }
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["modelInput": input])
            var headers = ["Content-Type": "application/json"]
            if let bearerToken, !bearerToken.isEmpty {
                headers["Authorization"] = "Bearer \(bearerToken)"
            }
            let response = try await transport.send(
                HTTPRequest(url: endpoint, method: "POST", headers: headers, body: payload)
            )
            guard (200..<300).contains(response.status) else { return [] }
            return cards(from: response.body)
        } catch {
            return []
        }
    }

    private func cards(from data: Data) -> [StealCard] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCards = json["cards"] as? [Any] else {
            return []
        }
        var cards: [StealCard] = []
        let decoder = JSONDecoder()
        for raw in rawCards {
            guard let object = raw as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: object),
                  let card = try? decoder.decode(StealCard.self, from: encoded) else {
                continue
            }
            cards.append(card)
        }
        return cards
    }
}
