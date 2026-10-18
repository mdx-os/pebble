import SwiftSyntax

/// The contrast guard's rules: no screen colors words in a way
/// `Theme.textPairs` doesn't cover. Each call is read through the tree, so
/// its arguments are its own however many lines they take, and comments and
/// the words inside strings are never code.
public enum ContrastLint {
    /// What may color words: the arguments of every `foregroundStyle(` and
    /// `foregroundColor(` call.
    static let wordCalls: Set<String> = ["foregroundStyle", "foregroundColor"]

    /// The tints that may reach system controls. `accentText` writes their
    /// words; `tintFill` sits under white words, as on a selected sidebar row.
    public static let allowedTints: Set<String> = ["Theme.accentText", "Theme.tintFill"]

    /// The contrast rules, then the accent rules: orange only where it belongs.
    public static let contrastRules: [Rule] = [
        Rule("contrast.rawAccent", rawAccent),
        Rule("contrast.systemGray", systemGray),
        Rule("contrast.gray", gray),
        Rule("contrast.red", red),
        Rule("contrast.fadedWhite", fadedWhite),
        Rule("contrast.white", white),
        Rule("contrast.accentSymbol", accentSymbol),
        Rule("contrast.surface", surface),
        Rule("contrast.tint", tint),
        Rule("contrast.orange", orange),
        Rule("contrast.bordered", bordered),
        Rule("contrast.splitCall", splitCall),
    ]

    /// The modifiers the rules read the arguments of.
    static let readModifiers: Set<String> = wordCalls.union(["fill", "background", "tint", "buttonStyle"])

    public static let accentRules: [Rule] = [
        Rule("accent.tintFillTint", tintFillTint),
        Rule("accent.tintFillWords", tintFillWords),
        Rule("accent.onTintFill", onTintFill),
        Rule("accent.doneInItem", doneInItem),
        Rule("accent.confirmation", confirmation),
        Rule("accent.doneRing", doneRing),
        Rule("accent.ink", ink),
    ]

    public static var rules: [Rule] { contrastRules + accentRules }

    public static func problems(in source: SyntaxSource, file: String = "") -> [Finding] {
        rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    public static func problems(in text: String) -> [Finding] {
        problems(in: SyntaxSource(text))
    }

    // MARK: Reading calls

    /// Every member read inside `node`, `node` too.
    static func members(in node: some SyntaxProtocol) -> [MemberAccessExprSyntax] {
        (node.as(MemberAccessExprSyntax.self).map { [$0] } ?? []) + node.descendants(MemberAccessExprSyntax.self)
    }

    /// The name read: `accent` in `Theme.accent` and `` Theme.`accent` ``.
    static func name(_ member: MemberAccessExprSyntax) -> String { SyntaxSource.name(member.declName.baseName) }

    static func name(_ reference: DeclReferenceExprSyntax) -> String { SyntaxSource.name(reference.baseName) }

    /// A member of `Theme` itself, qualified or not: `Theme.accent` and
    /// `PebbleUI.Theme.accent` alike.
    static func isTheme(_ member: MemberAccessExprSyntax, _ wanted: String) -> Bool {
        guard name(member) == wanted, let base = member.base else { return false }
        if let reference = base.as(DeclReferenceExprSyntax.self) { return name(reference) == "Theme" }
        if let qualified = base.as(MemberAccessExprSyntax.self) { return name(qualified) == "Theme" }
        return false
    }

    /// A member read off the system: `.gray`, `Color.gray`, or off a value
    /// that doesn't end in a name, such as `f().gray`. Never `Theme.gray`.
    static func isSystem(_ member: MemberAccessExprSyntax) -> Bool {
        guard let base = member.base else { return true }
        let code = SyntaxSource.code(base)
        return code == "Color" || code == "SwiftUI.Color" || !(code.last?.isLetter ?? false)
    }

    /// Each word call's arguments with the members read in them.
    static func wordMembers(_ source: SyntaxSource) -> [(call: FunctionCallExprSyntax, members: [MemberAccessExprSyntax])] {
        source.calls(named: wordCalls).map { ($0, members(in: $0.arguments)) }
    }

    /// Where a call's name is, which is the line a problem points at.
    static func nameToken(_ call: FunctionCallExprSyntax) -> Syntax {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) { return Syntax(member.declName) }
        return Syntax(call.calledExpression)
    }

    static func wordRule(_ name: String, _ message: String, _ source: SyntaxSource,
                         _ matches: (MemberAccessExprSyntax) -> Bool) -> [Finding] {
        wordMembers(source).compactMap { call, members in
            members.contains(where: matches) ? Finding(name, at: nameToken(call), in: source, message) : nil
        }
    }

    // MARK: Contrast

    @Sendable static func rawAccent(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.rawAccent",
                 "the raw accent is too faint for words; use Theme.accentText, or Theme.accentSymbol on an Image", source) {
            isTheme($0, "accent")
        }
    }

    @Sendable static func systemGray(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.systemGray", "the system gray is about 3.5 to 1 on white; use Theme.secondaryText", source) {
            ["secondary", "tertiary", "quaternary"].contains(name($0))
        }
    }

    @Sendable static func gray(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.gray", "the system gray is too faint for words; use Theme.secondaryText", source) {
            name($0) == "gray" && isSystem($0)
        }
    }

    @Sendable static func red(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.red", "the system red is too faint on a card; use Theme.dangerText", source) {
            name($0) == "red" && isSystem($0)
        }
    }

    @Sendable static func fadedWhite(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.fadedWhite", "faded white is too faint for words; use Theme.onAccent or the primary ink", source) {
            name($0) == "opacity" && $0.base?.as(MemberAccessExprSyntax.self).map(name) == "white"
        }
    }

    /// White anywhere in the argument, so a branch of a ternary counts too.
    /// Faded white has its own rule.
    @Sendable static func white(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("contrast.white", "white is too faint on the accent; use Theme.onAccent", source) { member in
            guard name(member) == "white", isSystem(member) else { return false }
            let faded = member.parent?.as(MemberAccessExprSyntax.self).map {
                $0.base?.id == member.id && name($0) == "opacity"
            } ?? false
            return !faded
        }
    }

    /// The call a modifier chain starts from: `Image` for
    /// `Image(systemName: "x").font(.body).foregroundStyle(...)`.
    static func chainRoot(of call: FunctionCallExprSyntax) -> String? {
        var expression = ExprSyntax(call)
        while true {
            if let next = expression.as(FunctionCallExprSyntax.self) {
                if let member = next.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
                    expression = base
                    continue
                }
                return next.calledExpression.as(DeclReferenceExprSyntax.self).map(name)
            }
            if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
                expression = base
                continue
            }
            return nil
        }
    }

    /// The accent symbol is for an Image, never words: the call it is in
    /// must be a modifier on an `Image(...)`.
    @Sendable static func accentSymbol(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordMembers(source).compactMap { call, members in
            guard members.contains(where: { isTheme($0, "accentSymbol") }), chainRoot(of: call) != "Image" else { return nil }
            return Finding("contrast.accentSymbol", at: nameToken(call), in: source, "Theme.accentSymbol is only for an Image")
        }
    }

    /// What may fill a surface: a system color surface is not in
    /// `Theme.textPairs`.
    @Sendable static func surface(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["fill", "background"]).compactMap { call in
            members(in: call.arguments).contains { ["gray", "red"].contains(name($0)) && isSystem($0) }
                ? Finding("contrast.surface", at: nameToken(call), in: source,
                          "a system color surface is not in Theme.textPairs; use a Theme surface")
                : nil
        }
    }

    @Sendable static func tint(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["tint"]).compactMap { call in
            allowedTints.contains(SyntaxSource.code(call.arguments)) ? nil
                : Finding("contrast.tint", at: nameToken(call), in: source,
                          "a tint colors the words of system controls; tint with Theme.accentText or Theme.tintFill only")
        }
    }

    /// Anywhere in code: the brand color comes from Theme.
    @Sendable static func orange(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(MemberAccessExprSyntax.self).compactMap { member in
            name(member) == "orange"
                ? Finding("contrast.orange", at: member.declName, in: source,
                          "the brand color comes from Theme, never the system orange")
                : nil
        }
    }

    @Sendable static func bordered(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["buttonStyle"]).compactMap { call in
            guard let argument = call.arguments.first?.expression else { return nil }
            let inner = SyntaxSource.unparenthesized(argument)
            let implicit = inner.as(MemberAccessExprSyntax.self).map {
                $0.base == nil && name($0).hasPrefix("bordered")
            } ?? false
            let named = inner.as(FunctionCallExprSyntax.self).flatMap(SyntaxSource.calledName)?.hasPrefix("Bordered") ?? false
            return implicit || named
                ? Finding("contrast.bordered", at: nameToken(call), in: source,
                          "system bordered buttons color their words with the tint; use SoftButtonStyle or AccentButtonStyle")
                : nil
        }
    }

    /// A modifier the rules read, named but not called, as in
    /// `.foregroundStyle\n(Theme.accent)`: Swift reads the paren on the next
    /// line as a new expression, so no rule above would see its argument.
    @Sendable static func splitCall(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(MemberAccessExprSyntax.self).compactMap { member in
            let token = member.declName.baseName
            guard readModifiers.contains(name(member)),
                  member.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != member.id,
                  let next = token.nextToken(viewMode: .sourceAccurate), next.tokenKind == .leftParen,
                  (token.trailingTrivia.pieces + next.leadingTrivia.pieces).contains(where: \.isNewline)
            else { return nil }
            return Finding("contrast.splitCall", at: member.declName, in: source,
                           ".\(name(member)) is not called here; put its ( on the same line")
        }
    }

    // MARK: Accent: the fill tint and white on it

    /// True when a `.tint(Theme.tintFill)` tints a fill: the sidebar's
    /// `List(selection:)` in `HomeSplit`, tinted right on its closure, or
    /// anything in `DoneButton`. A selected row and Done fill with the tint
    /// and write white on it; any other list or control would draw its
    /// words or icons in the fill, too faint on dark.
    public static func tintsAFill(_ call: FunctionCallExprSyntax, in source: SyntaxSource) -> Bool {
        if source.isInside("HomeSplit", call),
           let list = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(FunctionCallExprSyntax.self),
           SyntaxSource.calledName(list) == "List", list.calledExpression.is(DeclReferenceExprSyntax.self),
           list.arguments.first?.label.map(SyntaxSource.name) == "selection", list.trailingClosure != nil {
            return true
        }
        return source.isInside("DoneButton", call)
    }

    @Sendable static func tintFillTint(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["tint"]).compactMap { call in
            guard call.arguments.count == 1,
                  let member = call.arguments.first.flatMap({ SyntaxSource.unparenthesized($0.expression).as(MemberAccessExprSyntax.self) }),
                  isTheme(member, "tintFill"), !tintsAFill(call, in: source) else { return nil }
            return Finding("accent.tintFillTint", at: nameToken(call), in: source,
                           "Theme.tintFill is only for the sidebar's List(selection:) in HomeSplit and DoneButton, "
                            + "where it is a fill")
        }
    }

    /// Anything else in `tintFill` is drawn in it, words or icons.
    @Sendable static func tintFillWords(_ source: SyntaxSource, _ file: String) -> [Finding] {
        wordRule("accent.tintFillWords", "Theme.tintFill is a fill, never words", source) {
            isTheme($0, "tintFill")
        }
    }

    /// True when `onTintFill` at `node` has `tintFill` under it: anywhere
    /// in `FillButtonStyle`, which draws that fill, or in `HomeSplit` right
    /// inside the braces of an `if chosen {` whose `chosen` is the row's
    /// own. A ternary such as `chosen ? onTintFill : .primary` is not
    /// enough: it sets a style on every other row too, over their tinted
    /// icons and the system's own selection.
    public static func onTheFill(_ node: some SyntaxProtocol, in source: SyntaxSource) -> Bool {
        if source.isInside("FillButtonStyle", node) { return true }
        guard source.isInside("HomeSplit", node),
              let block = SyntaxSource.enclosingBraces(of: node)?.as(CodeBlockSyntax.self),
              let branch = block.parent?.as(IfExprSyntax.self), branch.body.id == block.id,
              branch.conditions.count == 1,
              branch.conditions.first?.condition.as(ExprSyntax.self)?.as(DeclReferenceExprSyntax.self).map(name) == "chosen"
        else { return false }
        return chosenIsTied(at: branch, in: source)
    }

    @Sendable static func onTintFill(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(DeclReferenceExprSyntax.self).compactMap { reference in
            guard name(reference) == "onTintFill", !onTheFill(reference, in: source) else { return nil }
            return Finding("accent.onTintFill", at: reference, in: source,
                           "Theme.onTintFill is only for words on tintFill: FillButtonStyle and HomeSplit's chosen row")
        }
    }

    /// True when the `chosen` that `node` sees is the row's own: the
    /// nearest one in scope is a `chosen: Bool` parameter of the function
    /// `node` is in, or a `let chosen = Self.isChosen(...)`, with at most
    /// `&& Self.drawsOwnFill` after it. Any other `chosen`, such as a stored
    /// one, a closure's, `let chosen = !Self.isChosen(...)`, or a parameter
    /// of another function, could put white on a row with no fill under it.
    public static func chosenIsTied(at node: some SyntaxProtocol, in source: SyntaxSource) -> Bool {
        switch nearestChosen(above: Syntax(node)) {
        case .parameter(let type)?: return type == "Bool"
        case .binding(let value)?: return value.map(isTheRowsChoice) ?? false
        case .other?, nil: return false
        }
    }

    enum Chosen {
        case parameter(type: String)
        case binding(value: ExprSyntax?)
        case other
    }

    /// The declaration of `chosen` that `start` sees, found going out from
    /// it scope by scope. Every form that binds a name counts: `let` and
    /// `var`, `if`, `guard` and `while` conditions, a `for` pattern, a
    /// `case .x(let chosen)`, a `catch let chosen`, and a closure's
    /// parameters.
    static func nearestChosen(above start: Syntax) -> Chosen? {
        var child = start
        var current = start.parent
        while let parent = current {
            // Statements before this one, in the same list, nearest first.
            if let list = parent.as(CodeBlockItemListSyntax.self) {
                let before = list.prefix { $0.id != child.id }
                for item in before.reversed() {
                    if let variable = item.item.as(VariableDeclSyntax.self) {
                        for binding in variable.bindings.reversed()
                        where binding.pattern.as(IdentifierPatternSyntax.self).map({ SyntaxSource.name($0.identifier) })
                            == "chosen" {
                            // Only a `let` stays what it was set to.
                            let kept = variable.bindingSpecifier.text == "let" && binding.accessorBlock == nil
                            return kept ? .binding(value: binding.initializer?.value) : .other
                        }
                        if variable.bindings.contains(where: { mentionsChosen($0.pattern) }) { return .other }
                    }
                    if let guardStatement = item.item.as(GuardStmtSyntax.self), binds(guardStatement.conditions) {
                        return .other
                    }
                }
            }
            if let branch = parent.as(IfExprSyntax.self), branch.body.id == child.id, binds(branch.conditions) { return .other }
            if let loop = parent.as(WhileStmtSyntax.self), loop.body.id == child.id, binds(loop.conditions) { return .other }
            if let loop = parent.as(ForStmtSyntax.self), loop.body.id == child.id, mentionsChosen(loop.pattern) {
                return .other
            }
            if let switchCase = parent.as(SwitchCaseSyntax.self), switchCase.statements.id == child.id,
               mentionsChosen(switchCase.label) {
                return .other
            }
            if let clause = parent.as(CatchClauseSyntax.self), clause.body.id == child.id, mentionsChosen(clause.catchItems) {
                return .other
            }
            if let closure = parent.as(ClosureExprSyntax.self), let signature = closure.signature, mentionsChosen(signature) {
                return .other
            }
            if let function = parent.as(FunctionDeclSyntax.self) {
                return parameter(in: function.signature.parameterClause)
            }
            if let initializer = parent.as(InitializerDeclSyntax.self) {
                return parameter(in: initializer.signature.parameterClause)
            }
            // Out of a computed property or into a type's members: any
            // `chosen` from here on is stored, or another function's.
            if parent.is(MemberBlockSyntax.self) || parent.is(AccessorBlockSyntax.self) { return .other }
            child = parent
            current = parent.parent
        }
        return nil
    }

    /// The function's own `chosen` parameter, or `other` when it has none:
    /// a `chosen` outside it is no parameter of this function.
    static func parameter(in clause: FunctionParameterClauseSyntax) -> Chosen {
        for parameter in clause.parameters where SyntaxSource.name(parameter.secondName ?? parameter.firstName) == "chosen" {
            return .parameter(type: SyntaxSource.code(parameter.type))
        }
        return .other
    }

    /// True when a name in `node` is `chosen`, backticks aside.
    static func mentionsChosen(_ node: some SyntaxProtocol) -> Bool {
        node.tokens(viewMode: .sourceAccurate).contains { $0.identifier != nil && SyntaxSource.name($0) == "chosen" }
    }

    static func binds(_ conditions: ConditionElementListSyntax) -> Bool {
        conditions.contains { element in
            element.condition.as(OptionalBindingConditionSyntax.self).map { mentionsChosen($0.pattern) } == true
                || element.condition.as(MatchingPatternConditionSyntax.self).map { mentionsChosen($0.pattern) } == true
        }
    }

    /// `Self.isChosen(...)`, with no call inside its arguments, alone or
    /// with `&& Self.drawsOwnFill` after it.
    static func isTheRowsChoice(_ expression: ExprSyntax) -> Bool {
        let inner = SyntaxSource.unparenthesized(expression)
        if let infix = inner.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "&&" {
            return isChoiceCall(infix.leftOperand) && SyntaxSource.code(infix.rightOperand) == "Self.drawsOwnFill"
        }
        return isChoiceCall(inner)
    }

    static func isChoiceCall(_ expression: ExprSyntax) -> Bool {
        guard let call = SyntaxSource.unparenthesized(expression).as(FunctionCallExprSyntax.self),
              SyntaxSource.code(call.calledExpression) == "Self.isChosen", call.trailingClosure == nil else { return false }
        return call.arguments.descendants(FunctionCallExprSyntax.self).isEmpty
    }

    /// Every call in `HomeSplit` that hands a row its `chosen`,
    /// `ink(chosen:)`, passes the row's own: `Self.isChosen(...)` or a
    /// `chosen` tied to it.
    @Sendable static func ink(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.calls(named: ["ink"]).compactMap { call in
            guard source.isInside("HomeSplit", call) else { return nil }
            if call.arguments.count == 1, let argument = call.arguments.first, argument.label.map(SyntaxSource.name) == "chosen" {
                if isChoiceCall(argument.expression) { return nil }
                if argument.expression.as(DeclReferenceExprSyntax.self).map(name) == "chosen",
                   chosenIsTied(at: call, in: source) {
                    return nil
                }
            }
            return Finding("accent.ink", at: nameToken(call), in: source,
                           "ink(chosen:) takes the row's own chosen, from Self.isChosen")
        }
    }

    // MARK: Accent: Done

    /// Every `ToolbarItem`, with a placement or with none, and its content.
    static func toolbarItems(_ source: SyntaxSource) -> [FunctionCallExprSyntax] {
        source.calls(named: ["ToolbarItem"]).filter { $0.calledExpression.is(DeclReferenceExprSyntax.self) }
    }

    static func mentionsDone(_ node: some SyntaxProtocol) -> Bool {
        node.descendants(DeclReferenceExprSyntax.self).contains { name($0) == "DoneButton" }
    }

    /// Done is checked only inside a `ToolbarItem`'s own closure. In a
    /// `ToolbarItemGroup`, straight in `.toolbar { }`, which the system wraps
    /// for itself, or anywhere else, neither Done rule would see it.
    @Sendable static func doneInItem(_ source: SyntaxSource, _ file: String) -> [Finding] {
        source.nodes(DeclReferenceExprSyntax.self).compactMap { reference in
            guard name(reference) == "DoneButton" else { return nil }
            var current = reference.parent
            while let parent = current {
                if let closure = parent.as(ClosureExprSyntax.self),
                   let call = closure.parent?.as(FunctionCallExprSyntax.self), call.trailingClosure?.id == closure.id,
                   call.calledExpression.as(DeclReferenceExprSyntax.self).map(name) == "ToolbarItem" {
                    return nil
                }
                current = parent.parent
            }
            return Finding("accent.doneInItem", at: reference, in: source,
                           "DoneButton goes in its own ToolbarItem, so the Done rules can check it")
        }
    }

    /// A confirmation button is drawn filled with the tint, with white
    /// words on it, so it must be a `DoneButton`, which tints it to keep
    /// those words readable, and no other button.
    @Sendable static func confirmation(_ source: SyntaxSource, _ file: String) -> [Finding] {
        toolbarItems(source).compactMap { item in
            guard members(in: item.arguments).contains(where: { name($0) == "confirmationAction" }) else {
                return nil
            }
            let content = item.trailingClosure
            let done = content.map(mentionsDone) ?? false
            let button = content.map { closure in
                closure.descendants(FunctionCallExprSyntax.self).contains {
                    $0.calledExpression.as(DeclReferenceExprSyntax.self).map(name) == "Button"
                }
            } ?? false
            return !done || button
                ? Finding("accent.confirmation", at: item.calledExpression, in: source,
                          "a confirmation button fills with the tint; use DoneButton so its words stay readable")
                : nil
        }
    }

    /// On iOS 26 the toolbar puts a glass ring around the fill unless the
    /// item hides its shared background. That is so whatever the placement,
    /// so any item holding Done is modified right away by
    /// `.sharedBackgroundVisibility(.hidden)`.
    @Sendable static func doneRing(_ source: SyntaxSource, _ file: String) -> [Finding] {
        toolbarItems(source).compactMap { item in
            guard let content = item.trailingClosure, mentionsDone(content) else { return nil }
            let modifier = SyntaxSource.climbParens(Syntax(item)).parent?.as(MemberAccessExprSyntax.self)
            let call = modifier?.parent?.as(FunctionCallExprSyntax.self)
            let hides = modifier.map(name) == "sharedBackgroundVisibility"
                && call?.calledExpression.id == modifier?.id
                && call.map { SyntaxSource.code($0.arguments) } == ".hidden"
            return hides ? nil
                : Finding("accent.doneRing", at: item.calledExpression, in: source,
                          "Done draws its own fill; add .sharedBackgroundVisibility(.hidden) so the toolbar draws no "
                            + "glass ring around it")
        }
    }
}
