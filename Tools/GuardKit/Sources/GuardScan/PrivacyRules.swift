import SwiftSyntax

/// Source tripwires, not a proof about arbitrary Swift or runtime behavior.
/// Names include references, so aliases and explicit `.init` cannot hide an API.
/// Comments, strings, whitespace and backticks are handled by the Swift parser.
public enum PrivacyRules {
    public static let cloud = "Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift"
    public static let gate = "Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift"
    public static let gateTests = "Packages/PebbleKit/Tests/PebbleUITests/CloudHelpTests.swift"
    public static let speechHelper = "Packages/PebbleKit/Sources/" + SpeechGate.adapterFile

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
        "WebView", "WebPage", "MCSession", "MCBrowserViewController",
    ]
    /// Initializers that load a remote resource when given one by a URL label.
    static let remoteInitializers: Set<String> = [
        "NSImage", "AVPlayer", "XMLParser", "NSDictionary",
        "NSArray", "NSAttributedString", "AVURLAsset", "AVAsset", "NSXMLDocument",
    ]
    /// The labels that hand an initializer a URL to load.
    static let urlLabels: Set<String> = ["contentsOf", "url", "byReferencing"]
    public static func hasNetwork(_ source: SyntaxSource) -> Bool {
        !network(source, "").isEmpty
    }
    static func network(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != cloud else { return [] }
        var hits = matches(source, rule: "privacy.network", message: "network code outside the opt-in cloud client") {
            networkNames.contains($0) || ($0.hasPrefix("URLSession") && $0 != "URLSessionCloudTransport")
                || $0.hasPrefix("NSURLSession") || $0.hasPrefix("NIO") || $0.hasPrefix("CFHTTPMessage")
                || $0.hasPrefix("CFStream") || $0.hasPrefix("CFReadStream") || $0.hasPrefix("CFWriteStream")
                || $0.hasPrefix("CFSocket") || $0.hasPrefix("MCNearbyService")
        }
        // These initializers can load remote resources too, however this file
        // spells them. Require review even for an initializer reference,
        // whose eventual argument is not visible.
        let remoteTypes = aliases(of: remoteInitializers, in: source)
        for token in identifiers(source) where remoteTypes.contains(SyntaxSource.name(token)) {
            if let call = ancestor(token, FunctionCallExprSyntax.self),
               call.arguments.contains(where: { urlLabels.contains($0.label.map(SyntaxSource.name) ?? "") }) {
                hits.append(Finding("privacy.network", at: token, in: source, "network code outside the opt-in cloud client"))
            } else if let member = ancestor(token, MemberAccessExprSyntax.self), SyntaxSource.name(member.declName.baseName) == "init" {
                hits.append(Finding("privacy.network", at: token, in: source, "network code outside the opt-in cloud client"))
            }
        }
        return hits
    }

    static let readTypes: Set<String> = ["Data", "NSData", "String", "NSString"]
    /// URL's async readers, properties that fetch whatever the URL names.
    static let urlReaders: Set<String> = ["lines", "resourceBytes"]

    static func urlRead(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var hits: [Finding] = []
        let types = aliases(of: readTypes, in: source)
        let declared = typeNames(in: source)
        let plain = plainTypes(in: source)
        // Any initializer given a URL label, however its type is spelled:
        // `.init`, an alias of any case, `Self` or a module name. Methods
        // such as `append(contentsOf:)` read nothing. url: and byReferencing:
        // are network labels, so the cloud client and a plain type this file
        // makes may take them.
        for call in source.nodes(FunctionCallExprSyntax.self) where initializerCallee(call.calledExpression, declared) {
            let labels = Set(call.arguments.compactMap { $0.label.map(SyntaxSource.name) })
            guard labels.contains("contentsOf")
                    || (file != cloud && !labels.isDisjoint(with: urlLabels) && !plain.contains(calleeName(call.calledExpression))) else { continue }
            hits.append(Finding("privacy.urlRead", at: call, in: source, SyntaxSource.code(call)))
        }
        for member in source.nodes(MemberAccessExprSyntax.self) {
            let name = SyntaxSource.name(member.declName.baseName)
            if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id { continue }
            if name == "init", namesReadType(member.base, types)
                || member.declName.argumentNames?.arguments.contains(where: { urlLabels.contains(SyntaxSource.name($0.name)) }) == true {
                hits.append(Finding("privacy.urlRead", at: member, in: source, SyntaxSource.code(member)))
            } else if urlReaders.contains(name) {
                hits.append(Finding("privacy.urlRead", at: member, in: source, SyntaxSource.code(member)))
            }
        }
        for component in source.nodes(KeyPathPropertyComponentSyntax.self) where urlReaders.contains(SyntaxSource.name(component.declName.baseName)) {
            hits.append(Finding("privacy.urlRead", at: component, in: source, "\\." + SyntaxSource.code(component)))
        }
        // Inside an extension of URL, `lines` and `resourceBytes` alone are
        // self's, the same readers with `self.` left off.
        let urls = aliases(of: ["URL"], in: source)
        for reference in source.nodes(DeclReferenceExprSyntax.self) where urlReaders.contains(SyntaxSource.name(reference.baseName)) {
            if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id { continue }
            if let call = reference.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == reference.id { continue }
            guard let extended = ancestor(reference, ExtensionDeclSyntax.self), extendsURL(extended, urls) else { continue }
            hits.append(Finding("privacy.urlRead", at: reference, in: source, SyntaxSource.code(reference)))
        }
        // copyItem(at:to:) downloads when its source is not a file URL.
        for reference in source.nodes(DeclReferenceExprSyntax.self) where SyntaxSource.name(reference.baseName) == "copyItem" {
            var expression = ExprSyntax(reference)
            if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id { expression = ExprSyntax(member) }
            if let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id {
                guard call.arguments.contains(where: { $0.label.map(SyntaxSource.name) == "at" }) else { continue }
                hits.append(Finding("privacy.urlRead", at: call, in: source, SyntaxSource.code(call)))
            } else if reference.argumentNames?.arguments.first.map({ SyntaxSource.name($0.name) }) != "atPath" {
                hits.append(Finding("privacy.urlRead", at: expression, in: source, SyntaxSource.code(expression)))
            }
        }
        return hits
    }

    /// The read types and every alias this file gives them, as in
    /// `typealias Bytes = Data`. An alias in another file is not seen, but a
    /// call through it is, by `initializerCallee`.
    static func aliases(of types: Set<String>, in source: SyntaxSource) -> Set<String> {
        var found = types
        var grew = true
        while grew {
            grew = false
            for alias in source.nodes(TypeAliasDeclSyntax.self) where !found.contains(SyntaxSource.name(alias.name))
                && alias.initializer.value.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name).contains(where: found.contains) {
                found.insert(SyntaxSource.name(alias.name))
                grew = true
            }
        }
        return found
    }

    /// `Data.init`, `Bytes.init`, or `Self.init` inside `extension Data`.
    static func namesReadType(_ base: ExprSyntax?, _ types: Set<String>) -> Bool {
        guard let base else { return false }
        let names = base.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name)
        if names.contains(where: types.contains) { return true }
        guard names.contains("Self"), let extended = ancestor(base, ExtensionDeclSyntax.self) else { return false }
        return extended.extendedType.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name).contains(where: types.contains)
    }

    /// Every type name this file declares, aliases included, in any case.
    static func typeNames(in source: SyntaxSource) -> Set<String> {
        Set(source.nodes(TypeAliasDeclSyntax.self).map { SyntaxSource.name($0.name) })
            .union(source.nodes(AssociatedTypeDeclSyntax.self).map { SyntaxSource.name($0.name) })
            .union(plainTypes(in: source))
    }

    /// Types this file makes whose initializers are all written here: a
    /// struct, enum or actor, or a class that inherits from nothing. A
    /// subclass might inherit an initializer that loads its URL.
    static func plainTypes(in source: SyntaxSource) -> Set<String> {
        Set(source.nodes(StructDeclSyntax.self).map { SyntaxSource.name($0.name) })
            .union(source.nodes(EnumDeclSyntax.self).map { SyntaxSource.name($0.name) })
            .union(source.nodes(ActorDeclSyntax.self).map { SyntaxSource.name($0.name) })
            .union(source.nodes(ClassDeclSyntax.self).filter { $0.inheritanceClause == nil }.map { SyntaxSource.name($0.name) })
    }

    /// `extension URL`, `extension Foundation.URL` or an alias of it.
    static func extendsURL(_ extended: ExtensionDeclSyntax, _ urls: Set<String>) -> Bool {
        extended.extendedType.tokens(viewMode: .sourceAccurate).map(SyntaxSource.name).contains(where: urls.contains)
    }

    /// The type or member a call names, as in `T` for `T(...)` or `M.T<U>(...)`.
    static func calleeName(_ callee: ExprSyntax) -> String {
        var expression = callee
        if let generic = expression.as(GenericSpecializationExprSyntax.self) { expression = generic.expression }
        if let member = expression.as(MemberAccessExprSyntax.self) { return SyntaxSource.name(member.declName.baseName) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return SyntaxSource.name(reference.baseName) }
        return ""
    }

    /// Whether a call may be made to an initializer: `T(...)`, `T.init(...)`,
    /// `.init(...)`, `Self(...)`, `M.T(...)`, `T<U>(...)`, or a bare name,
    /// which may be an alias of any case from another file. Members named in
    /// lower case are methods unless this file declares that name as a type.
    /// A shape not read here counts.
    static func initializerCallee(_ callee: ExprSyntax, _ declared: Set<String>) -> Bool {
        var expression = callee
        if let generic = expression.as(GenericSpecializationExprSyntax.self) { expression = generic.expression }
        let name: String
        if let member = expression.as(MemberAccessExprSyntax.self) {
            name = SyntaxSource.name(member.declName.baseName)
        } else if expression.is(DeclReferenceExprSyntax.self) {
            return true // A bare name, of any case.
        } else {
            return true
        }
        return name == "init" || declared.contains(name) || name.first.map { $0.isUppercase || $0 == "_" } ?? true
    }

    /// Accept only the actual cloud argument of ModelChoice.model, never a
    /// nearby call, the local argument or code after the closure's closing brace.
    /// Only the body counts: a capture list runs when the closure is made,
    /// before consent is checked.
    static func inCloudClosure(_ token: TokenSyntax) -> Bool {
        var child = Syntax(token)
        var current = token.parent
        while let node = current {
            if let closure = node.as(ClosureExprSyntax.self), closure.statements.id == child.id {
                if let call = closure.parent?.as(FunctionCallExprSyntax.self),
                   SyntaxSource.code(call.calledExpression) == "ModelChoice.model",
                   call.trailingClosure?.id == closure.id { return true }
                if let argument = closure.parent?.as(LabeledExprSyntax.self),
                   argument.label.map(SyntaxSource.name) == "cloud",
                   let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
                   SyntaxSource.code(call.calledExpression) == "ModelChoice.model" { return true }
            }
            child = node
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

    /// Speech ships only in the voice adapter, `DeviceSpeech.swift`, never
    /// on a true assignment elsewhere in a file taken as permission to upload.
    /// The adapter is let by only while the speech guard finds nothing in it:
    /// every request made there asks for on-device recognition, set before
    /// it is used and never turned off (`SpeechGate`).
    static func speech(_ source: SyntaxSource, _ file: String) -> [Finding] {
        if file == speechHelper, SpeechGate.problems(in: source, file: SpeechGate.adapterFile).isEmpty { return [] }
        return identifiers(source).compactMap { token in
            let name = SyntaxSource.name(token)
            guard name.hasPrefix("SFSpeech") || name == "recognitionTask" else { return nil }
            return Finding("privacy.speech", at: token, in: source, "speech recognition outside the reviewed helper (requiresOnDeviceRecognition must be enforced there)")
        }
    }
    static func upload(_ source: SyntaxSource, _ file: String) -> [Finding] {
        matches(source, rule: "privacy.upload", message: "a system API that sends the person's data to Apple's servers") {
            $0 == "CLGeocoder" || $0 == "MKDirections" || $0.hasPrefix("MKLocalSearch") || $0.hasPrefix("MKLookAround")
                // The iCloud container: files put there sync to Apple's servers.
                || $0 == "forUbiquityContainerIdentifier" || $0 == "ubiquityIdentityToken"
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
