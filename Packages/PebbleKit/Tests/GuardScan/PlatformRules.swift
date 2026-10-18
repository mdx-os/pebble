import SwiftSyntax

/// The package's tests build for iOS too, so anything that exists only on
/// the Mac must sit where the `#if` around it holds only on the Mac. The
/// conditions are evaluated, not matched: `!os(macOS)`,
/// `os(macOS) || os(iOS)`, an `#else` and `targetEnvironment(macCatalyst)`
/// are no Mac gate, and `#if(os(macOS))` is one.
public enum PlatformGate {
    /// Foundation names that exist on iOS too. Every other `NS` name is
    /// taken for AppKit, so a new AppKit type is caught without anyone
    /// adding it to a list; a Foundation name the tests come to need is
    /// added here.
    public static let safeOnIOS: Set<String> = [
        "NSArray", "NSAttributedString", "NSCache", "NSCondition", "NSData", "NSDate", "NSDictionary",
        "NSError", "NSLocale", "NSLock", "NSMakeRange", "NSMutableAttributedString", "NSMutableString",
        "NSNotFound", "NSNull", "NSNumber", "NSObject", "NSPredicate", "NSRange", "NSRecursiveLock",
        "NSRegularExpression", "NSSet", "NSString", "NSTemporaryDirectory", "NSTextCheckingResult",
        "NSURL", "NSUUID",
    ]

    /// Mac-only names that don't start with `NS`: Foundation's process and
    /// host types and the distributed notification center.
    public static let macOnlyNames: Set<String> = ["Process", "Host", "DistributedNotificationCenter"]

    /// Modules that only the Mac has.
    public static let macOnlyModules: Set<String> = ["AppKit", "Cocoa", "Carbon", "OSAKit", "ScreenSaver"]

    public static let rules: [Rule] = [
        Rule("platform.nsName", nsName),
        Rule("platform.macOnlyName", macOnlyName),
        Rule("platform.macOnlyImport", macOnlyImport),
    ]

    public static func ungated(in source: SyntaxSource, file: String) -> [Finding] {
        rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    public static func ungated(in text: String, file: String = "") -> [Finding] {
        ungated(in: SyntaxSource(text), file: file)
    }

    /// True when `token` is in an `#if` condition itself, not in a branch.
    static func inCondition(_ token: TokenSyntax) -> Bool {
        var current = token.parent
        var child = Syntax(token)
        while let parent = current {
            if let clause = parent.as(IfConfigClauseSyntax.self), clause.condition?.id == child.id { return true }
            child = parent
            current = parent.parent
        }
        return false
    }

    static func identifiers(_ source: SyntaxSource, _ wanted: (String) -> Bool) -> [TokenSyntax] {
        source.tokens.filter { token in
            guard case .identifier(let name) = token.tokenKind, wanted(name), !inCondition(token) else { return false }
            return !source.context(of: token).isMacOnly
        }
    }

    /// Any `NS` name, such as `NSWindow` or `NSViewController`.
    @Sendable static func nsName(_ source: SyntaxSource, _ file: String) -> [Finding] {
        identifiers(source) { name in
            name.count > 2 && name.hasPrefix("NS") && name.dropFirst(2).first!.isUppercase && !safeOnIOS.contains(name)
        }.map { token in
            Finding("platform.nsName", at: token, in: source,
                    "\(token.text) is AppKit only; put it behind #if os(macOS), or add it to PlatformGate.safeOnIOS "
                        + "if it is Foundation and exists on iOS")
        }
    }

    @Sendable static func macOnlyName(_ source: SyntaxSource, _ file: String) -> [Finding] {
        identifiers(source, macOnlyNames.contains).map { token in
            Finding("platform.macOnlyName", at: token, in: source,
                    "\(token.text) exists only on the Mac; put it behind #if os(macOS)")
        }
    }

    /// `import AppKit`, in any of its forms, outside a Mac-only branch.
    @Sendable static func macOnlyImport(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(ImportDeclSyntax.self).compactMap { decl in
            guard let module = decl.path.first?.name.text, macOnlyModules.contains(module),
                  !source.context(of: decl).isMacOnly else { return nil }
            return Finding("platform.macOnlyImport", at: decl, in: source,
                           "import \(module) builds only on the Mac; put it behind #if os(macOS)")
        }
    }
}
