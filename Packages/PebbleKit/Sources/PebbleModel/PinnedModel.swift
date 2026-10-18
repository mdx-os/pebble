import Foundation

/// One file of a pinned model, as it must arrive: its name in the
/// repository, its exact size and its SHA-256.
public struct PinnedModelFile: Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let sha256: String

    public init(name: String, bytes: Int64, sha256: String) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// The one model the app offers to download: a public repository at a fixed
/// revision commit, and every file it fetches, with sizes and hashes. A file
/// that arrives with any other size or hash is thrown away.
public struct PinnedModel: Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let files: [PinnedModelFile]

    public init(repository: String, revision: String, files: [PinnedModelFile]) {
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The folder it is kept in. The revision is part of the name, so a new
    /// pin never takes an older download for itself.
    public var folderName: String {
        repository.replacingOccurrences(of: "/", with: "--") + "--" + revision
    }

    /// The fixed public address of one file at the pinned revision.
    public func url(for file: PinnedModelFile) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = ModelDownloadRequest.host
        parts.path = "/\(repository)/resolve/\(revision)/\(file.name)"
        guard let url = parts.url else { preconditionFailure("A pinned file must make an address") }
        return url
    }

    /// Every address the download may start from, and no other.
    public var urls: [URL] { files.map(url(for:)) }

    /// Qwen3 4B Instruct 2507, 4-bit MLX weights. Chosen over Gemma 4 E4B
    /// in a side-by-side run of the agent's own prompts: warmer and more to the
    /// point, under half the size, and about 26 tokens a second on
    /// iPhone 17e. The tokenizer and template files are all MLX needs to
    /// load it; the rest of the repository is not fetched.
    public static let qwen3_4B = PinnedModel(
        repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        files: [
            PinnedModelFile(name: "config.json", bytes: 938,
                            sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
            PinnedModelFile(name: "generation_config.json", bytes: 238,
                            sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
            PinnedModelFile(name: "tokenizer.json", bytes: 11_422_654,
                            sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            PinnedModelFile(name: "tokenizer_config.json", bytes: 5_440,
                            sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
            PinnedModelFile(name: "chat_template.jinja", bytes: 4_040,
                            sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
            PinnedModelFile(name: "model.safetensors", bytes: 2_263_022_417,
                            sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
        ]
    )

    /// The model the app downloads.
    public static let `default` = qwen3_4B
}

/// The shape of every download request: a plain GET with nothing of the
/// person's in it. No cookies, no credentials, no conversation, no device
/// or app identifier. The two headers set here are the same fixed words
/// for everyone, and they replace the system's own, which would name the
/// app, its build and the person's language.
public enum ModelDownloadRequest {
    public static let host = "huggingface.co"
    public static let userAgent = "model-download"
    public static let acceptLanguage = "en"
    public static let headers = ["User-Agent": userAgent, "Accept-Language": acceptLanguage]

    public static func make(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Where a download may be sent on from a pinned address: the large
    /// files are served from the hub's own file hosts. HTTPS only, and the
    /// request sent there is made again by `make`, so nothing is carried
    /// over.
    public static func allowsRedirect(to url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else {
            return false
        }
        return host == Self.host || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }
}
