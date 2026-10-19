import SwiftSyntax

/// Only the question sheet's answer may make a grant. `GrantIssuer` is the
/// one way to make one, so no file but its own and the sheet's may name it:
/// not Today, not the chat, not a task engine, not the showcase. A name in
/// backticks is the same name.
///
/// The sheet's state makes a grant when its yes is tapped, so code could
/// also make one by building that state with somewhere to send grants,
/// picking a choice and tapping yes itself. Outside the sheet's own file,
/// `ConfirmationState` may be named only as a call with no `onGrant`: a yes
/// that counts once, as the showcase answers its sample questions. The one
/// exception is the showcase's `sampleGrants`, which fills an in-memory list
/// for the screenshots.
public enum GrantIssuerGate {
    /// Where `GrantIssuer` may be named, as paths under PebbleKit's Sources.
    public static let allowedFiles: Set<String> = ["PebbleCore/Grants.swift", "PebbleUI/ConfirmationSheet.swift"]

    /// Where the sheet's state is made, and may be given `onGrant`.
    public static let sheetFile = "PebbleUI/ConfirmationSheet.swift"

    /// Sample setup allowed to answer a granting sheet in code: the file and
    /// the function there.
    public static let sampleSetup = (file: "PebbleUI/ShowcaseScene.swift", function: "sampleGrants")

    public static let rules: [Rule] = [
        Rule("grant.issuerOutsideSheet", issuerOutsideSheet),
        Rule("grant.grantingStateOutsideSheet", grantingStateOutsideSheet),
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

    /// `ConfirmationState` named outside the sheet's file, other than as a
    /// call with no `onGrant`, and outside the showcase's sample setup.
    @Sendable static func grantingStateOutsideSheet(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != sheetFile else { return [] }
        return source.tokens.filter { token in
            token.identifier != nil && SyntaxSource.name(token) == "ConfirmationState"
                && !onceOnly(token) && !(file == sampleSetup.file && inFunction(sampleSetup.function, token))
        }.map { token in
            Finding("grant.grantingStateOutsideSheet", at: token, in: source,
                    "only a person's tap on the question sheet makes a grant; make ConfirmationState "
                        + "with onGrant only in PebbleUI/ConfirmationSheet.swift")
        }
    }

    /// True when `token` is the callee of a call, `ConfirmationState(...)`
    /// or `PebbleUI.ConfirmationState(...)`, that passes no `onGrant`.
    static func onceOnly(_ token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return false }
        var callee = Syntax(reference)
        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id {
            callee = Syntax(member)
        }
        guard let call = callee.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == callee.id else {
            return false
        }
        let labels = call.arguments.compactMap { $0.label.map(SyntaxSource.name) }
            + call.additionalTrailingClosures.map { SyntaxSource.name($0.label) }
        return !labels.contains("onGrant")
    }

    /// True when the innermost function around `token` is named `name`.
    static func inFunction(_ name: String, _ token: TokenSyntax) -> Bool {
        var current = token.parent
        while let node = current {
            if let function = node.as(FunctionDeclSyntax.self) { return SyntaxSource.name(function.name) == name }
            current = node.parent
        }
        return false
    }
}
