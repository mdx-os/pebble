import Foundation

/// The model download's network code, and the only place in the app and
/// the model adapter allowed to name a network session.
/// `scripts/local-only-check.sh` allows it in this file, by exact path,
/// and fails anywhere else.
///
/// It fetches only what `ModelInstaller` hands it: the pinned file
/// addresses, shaped by `ModelDownloadRequest`. The session is ephemeral,
/// keeps no cookies, cache or credentials, and sends nothing else. A
/// redirect is followed only to the hub's own file hosts, as a fresh
/// request with the same fixed headers.
public struct URLSessionModelFetcher: ModelFetching {
    /// Handlers that answer before the network. Empty in the app; tests
    /// put their own here so nothing they fetch leaves the machine.
    let handlers: [URLProtocol.Type]

    public init() {
        handlers = []
    }

    init(handlers: [URLProtocol.Type]) {
        self.handlers = handlers
    }

    /// Ephemeral, with nothing kept and nothing added.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = nil
        configuration.waitsForConnectivity = false
        // A slow connection still finishes a 2 GB file.
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        return configuration
    }

    /// Writes the body to `destination` as it arrives, and stops as soon as
    /// the server says, or sends, more than `bytes`.
    public func fetch(_ request: URLRequest, to destination: URL, bytes: Int64,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let configuration = Self.configuration()
        if !handlers.isEmpty { configuration.protocolClasses = handlers }
        let delegate = FetchDelegate(destination: destination, limit: bytes, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

extension ModelInstaller {
    /// The installer the app uses, fetching over the network with
    /// `URLSessionModelFetcher`. Made here so nothing else names the session.
    public static func overNetwork(pin: PinnedModel = .default, folders: ModelFolders) -> ModelInstaller {
        ModelInstaller(pin: pin, folders: folders, fetcher: URLSessionModelFetcher())
    }
}

/// One file's download. Each piece is written as it arrives, and only
/// while the total stays inside the pinned size, so a body larger than
/// the pin never reaches the disk. Any failure removes the file.
private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?

    init(destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.limit = limit
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ModelDownloadRequest.allowsRedirect(to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(ModelDownloadRequest.make(url))
    }

    /// Refuses a status other than 200, or a stated length over the pin,
    /// before any of the body is taken.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            fail(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > limit {
            fail(URLError(.dataLengthExceedsMaximum))
            completionHandler(.cancel)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: destination)
            lock.lock()
            file = handle
            lock.unlock()
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard failure == nil, let file else {
            lock.unlock()
            return
        }
        guard received + Int64(data.count) <= limit else {
            lock.unlock()
            fail(URLError(.dataLengthExceedsMaximum))
            dataTask.cancel()
            return
        }
        do {
            try file.write(contentsOf: data)
            received += Int64(data.count)
            let total = received
            lock.unlock()
            progress(total)
        } catch {
            lock.unlock()
            fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? file?.close()
        file = nil
        let result: Result<Void, Error>
        if let failure {
            // Ours comes first: stopping the task reports a cancel of its own.
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if (task.response as? HTTPURLResponse)?.statusCode != 200 {
            // A redirect refused ends here with no body and no error.
            result = .failure(URLError(.badServerResponse))
        } else {
            result = .success(())
        }
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        waiting?.resume(with: result)
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        try? file?.close()
        file = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: destination)
    }
}
