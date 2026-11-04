import Foundation

public struct CommandError: Error, LocalizedError, Equatable {
    public let message: String
    /// Close command names for an unknown command (at most 3).
    public let suggestions: [String]

    public init(_ message: String, suggestions: [String] = []) {
        self.message = message
        self.suggestions = suggestions
    }

    public var errorDescription: String? {
        suggestions.isEmpty ? message : "\(message). Did you mean: \(suggestions.joined(separator: ", "))?"
    }
}
