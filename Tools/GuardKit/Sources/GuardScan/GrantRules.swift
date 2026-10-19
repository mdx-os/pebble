import SwiftSyntax

/// Only the question sheet's answer may make a grant. `GrantIssuer` is the
/// one way to make one, so no file but its own and the sheet's may name it:
/// not Today, not the chat, not a task engine, not the showcase. A name in
/// backticks is the same name.
public enum GrantIssuerGate {
    /// Where `GrantIssuer` may be named, as paths under PebbleKit's Sources.
    public static let allowedFiles: Set<String> = ["PebbleCore/Grants.swift", "PebbleUI/ConfirmationSheet.swift"]

    public static let rules: [Rule] = [
        Rule("grant.issuerOutsideSheet", issuerOutsideSheet),
    ]

    public static func problems(in source: SyntaxSource, file: String) -> [Finding] {
        rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// `GrantIssuer` named in code, outside the two files allowed to.
    @Sendable static func issuerOutsideSheet(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard !allowedFiles.contains(file) else { return [] }
        return source.tokens.filter { $0.identifier != nil && SyntaxSource.name($0) == "GrantIssuer" }.map { token in
            Finding("grant.issuerOutsideSheet", at: token, in: source,
                    "only the question sheet's answer makes a grant; GrantIssuer belongs in "
                        + "PebbleUI/ConfirmationSheet.swift")
        }
    }
}
