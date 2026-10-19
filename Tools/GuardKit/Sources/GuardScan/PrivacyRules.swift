import SwiftSyntax

/// Source tripwires, not a proof about arbitrary Swift or runtime behavior.
/// Names include references, so aliases and explicit `.init` cannot hide an API.
/// Comments, strings, whitespace and backticks are handled by the Swift parser.
public enum PrivacyRules {
    public static let cloud = "Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift"
    public static let gate = "Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift"
    public static let gateTests = "Packages/PebbleKit/Tests/PebbleUITests/CloudHelpTests.swift"
    public static let speechHelper = "Packages/PebbleKit/Sources/PebbleModel/OnDeviceSpeech.swift"

    public static let rules: [Rule] = [
        Rule("privacy.network", network),
        Rule("privacy.urlRead", urlRead),
        Rule("privacy.transport", transport),
        Rule("privacy.sessionFactory", sessionFactory),
        Rule("privacy.requiredReason", requiredReason),
        Rule("privacy.speech", speech),
        Rule("privacy.upload", upload),
        Rule("privacy.encryption", encryption),
        Rule("privacy.gateTests", gateTestsPresent),
    ]

    public static func findings(in source: SyntaxSource, file: String) -> [Finding] {
        rules.flatMap { $0.check(source, file) }
    }

    // Ignore literal content but retain identifiers inside interpolations.
    static func identifiers(_ source: SyntaxSource) -> [TokenSyntax] {
        source.tokens.filter { token in
            switch token.tokenKind {
            case .identifier, .keyword: true
            default: false
            }
        }
    }

    static func matches(_ source: SyntaxSource, rule: String, message: String,
                        where predicate: (String) -> Bool) -> [Finding] {
        identifiers(source).filter { predicate(SyntaxSource.name($0)) }
            .map { Finding(rule, at: $0, in: source, message) }
    }

    static let networkNames: Set<String> = [
        "URLRequest", "NSURLRequest", "NSMutableURLRequest", "NSURLConnection", "Network",
        "FoundationNetworking", "AsyncHTTPClient", "HTTPClient", "NWConnection", "NWListener",
        "NWBrowser", "NWPathMonitor", "NWEndpoint", "CFNetwork", "WKWebView", "SFSafariViewController",
        "ASWebAuthenticationSession", "socket", "connect", "sendto", "recvfrom", "getaddrinfo",
        "AsyncImage", "CKContainer", "NSUbiquitousKeyValueStore",
    ]
    public static func hasNetwork(_ source: SyntaxSource) -> Bool {
        !network(source, "").isEmpty
    }
    static func network(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != cloud else { return [] }
        var hits = matches(source, rule: "privacy.network", message: "network code outside the opt-in cloud client") {
            networkNames.contains($0) || ($0.hasPrefix("URLSession") && $0 != "URLSessionCloudTransport")
                || $0.hasPrefix("NSURLSession") || $0.hasPrefix("NIO") || $0.hasPrefix("CFHTTPMessage")
                || $0.hasPrefix("CFStream") || $0.hasPrefix("CFReadStream") || $0.hasPrefix("CFWriteStream")
        }
        // These initializers can load remote resources too. Require review even
        // for an initializer reference, whose eventual argument is not visible.
        for token in identifiers(source) where ["NSImage", "AVPlayer", "XMLParser", "NSDictionary"].contains(SyntaxSource.name(token)) {
            if let call = ancestor(token, FunctionCallExprSyntax.self),
               call.arguments.contains(where: { ["url", "contentsOf"].contains($0.label.map(SyntaxSource.name) ?? "") }) {
                hits.append(Finding("privacy.network", at: token, in: source, "network code outside the opt-in cloud client"))
            } else if let member = ancestor(token, MemberAccessExprSyntax.self), SyntaxSource.name(member.declName.baseName) == "init" {
                hits.append(Finding("privacy.network", at: token, in: source, "network code outside the opt-in cloud client"))
            }
        }
        return hits
    }

    static func urlRead(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var hits: [Finding] = []
        let types: Set<String> = ["Data", "NSData", "String", "NSString"]
        for call in source.nodes(FunctionCallExprSyntax.self) {
            let names = call.calledExpression.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name)
            if names.contains(where: types.contains), call.arguments.contains(where: { $0.label.map(SyntaxSource.name) == "contentsOf" }) {
                hits.append(Finding("privacy.urlRead", at: call, in: source, SyntaxSource.code(call)))
            }
        }
        for member in source.nodes(MemberAccessExprSyntax.self) where SyntaxSource.name(member.declName.baseName) == "init" {
            guard let base = member.base, base.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name).contains(where: types.contains) else { continue }
            if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id { continue }
            hits.append(Finding("privacy.urlRead", at: member, in: source, SyntaxSource.code(member)))
        }
        return hits
    }

    /// Accept only the actual cloud argument of ModelChoice.model, never a
    /// nearby call, the local argument or code after the closure's closing brace.
    static func inCloudClosure(_ token: TokenSyntax) -> Bool {
        var current = token.parent
        while let node = current {
            if let closure = node.as(ClosureExprSyntax.self) {
                if let call = closure.parent?.as(FunctionCallExprSyntax.self),
                   SyntaxSource.code(call.calledExpression) == "ModelChoice.model",
                   call.trailingClosure?.id == closure.id { return true }
                if let argument = closure.parent?.as(LabeledExprSyntax.self),
                   argument.label.map(SyntaxSource.name) == "cloud",
                   let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
                   SyntaxSource.code(call.calledExpression) == "ModelChoice.model" { return true }
            }
            current = node.parent
        }
        return false
    }

    static func transport(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != cloud else { return [] }
        return identifiers(source).compactMap { token in
            let name = SyntaxSource.name(token)
            guard ["URLSessionCloudTransport", "CloudModel", "makeTransport"].contains(name) else { return nil }
            // Pure preview helpers do not construct a client or transport.
            if name == "CloudModel", let reference = token.parent?.as(DeclReferenceExprSyntax.self),
               let member = reference.parent?.as(MemberAccessExprSyntax.self), member.base?.id == reference.id,
               ["preview", "url", "place"].contains(SyntaxSource.name(member.declName.baseName)) { return nil }
            if name == "makeTransport", file == gate {
                if token.parent?.is(IdentifierPatternSyntax.self) == true { return nil }
                // The injected factory is stored, never called or exposed here.
                if let sequence = ancestor(token, SequenceExprSyntax.self), SyntaxSource.code(sequence) == "self.makeTransport=transport" { return nil }
                if let infix = ancestor(token, InfixOperatorExprSyntax.self), SyntaxSource.code(infix) == "self.makeTransport=transport" { return nil }
            }
            guard file != gate || !inCloudClosure(token) else { return nil }
            return Finding("privacy.transport", at: token, in: source, file == gate
                ? "a transport is made outside ModelChoice.model's cloud closure"
                : "the cloud client is made outside the consent gate")
        }
    }

    static func sessionFactory(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file == cloud else { return [] }
        return source.nodes(FunctionDeclSyntax.self).filter {
            SyntaxSource.name($0.name) == "makeSession" && $0.modifiers.contains { ["public", "open", "package"].contains(SyntaxSource.name($0.name)) }
        }.map { Finding("privacy.sessionFactory", at: $0, in: source, "makeSession must be internal or private") }
    }

    public static let categoryNames: [String: Set<String>] = [
        "UserDefaults": ["UserDefaults", "NSUserDefaults", "AppStorage"],
        "FileTimestamp": ["creationDate", "modificationDate", "fileModificationDate", "fileCreationDate",
                          "contentModificationDate", "contentModificationDateKey", "creationDateKey", "attributesOfItem",
                          "getattrlist", "getattrlistbulk", "getattrlistat", "fgetattrlist", "setattrlist", "stat", "fstat", "fstatat", "lstat"],
        "SystemBootTime": ["systemUptime", "mach_absolute_time"],
        "DiskSpace": ["volumeAvailableCapacity", "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsage",
                      "volumeAvailableCapacityForImportantUsageKey", "volumeAvailableCapacityForOpportunisticUsage",
                      "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacity", "volumeTotalCapacityKey",
                      "systemFreeSize", "systemSize", "attributesOfFileSystem", "statfs", "statvfs", "fstatfs", "fstatvfs",
                      "getattrlist", "fgetattrlist", "getattrlistat"],
        "ActiveKeyboards": ["activeInputModes"],
    ]
    static func requiredReason(_ source: SyntaxSource, _ file: String) -> [Finding] {
        categoryNames.sorted { $0.key < $1.key }.flatMap { category, names in
            matches(source, rule: "privacy.requiredReason", message: "NSPrivacyAccessedAPICategory" + category, where: names.contains)
        }
    }

    /// Speech is not shipped today. Reserve one reviewed helper instead of
    /// treating a true assignment elsewhere in a file as permission to upload.
    /// Adding that helper requires review of its request construction and tests.
    static func speech(_ source: SyntaxSource, _ file: String) -> [Finding] {
        identifiers(source).compactMap { token in
            let name = SyntaxSource.name(token)
            guard name.hasPrefix("SFSpeech") || name == "recognitionTask" else { return nil }
            if file == speechHelper, let function = ancestor(token, FunctionDeclSyntax.self),
               SyntaxSource.name(function.name) == "recognizeOnDevice" { return nil }
            return Finding("privacy.speech", at: token, in: source, "speech recognition outside the reviewed helper (requiresOnDeviceRecognition must be enforced there)")
        }
    }
    static func upload(_ source: SyntaxSource, _ file: String) -> [Finding] {
        matches(source, rule: "privacy.upload", message: "a system API that sends the person's data to Apple's servers") {
            $0 == "CLGeocoder" || $0 == "MKDirections" || $0.hasPrefix("MKLocalSearch") || $0.hasPrefix("MKLookAround")
        }
    }
    static func encryption(_ source: SyntaxSource, _ file: String) -> [Finding] {
        matches(source, rule: "privacy.encryption", message: "encryption or certificate pinning needs a fresh export review") {
            ["CryptoKit", "CommonCrypto", "Crypto", "_CryptoExtras", "NIOSSL", "BoringSSL", "CNIOBoringSSL",
             "SecKeyCreateEncryptedData", "SecKeyEncrypt", "serverTrust", "SecTrustSetAnchorCertificates",
             "SecCertificateCopyData", "SecTrustCopyKey", "SecTrustCopyCertificateChain", "URLAuthenticationChallenge",
             "pinnedCertificates", "pinnedKeys", "pinnedDomains"].contains($0)
                || $0.hasPrefix("CCCrypt") || $0.hasPrefix("CCHmac") || $0.hasPrefix("CCKeyDerivation")
                || $0.hasPrefix("SecTrustEvaluate")
        }
    }
    static func gateTestsPresent(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file == gateTests else { return [] }
        return ["offByDefaultMakesNoTransportAndKeepsChatsOnDevice", "anEmptyAddressMeansDisabledEvenIfSavedOn"].compactMap { name in
            let found = source.nodes(FunctionDeclSyntax.self).contains { function in
                SyntaxSource.name(function.name) == name && function.attributes.contains {
                    $0.as(AttributeSyntax.self).map { SyntaxSource.code($0.attributeName) == "Test" } ?? false
                } && function.descendants(MacroExpansionExprSyntax.self).contains {
                    SyntaxSource.name($0.macroName) == "expect" && $0.arguments.first.map { SyntaxSource.code($0.expression) == "maker.made==0" } == true
                }
            }
            return found ? nil : Finding(rule: "privacy.gateTests", line: 1, column: 1, message: "must keep \(name), which expects maker.made == 0")
        }
    }
    static func ancestor<T: SyntaxProtocol>(_ node: some SyntaxProtocol, _ type: T.Type) -> T? {
        var current = node.parent
        while let parent = current {
            if let found = parent.as(type) { return found }
            current = parent.parent
        }
        return nil
    }
}
