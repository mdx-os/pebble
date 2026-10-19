import SwiftSyntax

/// One thing a guard found, with the rule that found it.
public struct Finding: Equatable, CustomStringConvertible, Sendable {
    /// The rule's name, such as `contrast.rawAccent`. The wrong-case suite
    /// asks for it by name, so a rule that stops catching its case fails.
    public let rule: String
    public let line: Int
    /// Counted in Characters, from 1.
    public let column: Int
    public let message: String

    public init(rule: String, line: Int, column: Int, message: String) {
        self.rule = rule
        self.line = line
        self.column = column
        self.message = message
    }

    public init(_ rule: String, at node: some SyntaxProtocol, in source: SyntaxSource, _ message: String) {
        let place = source.location(of: node)
        self.init(rule: rule, line: place.line, column: place.column, message: message)
    }

    public var description: String { "\(line):\(column): \(message)" }

    /// `file:line:column: message`, as the sweeps record it.
    public func report(in file: String) -> String { "\(file):\(description)" }
}

/// A rule: its name and what it finds in one file.
public struct Rule: Sendable {
    public let name: String
    public let check: @Sendable (SyntaxSource, String) -> [Finding]

    public init(_ name: String, _ check: @escaping @Sendable (SyntaxSource, String) -> [Finding]) {
        self.name = name
        self.check = check
    }
}
