import SwiftSyntax

/// The privacy promise guard's rules. No word a person sees promises the
/// device unless `PrivacyPlace` decides it, and nothing lets the gate trust
/// anything but the model's own place.
public enum PromiseRules {
    /// Whether a literal chain that promises the device is allowed by a
    /// written reason: its words exactly as written, its file, and the first
    /// literal in it.
    public typealias Allows = (_ written: String, _ file: String, _ first: SyntaxSource.Literal, _ source: SyntaxSource) -> Bool

    /// The only receivers the gate reads `.staysOnDevice` from.
    public static let receivers: Set<String> = ["place", "self.place", "privacyPlace", "model.privacyPlace"]

    /// The only files that make a `LocalStubModel`: the app, which wires it
    /// in as the model, the Debug showcase, and the stub itself.
    public static let stubMakers: Set<String> = [
        "App/Sources/PebbleApp.swift",
        "PebbleUI/ShowcaseScene.swift",
        "PebbleModel/LocalStubModel.swift",
    ]

    /// The only files that may make a type a `ModelClient`. Any model says
    /// `runsOnDevice`, and the gate trusts the place made from it, so a
    /// screen with a model of its own could claim the device with no real
    /// model behind it. A new adapter is added here on purpose.
    public static let modelMakers: Set<String> = [
        "PebbleModel/ModelClient.swift",
        "PebbleModel/LocalStubModel.swift",
        "PebbleModel/CloudModel.swift",
    ]

    static let placeFile = "PebbleCore/PrivacyPlace.swift"
    static let modelFile = "PebbleModel/ModelClient.swift"

    /// Everything `PrivacyPlace.swift` may declare. The file is exempt from
    /// the `.onDevice` reads, so any other member there, a static, an init,
    /// a factory or a nested type's, could hand out a place with no model
    /// behind it under a name nothing else checks. A new one is added here
    /// on purpose, once the guard has learned its form.
    public static let placeMembers: Set<String> = [
        "enum PrivacyPlace",
        "case onDevice",
        "case mayLeaveDevice",
        "init(staysOnDevice:)",
        "var staysOnDevice",
        "func all(_:_:)",
    ]

    // MARK: The words

    /// True when `literal` shows only while the flag says so: it is the
    /// true branch of a ternary, alone or in a `+` chain, whose whole
    /// condition is `.staysOnDevice` read from one of `receivers`, grouping
    /// parens aside. The tree is folded, so `isRemote || place.staysOnDevice`,
    /// `!place.staysOnDevice`, `f(place.staysOnDevice)` and
    /// `other.place.staysOnDevice` are never the flag itself.
    public static func isGated(_ literal: SyntaxSource.Literal, in source: SyntaxSource) -> Bool {
        guard let ternary = source.ternary(showing: literal) else { return false }
        let condition = SyntaxSource.unparenthesized(ternary.condition)
        guard let member = condition.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "staysOnDevice",
              member.declName.argumentNames == nil, let base = member.base else { return false }
        return receivers.contains(SyntaxSource.code(base))
    }

    /// Every literal chain that promises the device, neither gated nor
    /// allowed. A chain is read as one line, gated by its first literal,
    /// and allowed only as its whole written text.
    public static func ungated(in source: SyntaxSource, file: String, allows: Allows) -> [Finding] {
        var found: [Finding] = []
        for chain in source.chains {
            let value = chain.map(\.value).joined()
            let phrases = PromisePhrases.found(in: value)
            guard !phrases.isEmpty, let first = chain.first else { continue }
            if isGated(first, in: source) { continue }
            if allows(chain.map(\.written).joined(), file, first, source) { continue }
            found.append(Finding(rule: "promise.phrase", line: first.line, column: first.column,
                                 message: "\"\(chain.map(\.written).joined())\" promises \(phrases) without PrivacyPlace"))
        }
        return found
    }

    /// The name of the binding whose value is an array literal holding
    /// `literal` as one of its elements, as `symbols` in
    /// `private static let symbols = ["cloud", "eye"]`.
    public static func listName(holding literal: SyntaxSource.Literal) -> String? {
        guard let element = literal.node.parent?.as(ArrayElementSyntax.self),
              let array = element.parent?.parent?.as(ArrayExprSyntax.self),
              let binding = array.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let name = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        return name.identifier.text
    }

    // MARK: The place

    /// The rules that keep the gate's flag the model's own.
    public static let placeRules: [Rule] = [
        Rule("promise.staysOnDeviceDeclared", staysOnDeviceDeclared),
        Rule("promise.placeWritten", placeWritten),
        Rule("promise.placeAlias", placeAlias),
        Rule("promise.emptyAll", emptyAll),
        Rule("promise.placeMade", placeMade),
        Rule("promise.stubMade", stubMade),
        Rule("promise.onDeviceBool", onDeviceBool),
        Rule("promise.dynamicLookup", dynamicLookup),
    ]

    public static func placeProblems(in source: SyntaxSource, file: String) -> [Finding] {
        placeRules.flatMap { $0.check(source, file) }
    }

    /// `staysOnDevice` is declared only in `PrivacyPlace.swift`, so a
    /// `place.staysOnDevice` that compiles is read from a `PrivacyPlace`.
    /// Elsewhere the word is only a member read (`.staysOnDevice`, or
    /// `\.staysOnDevice`) or the label of `PrivacyPlace(staysOnDevice:`:
    /// never a property, function, case, parameter, tuple label or name.
    @Sendable static func staysOnDeviceDeclared(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != placeFile else { return [] }
        return source.tokens.compactMap { token -> Finding? in
            guard case .identifier("staysOnDevice") = token.tokenKind else { return nil }
            if let reference = token.parent?.as(DeclReferenceExprSyntax.self) {
                if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id {
                    return nil
                }
                if reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true { return nil }
            }
            if let argument = token.parent?.as(LabeledExprSyntax.self), argument.label?.id == token.id,
               let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "PrivacyPlace"
                || call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "PrivacyPlace" {
                return nil
            }
            return Finding("promise.staysOnDeviceDeclared", at: token, in: source,
                           "staysOnDevice is declared only on PrivacyPlace, so the gate can trust it")
        }
    }

    /// The place itself, written out. Only the model decides it, so a
    /// screen never says `.onDevice` of its own accord, whatever is before
    /// the dot: a type alias of the place, its metatype or `type(of:)`
    /// reach the same case. A parameter or a binding typed `PrivacyPlace`
    /// may default to `.mayLeaveDevice`, which promises nothing, and the
    /// cloud adapter, a model itself, may say `.mayLeaveDevice` of its own
    /// words. Neither may ever say `.onDevice`.
    @Sendable static func placeWritten(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != placeFile, file != modelFile else { return [] }
        return source.nodes(MemberAccessExprSyntax.self).compactMap { member -> Finding? in
            let name = member.declName.baseName.text
            guard name == "onDevice" || name == "mayLeaveDevice" else { return nil }
            if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id { return nil }
            if name == "mayLeaveDevice" {
                if file == "PebbleModel/CloudModel.swift" { return nil }
                let initializer = SyntaxSource.climbParens(Syntax(member)).parent?.as(InitializerClauseSyntax.self)
                if let parameter = initializer?.parent?.as(FunctionParameterSyntax.self),
                   SyntaxSource.code(parameter.type) == "PrivacyPlace" {
                    return nil
                }
                if let binding = initializer?.parent?.as(PatternBindingSyntax.self),
                   binding.typeAnnotation.map({ SyntaxSource.code($0.type) }) == "PrivacyPlace" {
                    return nil
                }
            }
            return Finding("promise.placeWritten", at: member, in: source,
                           "\(SyntaxSource.code(member)) is decided only by the model, as model.privacyPlace")
        }
    }

    /// Another name for the place hides it from the reads above.
    @Sendable static func placeAlias(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != placeFile, file != modelFile else { return [] }
        return source.nodes(TypeAliasDeclSyntax.self).compactMap { alias in
            names(alias.initializer.value, "PrivacyPlace")
                ? Finding("promise.placeAlias", at: alias, in: source,
                          "typealias = \(SyntaxSource.code(alias.initializer.value)) is another name for PrivacyPlace, "
                            + "so its cases could be written unseen")
                : nil
        }
    }

    /// `all()` of no places at all would be `.onDevice` with no model
    /// behind it. Its signature needs one place; this keeps it so.
    @Sendable static func emptyAll(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(FunctionCallExprSyntax.self).compactMap { call in
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "all",
                  call.arguments.isEmpty, call.trailingClosure == nil else { return nil }
            let base = member.base.map(SyntaxSource.code)
            guard base == nil || ["PrivacyPlace", "PebbleCore.PrivacyPlace", "Self"].contains(base!) else { return nil }
            return Finding("promise.emptyAll", at: call, in: source,
                           "PrivacyPlace.all() of no places promises the device with no model behind it")
        }
    }

    /// `PrivacyPlace(staysOnDevice:` is made only in `ModelClient.swift`,
    /// from `runsOnDevice`, so a place is never built from a turned Bool.
    @Sendable static func placeMade(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(FunctionCallExprSyntax.self).compactMap { call in
            guard ["PrivacyPlace", "init"].contains(SyntaxSource.calledName(call)) else { return nil }
            let called = SyntaxSource.code(call.calledExpression)
            let makesPlace = called == "PrivacyPlace" || called.hasSuffix(".PrivacyPlace")
                || called == "PrivacyPlace.init" || called.hasSuffix(".PrivacyPlace.init") || called == ".init"
            guard makesPlace, call.arguments.contains(where: { $0.label?.text == "staysOnDevice" }) else { return nil }
            let arguments = SyntaxSource.code(call.arguments)
            if file == modelFile, called == "PrivacyPlace", arguments == "staysOnDevice:runsOnDevice" { return nil }
            return Finding("promise.placeMade", at: call, in: source,
                           "\(called)(\(arguments)) is made only by ModelClient, from runsOnDevice")
        }
    }

    /// A stand-in model, made anywhere, would be a model whose place is
    /// `.onDevice` with no real model behind it, so a screen could make the
    /// device promise from `LocalStubModel().privacyPlace`. It is made only
    /// by `stubMakers` and inside a `#Preview`'s own braces, which no person
    /// sees.
    @Sendable static func stubMade(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard !stubMakers.contains(file) else { return [] }
        return source.nodes(DeclReferenceExprSyntax.self).compactMap { reference in
            guard reference.baseName.text == "LocalStubModel" else { return nil }
            let called = reference.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == reference.id
            let member = reference.parent?.as(MemberAccessExprSyntax.self)
            let initialized = member?.base?.id == reference.id && member?.declName.baseName.text == "init"
            guard called || initialized, !source.context(of: reference).inPreview else { return nil }
            return Finding("promise.stubMade", at: reference, in: source,
                           "LocalStubModel() is made only by the app's wiring and the showcase, "
                            + "so no screen takes its place without the real model")
        }
    }

    /// A Bool called `onDevice`, kept, computed, passed or set, must come
    /// straight from `.staysOnDevice`, with no `!`: `let onDevice =
    /// !place.staysOnDevice` would turn the promise around. Its parameter
    /// form is never allowed, since nothing ties a caller's value to the flag.
    @Sendable static func onDeviceBool(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var found: [Finding] = []
        func flag(_ node: some SyntaxProtocol, _ value: String) {
            found.append(Finding("promise.onDeviceBool", at: node, in: source,
                                 "onDevice gets \"\(value)\", not .staysOnDevice straight from a PrivacyPlace"))
        }
        for binding in source.nodes(PatternBindingSyntax.self) {
            guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "onDevice" else { continue }
            if let value = binding.initializer?.value {
                if !isStraight(value) { flag(binding, SyntaxSource.code(value)) }
            } else if let accessors = binding.accessorBlock {
                if !isStraightBody(accessors) { flag(binding, SyntaxSource.code(accessors)) }
            } else {
                flag(binding, "nothing yet")
            }
        }
        for function in source.nodes(FunctionDeclSyntax.self) where function.name.text == "onDevice" {
            guard let returns = function.signature.returnClause.map({ SyntaxSource.code($0.type) }), returns == "Bool" else {
                continue
            }
            let items = function.body?.statements
            if items?.count != 1 || !(items.flatMap { single($0) }.map(isStraight) ?? false) {
                flag(function, SyntaxSource.code(function.body ?? CodeBlockSyntax(statements: [])))
            }
        }
        for parameter in source.nodes(FunctionParameterSyntax.self)
        where parameter.firstName.text == "onDevice" || parameter.secondName?.text == "onDevice" {
            flag(parameter, SyntaxSource.code(parameter.type) + (parameter.defaultValue.map { " " + SyntaxSource.code($0) } ?? ""))
        }
        for argument in source.nodes(LabeledExprSyntax.self) where argument.label?.text == "onDevice" {
            if !isStraight(argument.expression) { flag(argument, SyntaxSource.code(argument.expression)) }
        }
        for infix in source.nodes(InfixOperatorExprSyntax.self) where infix.operator.is(AssignmentExprSyntax.self) {
            let target = SyntaxSource.code(infix.leftOperand)
            if target == "onDevice" || target == "self.onDevice", !isStraight(infix.rightOperand) {
                flag(infix, SyntaxSource.code(infix.rightOperand))
            }
        }
        return found
    }

    /// `@dynamicMemberLookup` lets a type answer `.staysOnDevice` without
    /// declaring it, which the declared-only rule could never see, so a
    /// `place` of that type would pass the gate.
    @Sendable static func dynamicLookup(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(AttributeSyntax.self).compactMap { attribute in
            SyntaxSource.code(attribute.attributeName) == "dynamicMemberLookup"
                ? Finding("promise.dynamicLookup", at: attribute, in: source,
                          "a @dynamicMemberLookup type could answer .staysOnDevice without declaring it, so the gate "
                            + "could trust it")
                : nil
        }
    }

    /// `x.staysOnDevice`, `self.place.staysOnDevice` or `staysOnDevice`,
    /// read straight through names, grouping parens aside.
    static func isStraight(_ expression: ExprSyntax) -> Bool {
        let inner = SyntaxSource.unparenthesized(expression)
        if let reference = inner.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == "staysOnDevice" }
        guard let member = inner.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "staysOnDevice",
              var base = member.base else { return false }
        while true {
            if base.is(DeclReferenceExprSyntax.self) { return true }
            guard let next = base.as(MemberAccessExprSyntax.self)?.base else { return false }
            base = next
        }
    }

    static func single(_ items: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard items.count == 1, let item = items.first?.item else { return nil }
        if let expression = item.as(ExprSyntax.self) { return expression }
        if let statement = item.as(ReturnStmtSyntax.self) { return statement.expression }
        if let statement = item.as(ExpressionStmtSyntax.self) { return statement.expression }
        return nil
    }

    static func isStraightBody(_ block: AccessorBlockSyntax) -> Bool {
        switch block.accessors {
        case .getter(let items):
            return single(items).map(isStraight) ?? false
        case .accessors(let list):
            return list.count == 1 && list.first?.accessorSpecifier.text == "get"
                && (list.first?.body.flatMap { single($0.statements) }.map(isStraight) ?? false)
        }
    }

    /// True when `node` names `type`, alone or as part of a tuple,
    /// composition, array, optional or qualified name.
    static func names(_ node: some SyntaxProtocol, _ type: String) -> Bool {
        node.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .identifier(type) }
    }

    // MARK: The model

    /// The type declarations and extensions in `source` that list
    /// `ModelClient` among what they conform to, with their kind and name.
    public static func conformances(in source: SyntaxSource) -> [(node: Syntax, kind: String, name: String, modifiers: [String])] {
        var found: [(Syntax, String, String, [String])] = []
        func add(_ node: some DeclSyntaxProtocol, _ kind: String, _ name: String, _ inheritance: InheritanceClauseSyntax?,
                 _ modifiers: DeclModifierListSyntax) {
            guard let inheritance, names(inheritance, "ModelClient") else { return }
            found.append((Syntax(node), kind, name, modifiers.map { $0.name.text }))
        }
        for decl in source.nodes(StructDeclSyntax.self) {
            add(decl, "struct", decl.name.text, decl.inheritanceClause, decl.modifiers)
        }
        for decl in source.nodes(ClassDeclSyntax.self) {
            add(decl, "class", decl.name.text, decl.inheritanceClause, decl.modifiers)
        }
        for decl in source.nodes(ActorDeclSyntax.self) {
            add(decl, "actor", decl.name.text, decl.inheritanceClause, decl.modifiers)
        }
        for decl in source.nodes(EnumDeclSyntax.self) {
            add(decl, "enum", decl.name.text, decl.inheritanceClause, decl.modifiers)
        }
        for decl in source.nodes(ProtocolDeclSyntax.self) {
            add(decl, "protocol", decl.name.text, decl.inheritanceClause, decl.modifiers)
        }
        for decl in source.nodes(ExtensionDeclSyntax.self) {
            add(decl, "extension", SyntaxSource.code(decl.extendedType), decl.inheritanceClause, decl.modifiers)
        }
        return found.sorted { $0.0.position < $1.0.position }
    }

    public static let modelRules: [Rule] = [
        Rule("promise.modelMade", modelMade),
        Rule("promise.modelAlias", modelAlias),
    ]

    /// Each type in `source` made a `ModelClient` outside `modelMakers`, and
    /// every other name for it.
    public static func modelProblems(in source: SyntaxSource, file: String) -> [Finding] {
        modelRules.flatMap { $0.check(source, file) }
    }

    /// A struct, class, actor, enum or protocol that lists `ModelClient`,
    /// an extension that adds it, or an extension of `ModelClient` itself,
    /// which could say `runsOnDevice` for every model.
    @Sendable static func modelMade(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard !modelMakers.contains(file) else { return [] }
        let message = "only \(modelMakers.sorted().joined(separator: ", ")) may make a ModelClient"
        var found = conformances(in: source).map { Finding("promise.modelMade", at: $0.node, in: source, message) }
        for decl in source.nodes(ExtensionDeclSyntax.self)
        where ["ModelClient", "PebbleModel.ModelClient"].contains(SyntaxSource.code(decl.extendedType)) {
            found.append(Finding("promise.modelMade", at: decl, in: source, message))
        }
        return found
    }

    @Sendable static func modelAlias(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard !modelMakers.contains(file) else { return [] }
        return source.nodes(TypeAliasDeclSyntax.self).compactMap { alias in
            names(alias.initializer.value, "ModelClient")
                ? Finding("promise.modelAlias", at: alias, in: source,
                          "typealias = \(SyntaxSource.code(alias.initializer.value)) names ModelClient, "
                            + "so a type could conform to it without saying so")
                : nil
        }
    }

    /// Each type in a model maker's `source` that is a `ModelClient` must
    /// be a struct, enum, actor or final class, written in its own
    /// declaration. A class open to subclassing would hand its
    /// `runsOnDevice` to any subclass anywhere, and a protocol that refines
    /// `ModelClient` would let any type conform without naming it.
    @Sendable public static func makerKindProblems(in source: SyntaxSource, file: String) -> [Finding] {
        conformances(in: source).compactMap { decl in
            let rule = "promise.makerKind"
            switch decl.kind {
            case "class" where !decl.modifiers.contains("final") || decl.modifiers.contains("open"):
                return Finding(rule, at: decl.node, in: source,
                               "\(decl.name) is a class open to subclassing, so a subclass anywhere is a ModelClient too")
            case "protocol":
                return Finding(rule, at: decl.node, in: source,
                               "\(decl.name) refines ModelClient, so a type could conform to it without saying so")
            case "extension":
                return Finding(rule, at: decl.node, in: source,
                               "\(decl.name) gets ModelClient in an extension; say it where the type is declared")
            default:
                return nil
            }
        }
    }

    /// The names of the `ModelClient` types `source` declares.
    public static func modelTypes(in source: SyntaxSource) -> [String] {
        conformances(in: source).filter { ["struct", "class", "actor", "enum"].contains($0.kind) }.map(\.name)
    }

    /// Each `extension PrivacyPlace` in `source`, in any file, its own too.
    /// Even a plain extension could make a place with no model behind it,
    /// as in `static var here: PrivacyPlace { onDevice }`, where the case
    /// needs no dot. A conformance could build one from a raw value, a list
    /// or a decoder.
    @Sendable public static func placeExtensionProblems(in source: SyntaxSource, file: String) -> [Finding] {
        source.nodes(ExtensionDeclSyntax.self).compactMap { decl in
            guard ["PrivacyPlace", "PebbleCore.PrivacyPlace"].contains(SyntaxSource.code(decl.extendedType)) else { return nil }
            return Finding("promise.placeExtension", at: decl, in: source,
                           decl.inheritanceClause != nil ? "adds a conformance to PrivacyPlace"
                            : "extends PrivacyPlace, whose members are pinned")
        }
    }

    /// What `PrivacyPlace` is declared to conform to, in order, or nil when
    /// its declaration isn't found.
    public static func placeConformances(in source: SyntaxSource) -> [String]? {
        guard let decl = source.nodes(EnumDeclSyntax.self).first(where: { $0.name.text == "PrivacyPlace" }) else {
            return nil
        }
        return decl.inheritanceClause?.inheritedTypes.map { SyntaxSource.code($0.type) } ?? []
    }

    /// Each declaration in `source`, anywhere in it, written as in
    /// `placeMembers`: a `case` by name (`case a, b` is two), an `init`,
    /// `func` or `subscript` by its labels, a `var` or `let` by each name
    /// it binds, and any other declaration by its keyword and name.
    public static func declarations(in source: SyntaxSource) -> [(node: Syntax, name: String)] {
        func labels(_ clause: FunctionParameterClauseSyntax) -> String {
            clause.parameters.map { $0.firstName.text + ":" }.joined()
        }
        var found: [(Syntax, String)] = []
        for decl in source.nodes(DeclSyntax.self) {
            let node = Syntax(decl)
            if let cases = decl.as(EnumCaseDeclSyntax.self) {
                for element in cases.elements { found.append((node, "case " + element.name.text)) }
            } else if let initializer = decl.as(InitializerDeclSyntax.self) {
                let mark = initializer.optionalMark?.text ?? ""
                found.append((node, "init\(mark)(\(labels(initializer.signature.parameterClause)))"))
            } else if let function = decl.as(FunctionDeclSyntax.self) {
                found.append((node, "func \(function.name.text)(\(labels(function.signature.parameterClause)))"))
            } else if let subscriptDecl = decl.as(SubscriptDeclSyntax.self) {
                found.append((node, "subscript(\(labels(subscriptDecl.parameterClause)))"))
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    found.append((node, variable.bindingSpecifier.text + " " + SyntaxSource.code(binding.pattern)))
                }
            } else if let scope = SyntaxSource.typeScope(node) {
                found.append((node, scope.kind + " " + scope.name))
            } else if let alias = decl.as(TypeAliasDeclSyntax.self) {
                found.append((node, "typealias " + alias.name.text))
            } else if let associated = decl.as(AssociatedTypeDeclSyntax.self) {
                found.append((node, "associatedtype " + associated.name.text))
            } else if let macro = decl.as(MacroDeclSyntax.self) {
                found.append((node, "macro " + macro.name.text))
            } else if decl.is(ImportDeclSyntax.self) || decl.is(IfConfigDeclSyntax.self) {
                continue
            } else {
                found.append((node, decl.kind.syntaxNodeType == DeclSyntax.self ? "declaration" : "\(decl.kind)"))
            }
        }
        return found
    }

    /// Each declaration in `PrivacyPlace.swift` that isn't in
    /// `placeMembers`, so the only ways to a place are its cases, which the
    /// rules above keep to the model, and `init(staysOnDevice:)`, made only
    /// by `ModelClient`.
    @Sendable public static func placeMemberProblems(in source: SyntaxSource, file: String) -> [Finding] {
        guard file == placeFile else { return [] }
        return declarations(in: source).compactMap { declaration in
            placeMembers.contains(declaration.name) ? nil
                : Finding("promise.placeMember", at: declaration.node, in: source,
                          "\(declaration.name) is not one of PrivacyPlace's pinned members, so it could hand out a "
                            + "place with no model behind it")
        }
    }
}
