import Foundation

/// What the cleanup step produced, and whether the raw transcript had to stand in.
public struct CleanupOutcome: Sendable, Equatable {
    public let text: String
    public let cleaned: Bool
    public let failure: String?
    public let duration: Duration
}

/// Runs the selected backend under a deadline; any failure falls back to the raw transcript
/// so a dictation is never lost to the network.
public enum CleanupRouter {
    public static func run(
        transcript: String,
        backend: (any CleanupBackend)?,
        model: ClaudeModel,
        instructions: String,
        timeout: Duration
    ) async -> CleanupOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard let backend else {
            return CleanupOutcome(text: transcript, cleaned: false, failure: nil, duration: .zero)
        }
        do {
            let cleaned = try await withDeadline(timeout) {
                try await backend.cleanUp(transcript, model: model, instructions: instructions)
            }
            // An empty reply from a non-empty dictation is more likely a mistake than intent.
            if cleaned.isEmpty {
                return CleanupOutcome(text: transcript, cleaned: false, failure: "Claude returned no text", duration: clock.now - start)
            }
            return CleanupOutcome(text: cleaned, cleaned: true, failure: nil, duration: clock.now - start)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return CleanupOutcome(text: transcript, cleaned: false, failure: reason, duration: clock.now - start)
        }
    }

    /// Returns the operation's result, or throws `CleanupError.timedOut` and cancels it.
    static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CleanupError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CleanupError.timedOut }
            return first
        }
    }
}
