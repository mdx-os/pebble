import SwiftSyntax

/// The connectors read what the person keeps in other apps, such as their
/// calendar, and hand it on only as values in memory. So a connector's
/// source has no way out: it imports only what reading needs, names no
/// connection or address, keeps nothing in a file or the defaults, and
/// logs nothing. A name is caught wherever it is code, in any `#if`
/// branch, in backticks or behind a module's name, so a way out can't hide
/// in a branch the tests don't build.
public enum ConnectorGate {
    /// The modules a connector may import. Any other, the network's,
    /// logging's or one of this package's own layers, is a way out.
    public static let allowedModules: Set<String> = ["Foundation", "EventKit"]

    /// Names that reach past the app: connections, addresses, other processes.
    public static let networkNames: Set<String> = [
        "URL", "NSURL", "URLComponents", "URLRequest", "NSURLRequest", "URLSession", "URLSessionConfiguration",
        "URLSessionTask", "URLSessionDataTask", "URLSessionUploadTask", "URLSessionWebSocketTask", "NSURLConnection",
        "NWConnection", "NWListener", "NWBrowser", "NWEndpoint", "NWPathMonitor", "CFSocket", "CFStream",
        "CFSocketCreate", "Process", "NSTask", "NSXPCConnection", "DistributedNotificationCenter",
    ]

    /// Names that keep something: files, streams, the defaults, archives.
    public static let keepNames: Set<String> = [
        "FileManager", "FileHandle", "Stream", "InputStream", "OutputStream", "UserDefaults",
        "NSUbiquitousKeyValueStore", "NSKeyedArchiver", "write", "createFile", "createDirectory", "copyItem",
        "moveItem", "fopen", "fwrite", "fputs", "creat",
    ]

    /// Names that log.
    public static let logNames: Set<String> = [
        "print", "debugPrint", "dump", "NSLog", "os_log", "Logger", "OSLog", "os_signpost", "puts",
    ]

    public static let rules: [Rule] = [
        Rule("connector.import", importOutsideList),
        Rule("connector.network", network),
        Rule("connector.keep", keep),
        Rule("connector.log", log),
    ]

    public static func problems(in source: SyntaxSource, file: String) -> [Finding] {
        rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    public static func problems(in text: String, file: String = "") -> [Finding] {
        problems(in: SyntaxSource(text), file: file)
    }

    /// An `import` of anything outside `allowedModules`, in any of its forms.
    @Sendable static func importOutsideList(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(ImportDeclSyntax.self).compactMap { decl in
            guard let module = decl.path.first.map({ SyntaxSource.name($0.name) }),
                  !allowedModules.contains(module) else { return nil }
            return Finding("connector.import", at: decl, in: source,
                           "a connector imports only \(allowedModules.sorted().joined(separator: " and ")), "
                               + "and \(module) could carry what it reads away")
        }
    }

    static func named(_ source: SyntaxSource, _ names: Set<String>) -> [TokenSyntax] {
        source.tokens.filter { token in
            token.identifier != nil && names.contains(SyntaxSource.name(token))
        }
    }

    @Sendable static func network(_ source: SyntaxSource, _ file: String) -> [Finding] {
        named(source, networkNames).map { token in
            Finding("connector.network", at: token, in: source,
                    "\(SyntaxSource.name(token)) reaches past the app; a connector opens no connection")
        }
    }

    @Sendable static func keep(_ source: SyntaxSource, _ file: String) -> [Finding] {
        named(source, keepNames).map { token in
            Finding("connector.keep", at: token, in: source,
                    "\(SyntaxSource.name(token)) keeps something; a connector keeps nothing it reads")
        }
    }

    /// Each `.target(name: target, ...)` in a package manifest, with what
    /// its `dependencies` list holds as written, empty when it has none.
    public static func dependencies(ofTarget target: String, in manifest: SyntaxSource) -> [[String]] {
        manifest.nodes(FunctionCallExprSyntax.self).filter { call in
            call.calledExpression.as(MemberAccessExprSyntax.self).map { SyntaxSource.name($0.declName.baseName) }
                == "target"
                && call.arguments.contains { argument in
                    argument.label.map(SyntaxSource.name) == "name"
                        && argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue == target
                }
        }.map { call in
            let listed = call.arguments.first { $0.label.map(SyntaxSource.name) == "dependencies" }
            guard let listed else { return [] }
            guard let array = listed.expression.as(ArrayExprSyntax.self) else { return [listed.expression.trimmedDescription] }
            return array.elements.map(\.expression.trimmedDescription)
        }
    }

    @Sendable static func log(_ source: SyntaxSource, _ file: String) -> [Finding] {
        named(source, logNames).map { token in
            Finding("connector.log", at: token, in: source,
                    "\(SyntaxSource.name(token)) logs; a connector logs nothing it reads")
        }
    }
}
