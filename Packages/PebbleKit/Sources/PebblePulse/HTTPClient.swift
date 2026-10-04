import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PebbleCore

public struct FetchedPage: Sendable, Equatable {
    public var url: URL
    public var status: Int
    public var contentType: String?
    public var body: String

    public init(url: URL, status: Int, contentType: String?, body: String) {
        self.url = url
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPSending: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionPageFetcher: PageFetching {
    public var session: URLSession
    public var userAgent: String

    public init(userAgent: String = "pebble-pulse/0.1", timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PulseError(message: "No HTTP response for \(url.absoluteString).")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw PulseError(message: "Page was not UTF-8: \(url.absoluteString).")
        }
        return FetchedPage(
            url: url,
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            body: body
        )
    }
}

public struct URLSessionHTTPSender: HTTPSending {
    public var session: URLSession

    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(status: status, body: data)
    }
}
