import Foundation

/// The Claude models offered in the model picker.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    /// Server-side refusal fallbacks exist for Opus 5.5 and Sonnet 5.5, not for Haiku 5.5.
    public var supportsServerFallbacks: Bool { self != .haiku }

    /// The oldest Claude Code that can run this model, when known. Claude Code 2.1.206
    /// rejected Opus 5.5 with "version 2.1.280 or newer is required".
    public var minimumClaudeCodeVersion: String? {
        self == .opus ? "2.1.280" : nil
    }
}

/// Where the cleanup step sends a transcript.
public enum CleanupBackendKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The user's own Claude Code install, signed in with `claude auth login`.
    case claudeCode
    /// A Claude Console API key stored in the Keychain.
    case apiKey
    /// No cleanup: paste the raw transcript.
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code (your subscription)"
        case .apiKey: "Claude API key"
        case .off: "Off (raw transcript)"
        }
    }
}
