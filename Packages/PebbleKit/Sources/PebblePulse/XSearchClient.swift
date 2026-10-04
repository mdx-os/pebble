import Foundation
import PebbleCore

public enum XSearchResult: Sendable, Equatable {
    case skipped(String)
    case failed(String)
    case text(String)
}

public protocol XSearching: Sendable {
    func search(_ source: PulseSource, now: Date) async -> XSearchResult
}

/// Builds one X Search request. The key is not part of the body.
public enum XSearchRequest {
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!

    public static func make(source: PulseSource, now: Date) throws -> (body: Data, cap: Int) {
        guard source.kind == .xSearch else {
            throw PulseError(message: "Source \(source.id) is not an X search.")
        }
        try source.validate()
        let handles = try PulseSource.normalizedHandles(source.handles ?? [], id: source.id)
        let cap = try XSearchBudget(postCap: source.postCap ?? 0).postCap
        let fromDay = PulseTime.day(now, addingDays: -1)
        let toDay = PulseTime.day(now, addingDays: 0)
        let query = source.query ?? ""
        let prompt = """
        Search X for posts between \(fromDay) and \(toDay) inclusive.
        Topic: \(query)
        Only consider posts from these handles: \(handles.joined(separator: ", ")).
        Make one X search.
        Fetch at most \(cap) posts. Stop when you reach that number.
        For each post, give the handle, the date, the text, and the post URL.
        Do not analyze images or video.
        """
        let payload: [String: Any] = [
            "model": model,
            "input": [
                ["role": "user", "content": prompt],
            ],
            "tools": [
                [
                    "type": "x_search",
                    "allowed_x_handles": handles,
                    "from_date": fromDay,
                    "to_date": toDay,
                    "enable_image_understanding": false,
                    "enable_video_understanding": false,
                ],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return (body, cap)
    }
}

/// Reads an X Search response and drops it when the reported post count is over the cap.
public enum XSearchResponse {
    public static func interpret(data: Data, cap: Int) -> XSearchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(
                "X search returned unreadable JSON, so the post cap could not be checked. The result was discarded."
            )
        }
        let usage = json["usage"] as? [String: Any]
        let details = usage?["server_side_tool_usage_details"] as? [String: Any]
        guard let posts = intValue(details?["x_posts_fetched"]) else {
            return .failed(
                "X search response did not report x_posts_fetched, so the post cap could not be checked. The result was discarded."
            )
        }
        if posts > cap {
            return .failed("X search fetched \(posts) posts, over the cap of \(cap). The result was discarded.")
        }
        if let users = intValue(details?["x_users_fetched"]), users > XSearchBudget.hardCeiling {
            return .failed(
                "X search fetched \(users) profiles, over the cap of \(XSearchBudget.hardCeiling). The result was discarded."
            )
        }
        let text = extractText(json).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .failed("X search returned no text.")
        }
        let citations = extractCitations(json)
        var lines = [
            "posts fetched: \(posts)",
            "cap: \(cap)",
            "",
            text,
        ]
        if !citations.isEmpty {
            lines.append("")
            lines.append("citations:")
            lines.append(contentsOf: citations.map { "- \($0)" })
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func extractText(_ json: [String: Any]) -> String {
        var parts: [String] = []
        let output = json["output"] as? [Any] ?? []
        for item in output {
            guard let object = item as? [String: Any] else { continue }
            if let content = object["content"] as? [Any] {
                for part in content {
                    guard let piece = part as? [String: Any] else { continue }
                    if let text = piece["text"] as? String {
                        parts.append(text)
                    }
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractCitations(_ json: [String: Any]) -> [String] {
        var urls: [String] = []
        func add(_ value: String) {
            if (value.hasPrefix("https://") || value.hasPrefix("http://")), !urls.contains(value) {
                urls.append(value)
            }
        }
        if let citations = json["citations"] as? [Any] {
            for citation in citations {
                if let url = citation as? String { add(url) }
                if let object = citation as? [String: Any], let url = object["url"] as? String { add(url) }
            }
        }
        let output = json["output"] as? [Any] ?? []
        for item in output {
            guard let object = item as? [String: Any], let content = object["content"] as? [Any] else { continue }
            for part in content {
                guard let piece = part as? [String: Any], let annotations = piece["annotations"] as? [Any] else { continue }
                for annotation in annotations {
                    if let object = annotation as? [String: Any], let url = object["url"] as? String {
                        add(url)
                    }
                }
            }
        }
        return urls
    }
}

public struct XSearchClient: XSearching {
    public static let apiKeyEnvironment = "XAI_API_KEY"

    public var apiKey: String?
    public var transport: any HTTPSending
    public var endpoint: URL

    public init(
        apiKey: String?,
        transport: any HTTPSending = URLSessionHTTPSender(),
        endpoint: URL = XSearchRequest.endpoint
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
    }

    public func search(_ source: PulseSource, now: Date) async -> XSearchResult {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            return .skipped("X search skipped: \(Self.apiKeyEnvironment) is not set.")
        }
        do {
            let built = try XSearchRequest.make(source: source, now: now)
            let request = HTTPRequest(
                url: endpoint,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: built.body
            )
            let response = try await transport.send(request)
            if !(200..<300).contains(response.status) {
                return .failed("X search was rejected (HTTP \(response.status)).")
            }
            return XSearchResponse.interpret(data: response.body, cap: built.cap)
        } catch {
            let message = String(describing: error).replacingOccurrences(of: key, with: "[redacted]")
            return .failed("X search failed: \(message)")
        }
    }
}
