import Foundation

/// A pulse failure with a sentence a person can read.
public struct PulseError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }

    public var errorDescription: String? { message }
}
