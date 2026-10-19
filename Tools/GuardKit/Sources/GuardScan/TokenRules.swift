import SwiftSyntax

/// The design token guard: a screen's colors and type sizes come from
/// `Theme`, so a literal color or a fixed font size anywhere in PebbleUI
/// outside Theme.swift is a token that was skipped. Each call is read
/// through the tree, so a name in backticks is still the name, and the
/// words inside strings and comments are never code.
public enum TokenLint {
    /// The one file that may spell colors and sizes out: it defines them.
    public static let themeFile = "PebbleUI/Theme.swift"

    public static let rules: [Rule] = [
        Rule("token.literalColor", literalColor),
        Rule("token.fixedFont", fixedFont),
    ]

    public static func problems(in source: SyntaxSource, file: String) -> [Finding] {
        guard applies(to: file) else { return [] }
        return rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// PebbleUI's screens, Theme.swift aside.
    public static func applies(to file: String) -> Bool {
        file.hasPrefix("PebbleUI/") && file != themeFile
    }

    static func labels(_ call: FunctionCallExprSyntax) -> [String] {
        call.arguments.compactMap { $0.label.map(SyntaxSource.name) }
    }

    /// The type a call makes: `Color` in `Color(red:)`, `SwiftUI.Color(red:)`
    /// and `Color.init(red:)`.
    static func madeType(_ call: FunctionCallExprSyntax) -> String? {
        guard let called = SyntaxSource.calledName(call) else { return nil }
        if called == "init", let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base {
            return base.as(DeclReferenceExprSyntax.self).map { SyntaxSource.name($0.baseName) }
                ?? base.as(MemberAccessExprSyntax.self).map { SyntaxSource.name($0.declName.baseName) }
        }
        return called
    }

    /// A color made from numbers: `Color(red:green:blue:)`, `Color(hue:...)`,
    /// `Color(white:)`, and the same on `UIColor` and `NSColor`.
    @Sendable static func literalColor(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(FunctionCallExprSyntax.self).compactMap { call in
            guard let type = madeType(call), ["Color", "UIColor", "NSColor"].contains(type),
                  labels(call).contains(where: { ["red", "hue", "white"].contains($0) }) else { return nil }
            return Finding("token.literalColor", at: call.calledExpression, in: source,
                           "a literal color; add it to Theme and use the token")
        }
    }

    /// A font of a fixed size, which never grows with Dynamic Type:
    /// `.system(size:)`, `.custom(_:size:)` and `systemFont(ofSize:)`.
    @Sendable static func fixedFont(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["system", "custom", "systemFont", "monospacedSystemFont"]).compactMap { call in
            guard labels(call).contains(where: { ["size", "ofSize"].contains($0) }) else { return nil }
            return Finding("token.fixedFont", at: call.calledExpression, in: source,
                           "a fixed font size; use a Theme.TypeScale style so it grows with Dynamic Type")
        }
    }
}
