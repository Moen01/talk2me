import Foundation
import Testing
@testable import Talk2MeCore

/// Runs ClaudeCodeBackend against fake `claude` scripts to check the process plumbing.
struct ClaudeCodeProcessTests {
    private func fakeClaude(_ body: String) throws -> (script: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talk2me-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, dir)
    }

    @Test func sendsTranscriptOnStdinAndReadsResult() async throws {
        // Echo the transcript back inside the JSON result to prove it arrived on stdin.
        let (script, dir) = try fakeClaude("""
        input=$(cat | tr -d '\\n')
        printf '{"is_error":false,"result":"%s"}' "$input"
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try await ClaudeCodeBackend(executable: script).cleanUp("hello", model: .haiku, instructions: "x")
        #expect(text == "hello")
    }

    @Test func nonZeroExitWithoutOutputReportsStderr() async throws {
        let (script, dir) = try fakeClaude("cat > /dev/null\necho 'not logged in' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CleanupError.claudeCode("not logged in\n")) {
            try await ClaudeCodeBackend(executable: script).cleanUp("hi", model: .haiku, instructions: "x")
        }
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let (script, dir) = try fakeClaude("sleep 2\ntouch \"$(dirname \"$0\")/finished\"\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: ClaudeCodeBackend(executable: script),
            model: .haiku, instructions: "", timeout: .milliseconds(300))
        #expect(outcome.text == "raw")
        #expect(outcome.failure == CleanupError.timedOut.errorDescription)
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("finished").path))
    }

    @Test func timeoutReturnsWhenClaudeIgnoresSIGTERM() async throws {
        // The background sleep inherits the pipes and keeps them open after the script is killed.
        let (script, dir) = try fakeClaude("trap '' TERM\nsleep 6 &\nsleep 6\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await CleanupRouter.run(
            transcript: "raw", backend: ClaudeCodeBackend(executable: script),
            model: .haiku, instructions: "", timeout: .milliseconds(300))
        #expect(outcome.text == "raw")
        #expect(clock.now - start < .seconds(4))
    }

    @Test func pathFindsToolsNextToClaudeFirst() {
        let env = ClaudeCodeBackend.environment(
            for: URL(fileURLWithPath: "/opt/nvm/bin/claude"), base: ["PATH": "/usr/bin:/bin", "HOME": "/h"])
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/opt/nvm/bin")
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.suffix(2) == ["/usr/bin", "/bin"])
        #expect(env["HOME"] == "/h")
    }
}
