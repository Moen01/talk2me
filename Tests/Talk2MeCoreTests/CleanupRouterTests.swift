import Foundation
import Testing
@testable import Talk2MeCore

private struct StubBackend: CleanupBackend {
    var delay: Duration = .zero
    var result: Result<String, CleanupError>

    func cleanUp(_ transcript: String, model: ClaudeModel, instructions: String) async throws -> String {
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

struct CleanupRouterTests {
    @Test func usesCleanedTextOnSuccess() async {
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: StubBackend(result: .success("Clean.")),
            model: .haiku, instructions: "", timeout: .seconds(5))
        #expect(outcome.text == "Clean.")
        #expect(outcome.cleaned)
        #expect(outcome.failure == nil)
    }

    @Test func noBackendPastesRawTranscript() async {
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: nil, model: .haiku, instructions: "", timeout: .seconds(5))
        #expect(outcome.text == "raw")
        #expect(!outcome.cleaned)
        #expect(outcome.failure == nil)
    }

    @Test func failureFallsBackToRawWithReason() async {
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: StubBackend(result: .failure(.claudeNotFound)),
            model: .haiku, instructions: "", timeout: .seconds(5))
        #expect(outcome.text == "raw")
        #expect(!outcome.cleaned)
        #expect(outcome.failure == CleanupError.claudeNotFound.errorDescription)
    }

    @Test func timeoutFallsBackToRawPromptly() async {
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: StubBackend(delay: .seconds(30), result: .success("late")),
            model: .haiku, instructions: "", timeout: .milliseconds(100))
        #expect(outcome.text == "raw")
        #expect(outcome.failure == CleanupError.timedOut.errorDescription)
        #expect(outcome.duration < .seconds(5))
    }

    @Test func emptyCleanupKeepsRawTranscript() async {
        let outcome = await CleanupRouter.run(
            transcript: "raw words", backend: StubBackend(result: .success("")),
            model: .haiku, instructions: "", timeout: .seconds(5))
        #expect(outcome.text == "raw words")
        #expect(!outcome.cleaned)
    }
}

struct CleanupPromptTests {
    @Test func appendsUserInstructionsOnlyWhenSet() {
        #expect(CleanupPrompt.system(extraInstructions: nil) == CleanupPrompt.base)
        #expect(CleanupPrompt.system(extraInstructions: "  ") == CleanupPrompt.base)
        #expect(CleanupPrompt.system(extraInstructions: "Use British spelling").hasSuffix("Use British spelling"))
    }

    @Test func sanitizeStripsEchoedTags() {
        #expect(CleanupPrompt.sanitize("<transcript>\nHi.\n</transcript>\n") == "Hi.")
    }
}
