import Foundation

/// Sends one transcript to Claude and returns the cleaned text.
public protocol CleanupBackend: Sendable {
    func cleanUp(_ transcript: String, model: ClaudeModel, instructions: String) async throws -> String
}

public enum CleanupError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case claudeNotFound
    case invalidAPIKey(String)
    case rateLimited(String)
    case refused
    case timedOut
    case http(status: Int, message: String)
    case claudeCode(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Claude API key is saved. Add one in Settings."
        case .claudeNotFound: "Claude Code was not found. Install it, or set its path in Settings."
        case .invalidAPIKey(let message): "The API key was rejected: \(message)"
        case .rateLimited(let message): "Rate limited: \(message)"
        case .refused: "Claude declined to clean up this transcript."
        case .timedOut: "Cleanup took too long."
        case .http(let status, let message): "Claude API error \(status): \(message)"
        case .claudeCode(let message): "Claude Code failed: \(message)"
        case .badResponse(let message): "Unexpected response: \(message)"
        }
    }
}
