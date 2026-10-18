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
    public init() {}

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

    public func fetch(_ request: URLRequest, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = FetchDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
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

/// One file's download. Moves the finished file to its place inside the
/// delegate call, before the system removes it.
private final class FetchDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            record(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            record(.success(()))
        } catch {
            record(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Void, Error>
        if let error {
            result = .failure(error)
        } else {
            // A redirect refused ends here with no file and no error.
            result = outcome ?? .failure(URLError(.badServerResponse))
        }
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    private func record(_ result: Result<Void, Error>) {
        lock.lock()
        outcome = result
        lock.unlock()
    }
}
