import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FetchedPage: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data
    public var mimeType: String?

    public init(statusCode: Int, body: Data, mimeType: String?) {
        self.statusCode = statusCode
        self.body = body
        self.mimeType = mimeType
    }
}

public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

public struct URLSessionPageClient: PageFetching {
    public init() {}

    public func fetch(_ url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("pebble-pulse/0.1", forHTTPHeaderField: "User-Agent")
        // Some docs hosts answer 404 when the client names text/markdown,
        // and return the Markdown anyway for a plain accept.
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PulseFailure.unreadable(url.absoluteString)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PulseFailure.badStatus(url: url.absoluteString, status: http.statusCode)
        }
        return FetchedPage(
            statusCode: http.statusCode,
            body: data,
            mimeType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }
}

public enum PulseFailure: Error, Equatable, CustomStringConvertible {
    case badStatus(url: String, status: Int)
    case unreadable(String)
    case api(String)

    public var description: String {
        switch self {
        case .badStatus(let url, let status):
            "\(url) returned \(status)."
        case .unreadable(let name):
            "\(name) could not be read."
        case .api(let message):
            message
        }
    }
}

enum PageText {
    static func plain(_ page: FetchedPage, url: URL) -> String {
        let raw = String(decoding: page.body, as: UTF8.self)
        let mime = page.mimeType?.lowercased() ?? ""
        if url.pathExtension == "md" || mime.contains("markdown") || mime.contains("text/plain") {
            return raw
        }
        if let article = NewsArticleText.extract(from: raw) {
            return article
        }
        if mime.contains("html") || raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return HTMLText.extract(raw)
        }
        return raw
    }
}
