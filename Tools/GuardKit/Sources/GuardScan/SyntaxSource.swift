import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Swift source parsed once with SwiftSyntax, for the source guards.
///
/// The tree is folded with the standard operators, so `a || b ? c : d` is a
/// ternary whose condition is `a || b`, and `"a" + "b" + c` is a chain of
/// `+`. Comments are trivia and the words inside a string are a literal's,
/// so neither is ever taken for code. Every guard reads the same model:
///
/// - `literals`: each string literal, decoded as the program sees it
///   (escapes, `\u{...}`, multi-line indentation and raw strings), with
///   each interpolation marked by `interpolation`.
/// - `chains`: literals joined with `+`, read as one line.
/// - `context(of:)`: the `#if` condition that holds where a node is, as a
///   boolean over `os()`, `canImport()` and `targetEnvironment()`, and the
///   declarations and macros around it (`#Preview`, `@main`, types).
/// - `location(of:)`: line and column, both counted in Characters.
public struct SyntaxSource: @unchecked Sendable {
    /// What stands for an interpolation in a literal's `value`. It is not
    /// white space, so a phrase never runs across one.
    public static let interpolation: Character = "\u{FFFC}"

    public let text: String
    /// The folded tree.
    public let tree: SourceFileSyntax
    public let literals: [Literal]
    /// Every literal, alone or with the ones joined to it by `+`, in order.
    public let chains: [[Literal]]

    /// Every token, outside comments and strings' words, in order.
    public let tokens: [TokenSyntax]

    private let bytes: [UInt8]
    private let lineStarts: [Int]
    /// Every node in the tree by its type, walked once, so a rule asking
    /// for all the calls doesn't walk the tree again.
    private let index: [ObjectIdentifier: [Syntax]]

    /// One string literal.
    public struct Literal {
        public let node: StringLiteralExprSyntax
        /// Exactly what is written between the quotes, escapes and
        /// interpolations included.
        public let written: String
        /// What the program sees: escapes decoded, a multi-line literal's
        /// indentation taken off, each interpolation as `interpolation`.
        public let value: String
        public let hasInterpolation: Bool
        public let line: Int
        public let column: Int
        /// Where the literal starts, in UTF-8 bytes from the start of the file.
        public let offset: Int
    }

    public init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        self.bytes = bytes
        var starts = [0]
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { starts.append(index + 1) }
        lineStarts = starts
        let parsed = Parser.parse(source: text)
        let folded = OperatorTable.standardOperators.foldAll(parsed) { _ in }
        let tree = folded.as(SourceFileSyntax.self) ?? parsed
        self.tree = tree
        var index: [ObjectIdentifier: [Syntax]] = [:]
        var stack = [Syntax(tree)]
        while let node = stack.popLast() {
            index[ObjectIdentifier(node.kind.syntaxNodeType), default: []].append(node)
            stack.append(contentsOf: node.children(viewMode: .sourceAccurate).reversed())
        }
        self.index = index
        tokens = Array(tree.tokens(viewMode: .sourceAccurate))

        var literals: [Literal] = []
        for node in (index[ObjectIdentifier(StringLiteralExprSyntax.self)] ?? []).compactMap({ $0.as(StringLiteralExprSyntax.self) }) {
            let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let opened = node.openingQuote.endPositionBeforeTrailingTrivia.utf8Offset
            let closed = node.closingQuote.positionAfterSkippingLeadingTrivia.utf8Offset
            let written = String(decoding: bytes[opened..<max(opened, closed)], as: UTF8.self)
            let decoded = Self.decode(node, bytes: bytes)
            let (line, column) = Self.location(of: start, bytes: bytes, lineStarts: starts)
            literals.append(Literal(node: node, written: written, value: decoded.value,
                                    hasInterpolation: decoded.interpolated, line: line, column: column, offset: start))
        }
        literals.sort { $0.offset < $1.offset }
        self.literals = literals
        let infixes = (index[ObjectIdentifier(InfixOperatorExprSyntax.self)] ?? []).compactMap { $0.as(InfixOperatorExprSyntax.self) }
        chains = Self.chains(of: literals, infixes: infixes)
    }

    /// Every node of a concrete type in the file, in source order, from
    /// the index. A base type such as `DeclSyntax` is found by a walk.
    public func nodes<T: SyntaxProtocol>(_ type: T.Type) -> [T] {
        let bases: [Any.Type] = [DeclSyntax.self, ExprSyntax.self, StmtSyntax.self, PatternSyntax.self, TypeSyntax.self,
                                 Syntax.self]
        if bases.contains(where: { $0 == type }) { return tree.descendants(type) }
        return (index[ObjectIdentifier(type)] ?? []).compactMap { $0.as(T.self) }
    }

    // MARK: Sharing

    private static let lock = NSLock()
    nonisolated(unsafe) private static var parsed: [String: SyntaxSource] = [:]

    /// The file parsed once for every guard that reads it. The sweeps read
    /// the same files many times over.
    public static func shared(_ text: String) -> SyntaxSource {
        if let found = lock.withLock({ parsed[text] }) { return found }
        let source = SyntaxSource(text)
        lock.withLock { parsed[text] = source }
        return source
    }

    // MARK: Places

    /// The line and column, from 1, of a byte offset. The column counts
    /// Characters, so an emoji or an accented letter is one.
    public func location(of offset: Int) -> (line: Int, column: Int) {
        Self.location(of: offset, bytes: bytes, lineStarts: lineStarts)
    }

    public func location(of node: some SyntaxProtocol) -> (line: Int, column: Int) {
        location(of: node.positionAfterSkippingLeadingTrivia.utf8Offset)
    }

    private static func location(of offset: Int, bytes: [UInt8], lineStarts: [Int]) -> (line: Int, column: Int) {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        let start = lineStarts[low]
        let column = String(decoding: bytes[start..<min(max(start, offset), bytes.count)], as: UTF8.self).count + 1
        return (low + 1, column)
    }

    // MARK: Literals

    /// A literal's value as the program sees it. Each interpolation is
    /// swapped for a `\u{FFFC}` escape with the literal's own delimiter,
    /// and the result read back by the parser.
    private static func decode(_ node: StringLiteralExprSyntax, bytes: [UInt8]) -> (value: String, interpolated: Bool) {
        if let value = node.representedLiteralValue { return (value, false) }
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        let pounds = node.openingPounds?.text ?? ""
        var rebuilt: [UInt8] = []
        var cursor = start
        var interpolated = false
        for segment in node.segments {
            guard case .expressionSegment(let expression) = segment else { continue }
            interpolated = true
            let from = expression.positionAfterSkippingLeadingTrivia.utf8Offset
            rebuilt += bytes[cursor..<from]
            rebuilt += Array(("\\" + pounds + "u{FFFC}").utf8)
            cursor = expression.endPositionBeforeTrailingTrivia.utf8Offset
        }
        rebuilt += bytes[cursor..<max(cursor, end)]
        let again = Parser.parse(source: "_ = " + String(decoding: rebuilt, as: UTF8.self))
        if let value = again.descendants(StringLiteralExprSyntax.self).first?.representedLiteralValue {
            return (value, interpolated)
        }
        let opened = node.openingQuote.endPositionBeforeTrailingTrivia.utf8Offset
        let closed = node.closingQuote.positionAfterSkippingLeadingTrivia.utf8Offset
        return (String(decoding: bytes[opened..<max(opened, closed)], as: UTF8.self), interpolated)
    }

    /// Literals written one after another with `+` between them, grouping
    /// parens aside, are one chain. `"Only " + name + " leaves."` is three:
    /// the name between breaks it.
    private static func chains(of literals: [Literal], infixes: [InfixOperatorExprSyntax]) -> [[Literal]] {
        var byOffset: [Int: Literal] = [:]
        for literal in literals { byOffset[literal.offset] = literal }
        var joined: [[Literal]] = []
        var taken = Set<Int>()
        for infix in infixes where isPlus(infix) {
            // Only the top of each `+` tree.
            if let parent = climbParens(Syntax(infix)).parent?.as(InfixOperatorExprSyntax.self), isPlus(parent) { continue }
            var run: [Literal] = []
            for operand in plusOperands(ExprSyntax(infix)) {
                if let literal = operand.as(StringLiteralExprSyntax.self),
                   let found = byOffset[literal.positionAfterSkippingLeadingTrivia.utf8Offset] {
                    run.append(found)
                } else {
                    if run.count > 1 { joined.append(run) }
                    run = []
                }
            }
            if run.count > 1 { joined.append(run) }
        }
        for chain in joined { for literal in chain { taken.insert(literal.offset) } }
        let single = literals.filter { !taken.contains($0.offset) }.map { [$0] }
        return (joined + single).sorted { $0[0].offset < $1[0].offset }
    }

    static func isPlus(_ infix: InfixOperatorExprSyntax) -> Bool {
        infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+"
    }

    /// The operands of a `+` tree, left to right, through grouping parens.
    static func plusOperands(_ expression: ExprSyntax) -> [ExprSyntax] {
        let inner = unparenthesized(expression)
        if let infix = inner.as(InfixOperatorExprSyntax.self), isPlus(infix) {
            return plusOperands(infix.leftOperand) + plusOperands(infix.rightOperand)
        }
        return [inner]
    }

    /// `expression` without the grouping parens around it: `((a))` is `a`.
    public static func unparenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let only = tuple.elements.first, only.label == nil {
            current = only.expression
        }
        return current
    }

    /// The outermost grouping paren around `node`, or `node`.
    static func climbParens(_ node: Syntax) -> Syntax {
        var current = node
        while let element = current.parent?.as(LabeledExprSyntax.self), element.label == nil,
              let list = element.parent?.as(LabeledExprListSyntax.self), list.count == 1,
              let tuple = list.parent?.as(TupleExprSyntax.self) {
            current = Syntax(tuple)
        }
        return current
    }

    /// The ternary whose true branch shows `literal`: the literal is that
    /// branch, or one part of a `+` chain that is, grouping parens aside.
    public func ternary(showing literal: Literal) -> TernaryExprSyntax? {
        var node = Syntax(literal.node)
        while true {
            node = Self.climbParens(node)
            if let infix = node.parent?.as(InfixOperatorExprSyntax.self), Self.isPlus(infix),
               infix.leftOperand.id == node.id || infix.rightOperand.id == node.id {
                node = Syntax(infix)
                continue
            }
            break
        }
        guard let ternary = node.parent?.as(TernaryExprSyntax.self), ternary.thenExpression.id == node.id else { return nil }
        return ternary
    }

    // MARK: Code

    /// A token as the compiler names it: an identifier without its
    /// backticks, so `` `onDevice` `` is `onDevice`, and any other token as
    /// written. Every rule compares names through this, never `text`.
    public static func name(_ token: TokenSyntax) -> String {
        token.identifier?.name ?? token.text
    }

    /// The tokens of `node` with no trivia between them, each by `name`, so
    /// `Theme . accent /* x */` and `` `Theme`.`accent` `` read `Theme.accent`.
    public static func code(_ node: some SyntaxProtocol) -> String {
        node.tokens(viewMode: .sourceAccurate).map(name).joined()
    }

    /// The name a call is made to: `f` in `f(x)` and `a.b.f(x)`, and `init`
    /// in `T.init(x)`.
    public static func calledName(_ call: FunctionCallExprSyntax) -> String? {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) { return name(reference.baseName) }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) { return name(member.declName.baseName) }
        return nil
    }

    /// Every call to one of `names`, `.name(...)`, `x.name(...)`,
    /// `name(...)` and `name { }` alike.
    public func calls(named names: Set<String>) -> [FunctionCallExprSyntax] {
        nodes(FunctionCallExprSyntax.self).filter { Self.calledName($0).map(names.contains) ?? false }
    }

    // MARK: Context

    /// Where a node sits.
    public struct Context {
        /// What must hold for the node to be compiled: every enclosing
        /// `#if` branch, with the branches before it turned down.
        public var condition: Condition = .constant(true)
        /// The types and extensions around the node, innermost first.
        public var types: [TypeScope] = []
        /// Inside a `#Preview`'s own braces.
        public var inPreview = false

        /// Compiled only on the Mac: false on every other platform.
        public var isMacOnly: Bool { condition.holdsOnlyOnTheMac }
        /// Compiled only in a Debug build.
        public var isDebugOnly: Bool { condition.holdsOnlyInDebug }
        /// Inside a type marked `@main`.
        public var inMain: Bool { types.contains { $0.attributes.contains("main") } }
        /// The innermost type or extension.
        public var type: TypeScope? { types.first }
    }

    /// A type declaration or an extension.
    public struct TypeScope: Equatable {
        /// `struct`, `class`, `enum`, `actor`, `protocol` or `extension`.
        public let kind: String
        /// The type's name, or the extended type as written, qualified or not.
        public let name: String
        public let attributes: [String]

        /// The bare name, `HomeSplit` for `PebbleUI.HomeSplit`.
        public var bareName: String { String(name.split(separator: ".").last ?? Substring(name)) }
    }

    public func context(of node: some SyntaxProtocol) -> Context {
        var context = Context()
        var child = Syntax(node)
        var current = child.parent
        while let parent = current {
            if let clause = parent.as(IfConfigClauseSyntax.self), clause.condition?.id != child.id,
               let list = clause.parent?.as(IfConfigClauseListSyntax.self) {
                var holds = clause.condition.map(Condition.init) ?? .constant(true)
                for earlier in list {
                    if earlier.id == clause.id { break }
                    holds = .and(holds, .not(earlier.condition.map(Condition.init) ?? .constant(true)))
                }
                context.condition = .and(holds, context.condition)
            }
            if let macro = parent.as(MacroExpansionDeclSyntax.self), Self.name(macro.macroName) == "Preview" {
                context.inPreview = true
            }
            if let macro = parent.as(MacroExpansionExprSyntax.self), Self.name(macro.macroName) == "Preview" {
                context.inPreview = true
            }
            if let scope = Self.typeScope(parent) { context.types.append(scope) }
            child = parent
            current = parent.parent
        }
        return context
    }

    static func typeScope(_ node: Syntax) -> TypeScope? {
        func attributes(_ list: AttributeListSyntax) -> [String] {
            list.compactMap { $0.as(AttributeSyntax.self).map { code($0.attributeName) } }
        }
        if let decl = node.as(StructDeclSyntax.self) {
            return TypeScope(kind: "struct", name: name(decl.name), attributes: attributes(decl.attributes))
        }
        if let decl = node.as(ClassDeclSyntax.self) {
            return TypeScope(kind: "class", name: name(decl.name), attributes: attributes(decl.attributes))
        }
        if let decl = node.as(EnumDeclSyntax.self) {
            return TypeScope(kind: "enum", name: name(decl.name), attributes: attributes(decl.attributes))
        }
        if let decl = node.as(ActorDeclSyntax.self) {
            return TypeScope(kind: "actor", name: name(decl.name), attributes: attributes(decl.attributes))
        }
        if let decl = node.as(ProtocolDeclSyntax.self) {
            return TypeScope(kind: "protocol", name: name(decl.name), attributes: attributes(decl.attributes))
        }
        if let decl = node.as(ExtensionDeclSyntax.self) {
            return TypeScope(kind: "extension", name: code(decl.extendedType), attributes: attributes(decl.attributes))
        }
        return nil
    }

    /// The first token named `text`, outside comments and strings.
    public func firstToken(_ text: String) -> TokenSyntax? {
        tokens.first { Self.name($0) == text }
    }

    /// The context of the first token spelled `text`.
    public func context(atFirst text: String) -> Context? {
        firstToken(text).map { context(of: $0) }
    }

    /// `isInside` for the first token spelled `text`.
    public func isInside(_ name: String, atFirst text: String) -> Bool {
        firstToken(text).map { isInside(name, $0) } ?? false
    }

    /// True when the innermost type around `node` is `name` itself, its
    /// declaration or an extension of it. A type nested inside it, or code
    /// after its closing brace, is not inside it.
    public func isInside(_ name: String, _ node: some SyntaxProtocol) -> Bool {
        guard let type = context(of: node).type else { return false }
        return type.bareName == name && type.kind != "protocol"
    }

    /// The innermost block with braces around `node`: a code block, a
    /// closure, a type's members or an accessor.
    public static func enclosingBraces(of node: some SyntaxProtocol) -> Syntax? {
        var current = node.parent
        while let parent = current {
            if parent.is(CodeBlockSyntax.self) || parent.is(ClosureExprSyntax.self) || parent.is(MemberBlockSyntax.self)
                || parent.is(AccessorBlockSyntax.self) || parent.is(SwitchExprSyntax.self) {
                return parent
            }
            current = parent.parent
        }
        return nil
    }
}

extension SyntaxProtocol {
    /// Every node of `type` below this one, in source order.
    public func descendants<T: SyntaxProtocol>(_ type: T.Type) -> [T] {
        var found: [T] = []
        var stack = Array(Syntax(self).children(viewMode: .sourceAccurate).reversed())
        while let node = stack.popLast() {
            if let match = node.as(T.self) { found.append(match) }
            stack.append(contentsOf: node.children(viewMode: .sourceAccurate).reversed())
        }
        return found
    }
}

// MARK: Conditions

/// An `#if` condition as a boolean. `os()`, `canImport()` and
/// `targetEnvironment()` are decided by the platform; anything else, such
/// as `DEBUG` or `swift(>=6)`, may be either, so a condition holds "only on
/// the Mac" when it is false on every other platform whatever those are.
public indirect enum Condition: Equatable, CustomStringConvertible {
    case constant(Bool)
    /// `os(macOS)` is `.test("os", "macOS")`.
    case test(String, String)
    /// A flag such as `DEBUG`, or anything the evaluator doesn't know.
    case flag(String)
    case not(Condition)
    case and(Condition, Condition)
    case or(Condition, Condition)

    public init(_ expression: ExprSyntax) {
        let inner = SyntaxSource.unparenthesized(expression)
        if let literal = inner.as(BooleanLiteralExprSyntax.self) {
            self = .constant(literal.literal.text == "true")
        } else if let prefix = inner.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            self = .not(Condition(prefix.expression))
        } else if let infix = inner.as(InfixOperatorExprSyntax.self),
                  let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text, op == "&&" || op == "||" {
            let left = Condition(infix.leftOperand), right = Condition(infix.rightOperand)
            self = op == "&&" ? .and(left, right) : .or(left, right)
        } else if let sequence = inner.as(SequenceExprSyntax.self) {
            self = Condition(sequence: Array(sequence.elements))
        } else if let call = inner.as(FunctionCallExprSyntax.self),
                  let name = call.calledExpression.as(DeclReferenceExprSyntax.self).map({ SyntaxSource.name($0.baseName) }) {
            self = .test(name, SyntaxSource.code(call.arguments))
        } else if let reference = inner.as(DeclReferenceExprSyntax.self) {
            self = .flag(SyntaxSource.name(reference.baseName))
        } else {
            self = .flag("?" + SyntaxSource.code(inner))
        }
    }

    /// An unfolded `a || b && c`, `&&` binding tighter.
    init(sequence elements: [ExprSyntax]) {
        func op(_ element: ExprSyntax) -> String? { element.as(BinaryOperatorExprSyntax.self)?.operator.text }
        if let split = elements.firstIndex(where: { op($0) == "||" }) {
            self = .or(Condition(sequence: Array(elements[..<split])), Condition(sequence: Array(elements[(split + 1)...])))
        } else if let split = elements.firstIndex(where: { op($0) == "&&" }) {
            self = .and(Condition(sequence: Array(elements[..<split])), Condition(sequence: Array(elements[(split + 1)...])))
        } else if elements.count == 1 {
            self = Condition(elements[0])
        } else {
            self = .flag("?" + elements.map(SyntaxSource.code).joined())
        }
    }

    public var description: String {
        switch self {
        case .constant(let value): return String(value)
        case .test(let name, let argument): return "\(name)(\(argument))"
        case .flag(let name): return name
        case .not(let inner): return "!(\(inner))"
        case .and(let left, let right): return "(\(left) && \(right))"
        case .or(let left, let right): return "(\(left) || \(right))"
        }
    }

    /// A platform the package could be built for.
    public struct Platform: Sendable {
        public let name: String
        public let os: String
        public let environments: Set<String>
        /// Modules known to import here. Any module not in `known` may or
        /// may not.
        public let modules: Set<String>

        static let known: Set<String> = ["AppKit", "UIKit", "SwiftUI", "WatchKit", "Cocoa", "Foundation", "Darwin",
                                         "Glibc", "FoundationNetworking", "Combine"]
        static let apple: Set<String> = ["SwiftUI", "Foundation", "Darwin", "Combine"]

        public static let all: [Platform] = [
            Platform(name: "macOS", os: "macOS", environments: [], modules: apple.union(["AppKit", "Cocoa"])),
            Platform(name: "iOS", os: "iOS", environments: [], modules: apple.union(["UIKit"])),
            Platform(name: "iOS Simulator", os: "iOS", environments: ["simulator"], modules: apple.union(["UIKit"])),
            // Mac Catalyst runs UIKit apps. AppKit can be imported there, but
            // most of it is unavailable, so it is never a Mac gate. Cocoa
            // brings AppKit with it, so it is no Mac gate either.
            Platform(name: "Mac Catalyst", os: "iOS", environments: ["macCatalyst"],
                     modules: apple.union(["UIKit", "AppKit", "Cocoa"])),
            Platform(name: "tvOS", os: "tvOS", environments: [], modules: apple.union(["UIKit"])),
            Platform(name: "watchOS", os: "watchOS", environments: [], modules: apple.union(["WatchKit"])),
            Platform(name: "visionOS", os: "visionOS", environments: [], modules: apple.union(["UIKit"])),
            Platform(name: "Linux", os: "Linux", environments: [], modules: ["Foundation", "Glibc", "FoundationNetworking"]),
        ]
    }

    /// The names whose value the platform doesn't settle.
    private var free: [String] {
        var names: [String] = []
        func walk(_ condition: Condition) {
            switch condition {
            case .constant: break
            case .test(let name, let argument):
                switch name {
                case "os", "targetEnvironment": break
                case "canImport" where Platform.known.contains(argument): break
                default: names.append("\(name)(\(argument))")
                }
            case .flag(let name): names.append(name)
            case .not(let inner): walk(inner)
            case .and(let left, let right), .or(let left, let right): walk(left); walk(right)
            }
        }
        walk(self)
        return Array(Set(names)).sorted()
    }

    public func evaluate(on platform: Platform, _ values: [String: Bool]) -> Bool {
        switch self {
        case .constant(let value): return value
        case .test("os", let argument): return argument == platform.os
        case .test("targetEnvironment", let argument): return platform.environments.contains(argument)
        case .test("canImport", let argument) where Platform.known.contains(argument):
            return platform.modules.contains(argument)
        case .test(let name, let argument): return values["\(name)(\(argument))"] ?? false
        case .flag(let name): return values[name] ?? false
        case .not(let inner): return !inner.evaluate(on: platform, values)
        case .and(let left, let right): return left.evaluate(on: platform, values) && right.evaluate(on: platform, values)
        case .or(let left, let right): return left.evaluate(on: platform, values) || right.evaluate(on: platform, values)
        }
    }

    /// True when, on some platform in `platforms` and for some value of
    /// each free name allowed by `fixed`, the condition holds.
    public func canHold(on platforms: [Platform], fixed: [String: Bool] = [:]) -> Bool {
        let names = free.filter { fixed[$0] == nil }
        let count = min(names.count, 16)
        for platform in platforms {
            for bits in 0..<(1 << count) {
                var values = fixed
                for (index, name) in names.prefix(count).enumerated() { values[name] = bits & (1 << index) != 0 }
                if evaluate(on: platform, values) { return true }
            }
        }
        return false
    }

    /// False on every platform but the Mac, whatever the flags are.
    public var holdsOnlyOnTheMac: Bool {
        !canHold(on: Platform.all.filter { $0.name != "macOS" })
    }

    /// False whenever `DEBUG` is, on every platform.
    public var holdsOnlyInDebug: Bool {
        !canHold(on: Platform.all, fixed: ["DEBUG": false])
    }
}
