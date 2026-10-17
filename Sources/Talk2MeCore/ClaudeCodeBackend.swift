import Foundation

/// Cleans up a transcript by running the user's own Claude Code install, the way T3 Code does.
///
/// Talk2Me never sees the user's Claude credentials: the user signs in once with
/// `claude auth login`, and Claude Code reads its own login from its config and the Keychain.
public struct ClaudeCodeBackend: CleanupBackend {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Common install locations; a menu-bar app does not inherit the user's shell PATH.
    public static func locate(customPath: String? = nil) -> URL? {
        let fm = FileManager.default
        if let custom = customPath?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Print mode with no tools, MCP servers, slash commands or saved session: one text-in, text-out turn.
    /// `--bare` would start faster, but it ignores the subscription login and accepts only API keys.
    public static func arguments(model: ClaudeModel, instructions: String) -> [String] {
        [
            "-p",
            "--model", model.rawValue,
            "--system-prompt", instructions,
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--effort", "low",
            "--output-format", "json",
        ]
    }

    struct PrintResult: Decodable {
        let is_error: Bool?
        let result: String?
        let subtype: String?
    }

    public static func parseOutput(_ data: Data) throws -> String {
        guard let result = try? JSONDecoder().decode(PrintResult.self, from: data) else {
            let raw = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanupError.claudeCode(raw.isEmpty ? "no output" : raw)
        }
        if result.is_error == true {
            throw CleanupError.claudeCode(result.result ?? result.subtype ?? "unknown error")
        }
        guard let text = result.result else { throw CleanupError.badResponse("missing result") }
        return CleanupPrompt.sanitize(text)
    }

    public func cleanUp(_ transcript: String, model: ClaudeModel, instructions: String) async throws -> String {
        let output = try await run(
            arguments: Self.arguments(model: model, instructions: instructions),
            stdin: CleanupPrompt.userMessage(for: transcript)
        )
        return try Self.parseOutput(output)
    }

    /// Runs `claude` in an empty working directory so no project CLAUDE.md is picked up.
    /// Cancelling the calling task terminates the process.
    private func run(arguments: [String], stdin input: String) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = Self.workingDirectory()

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let collector = OutputCollector()
                let group = DispatchGroup()
                for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
                    group.enter()
                    DispatchQueue.global().async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        collector.store(data, stdout: isStdout)
                        group.leave()
                    }
                }
                process.terminationHandler = { process in
                    group.notify(queue: .global()) {
                        let (out, err) = collector.values
                        if process.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: CancellationError())
                        } else if process.terminationStatus != 0, out.isEmpty {
                            let message = String(decoding: err.prefix(300), as: UTF8.self)
                            continuation.resume(throwing: CleanupError.claudeCode(
                                message.isEmpty ? "exit status \(process.terminationStatus)" : message))
                        } else {
                            // A failed turn still prints its JSON result with is_error set.
                            continuation.resume(returning: out)
                        }
                    }
                }
                do {
                    try process.run()
                    stdinPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? stdinPipe.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CleanupError.claudeCode(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func workingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talk2me-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func store(_ data: Data, stdout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if stdout { out = data } else { err = data }
    }

    var values: (Data, Data) {
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}
