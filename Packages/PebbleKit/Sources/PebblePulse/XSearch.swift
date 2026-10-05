import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PebbleCore

public struct XSearchQuery: Sendable, Equatable {
    public var handles: [String]
    public var fromDay: String
    public var toDay: String

    public init(handles: [String], fromDay: String, toDay: String) {
        self.handles = handles
        self.fromDay = fromDay
        self.toDay = toDay
    }
}

public struct XSearchHit: Sendable, Equatable {
    public var postURLs: [URL]
    public var summary: String

    public init(postURLs: [URL], summary: String) {
        self.postURLs = postURLs
        self.summary = summary
    }
}

public protocol XSearching: Sendable {
    func search(_ query: XSearchQuery) async throws -> XSearchHit
}

/// X Search through the xAI responses API.
///
/// The tool has no numeric post limit, so this client asks for at most
/// `maxPosts` and `parse` keeps at most that many unique post URLs.
/// Nothing above the cap is returned.
public enum XSearchAPI {
    public static let maxPosts = 25
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!

    public static func cappedPostCount(_ requested: Int) -> Int {
        min(max(requested, 0), maxPosts)
    }

    public static func requestBody(_ query: XSearchQuery) throws -> Data {
        let cap = cappedPostCount(maxPosts)
        let handles = query.handles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
        let prompt = """
        Find posts about product launches, product changes, reviews, and complaints.
        Return at most \(cap) posts. Stop after \(cap) posts. Do not fetch whole threads.
        """
        let body = Request(
            model: model,
            input: [Request.Message(role: "user", content: prompt)],
            tools: [
                Request.Tool(
                    type: "x_search",
                    allowed_x_handles: handles,
                    from_date: query.fromDay,
                    to_date: query.toDay,
                    enable_image_understanding: false,
                    enable_video_understanding: false
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    public static func parse(_ data: Data) throws -> XSearchHit {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PulseFailure.unreadable("X Search")
        }
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "X Search failed."
            throw PulseFailure.api(String(message.prefix(200)))
        }

        var urls: [String] = []
        var texts: [String] = []
        if let citations = root["citations"] as? [String] {
            urls.append(contentsOf: citations)
        }
        if let output = root["output"] as? [Any] {
            collect(output, urls: &urls, texts: &texts)
        }

        var posts: [URL] = []
        var seen: Set<String> = []
        for raw in urls {
            guard isPost(raw), seen.insert(raw).inserted, let url = URL(string: raw) else { continue }
            posts.append(url)
            if posts.count == maxPosts { break }
        }
        return XSearchHit(postURLs: posts, summary: texts.joined(separator: "\n\n"))
    }

    private static func isPost(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        let allowed = host == "x.com" || host == "twitter.com" || host == "www.x.com" || host == "www.twitter.com"
        guard allowed else { return false }
        return url.path.split(separator: "/").contains("status")
    }

    private static func collect(_ value: Any, urls: inout [String], texts: inout [String]) {
        if let dict = value as? [String: Any] {
            if dict["type"] as? String == "output_text", let text = dict["text"] as? String {
                texts.append(text)
            }
            if let url = dict["url"] as? String { urls.append(url) }
            for child in dict.values { collect(child, urls: &urls, texts: &texts) }
        } else if let array = value as? [Any] {
            for child in array { collect(child, urls: &urls, texts: &texts) }
        }
    }

    private struct Request: Encodable {
        var model: String
        var input: [Message]
        var tools: [Tool]

        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct Tool: Encodable {
            var type: String
            var allowed_x_handles: [String]
            var from_date: String
            var to_date: String
            var enable_image_understanding: Bool
            var enable_video_understanding: Bool
        }
    }
}

public struct XAISearchClient: XSearching {
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func search(_ query: XSearchQuery) async throws -> XSearchHit {
        var request = URLRequest(url: XSearchAPI.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("pebble-pulse/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try XSearchAPI.requestBody(query)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PulseFailure.unreadable("X Search")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PulseFailure.badStatus(url: "X Search", status: http.statusCode)
        }
        return try XSearchAPI.parse(data)
    }
}

enum XPostDiff {
    static func snapshot(urls: [URL]) -> String {
        urls.map(\.absoluteString).sorted().joined(separator: "\n")
    }

    /// New post URLs only. A rewritten summary with the same posts is not a change.
    static func modelBody(previous: String?, snapshot: String, summary: String) -> String? {
        let newURLs = snapshot.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let old = Set((previous ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        let added = newURLs.filter { !old.contains($0) }
        guard !added.isEmpty else { return nil }
        var body = added.joined(separator: "\n")
        let clean = SnapshotText.normalize(summary)
        if !clean.isEmpty {
            body += "\n\n" + clean
        }
        return body
    }
}

enum PulseClock {
    static func day(_ date: Date) -> String {
        format(date)
    }

    static func previousDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let prior = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return format(prior)
    }

    private static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
