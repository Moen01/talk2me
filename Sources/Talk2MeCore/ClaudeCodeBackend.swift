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
        let output = try await Self.run(
            executable,
            arguments: Self.arguments(model: model, instructions: instructions),
            stdin: CleanupPrompt.userMessage(for: transcript)
        )
        return try Self.parseOutput(output)
    }

    // MARK: - Install and sign-in status

    /// What the setup guide shows about the user's Claude Code install.
    public struct Status: Sendable, Equatable {
        public var version: String?
        public var loggedIn: Bool
        /// "claude.ai" for a subscription login, otherwise an API key or cloud provider.
        public var authMethod: String?
        /// "pro", "max", … for subscription logins.
        public var subscriptionType: String?

        public init(version: String?, loggedIn: Bool, authMethod: String?, subscriptionType: String?) {
            self.version = version
            self.loggedIn = loggedIn
            self.authMethod = authMethod
            self.subscriptionType = subscriptionType
        }

        /// Whether this install can run `model`; unknown versions are given the benefit of the doubt.
        public func supports(_ model: ClaudeModel) -> Bool {
            guard let version, let minimum = model.minimumClaudeCodeVersion else { return true }
            return ClaudeCodeBackend.compareVersions(version, minimum) != .orderedAscending
        }
    }

    public static func status(of executable: URL) async -> Status {
        async let versionOutput = try? run(executable, arguments: ["--version"], stdin: "")
        async let authOutput = try? run(executable, arguments: ["auth", "status", "--json"], stdin: "")
        let version = await versionOutput.flatMap { parseVersion(String(decoding: $0, as: UTF8.self)) }
        var status = await authOutput.map(parseAuthStatus) ?? Status(version: nil, loggedIn: false, authMethod: nil, subscriptionType: nil)
        status.version = version
        return status
    }

    /// `claude --version` prints e.g. "2.1.206 (Claude Code)".
    public static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first.map(String.init).flatMap { token in
            token.first?.isNumber == true ? token : nil
        }
    }

    struct AuthStatus: Decodable {
        let loggedIn: Bool?
        let authMethod: String?
        let subscriptionType: String?
    }

    public static func parseAuthStatus(_ data: Data) -> Status {
        let auth = try? JSONDecoder().decode(AuthStatus.self, from: data)
        return Status(version: nil, loggedIn: auth?.loggedIn ?? false,
                      authMethod: auth?.authMethod, subscriptionType: auth?.subscriptionType)
    }

    /// Numeric dotted-version comparison: "2.1.206" < "2.1.280" < "2.10.0".
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Process

    /// Runs `claude` in an empty working directory so no project CLAUDE.md is picked up.
    /// Cancelling the calling task terminates the process.
    static func run(_ executable: URL, arguments: [String], stdin input: String) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory()
        process.environment = environment(for: executable)

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
                    DispatchQueue.global().async {
                        // A child of claude can keep the pipes open after claude exits; don't wait on it forever.
                        _ = group.wait(timeout: .now() + 1)
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
                    // Throws instead of crashing when claude exits before reading (SIGPIPE is ignored at launch).
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdinPipe.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CleanupError.claudeCode(error.localizedDescription))
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM can be ignored; the cleanup timeout must still end.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// An app opened from Finder gets only /usr/bin:/bin:/usr/sbin:/sbin. An npm install of claude
    /// is a `#!/usr/bin/env node` script, so put claude's own folder (where node lives too) first.
    static func environment(
        for executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var environment = base
        environment["PATH"] = (preferred + existing.filter { !preferred.contains($0) }).joined(separator: ":")
        return environment
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
