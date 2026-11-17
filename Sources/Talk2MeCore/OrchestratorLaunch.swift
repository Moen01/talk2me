/// Builds the CLI arguments, shell commands, system prompt, and MCP config JSON
/// needed to launch a `claude` orchestrator session for Talk2Me.
///
/// This is a pure configuration layer — no execution happens here. The caller
/// (e.g. `TerminalScript.openWindow(command:)`) receives the final strings and
/// decides how to run them.
public enum OrchestratorLaunch {

    // MARK: - Tool lists

    /// Tools the orchestrator is allowed to call.
    ///
    /// Limited to read-only exploration and the Talk2Me MCP server so the
    /// orchestrator can navigate sessions without touching project files.
    public static let allowedTools: [String] = [
        "mcp__talk2me__*",
        "Read",
        "Glob",
        "Grep",
        "Bash(ls:*)",
        "Bash(find:*)",
        "Bash(tree:*)",
        "Bash(git status:*)",
        "Bash(git log:*)",
    ]

    /// Tools the orchestrator must never call.
    public static let disallowedTools: [String] = [
        "Edit",
        "Write",
        "NotebookEdit",
    ]

    // MARK: - System prompt

    /// System prompt appended to every orchestrator session.
    ///
    /// Tells the model its role: navigator and dispatcher, not implementer.
    public static let systemPrompt: String = """
    You are a navigator and dispatcher for Talk2Me.

    Your job:
    - Use the MCP tools (open_session, focus_session, list_sessions, reveal_folder) to manage windows and sessions on behalf of the user.
    - Answer short read-only questions about the project — browse folders, read files, explain structure — but never edit, write, or run code that changes anything.
    - Never do project work yourself. If the user asks you to implement something, open the right session for them instead.

    Keep replies very short. The user speaks to you and reads your answer in a terminal, usually about to speak again. One or two sentences is enough unless a list genuinely helps.
    """

    // MARK: - Arguments and commands

    /// Returns the CLI argument array for launching `claude` as an orchestrator.
    ///
    /// - Parameter mcpConfigPath: Path to the MCP config JSON file on disk.
    public static func claudeArguments(mcpConfigPath: String) -> [String] {
        [
            "--append-system-prompt",
            systemPrompt,
            "--mcp-config",
            mcpConfigPath,
            "--strict-mcp-config",
            "--allowedTools",
            allowedTools.joined(separator: ","),
            "--disallowedTools",
            disallowedTools.joined(separator: ","),
        ]
    }

    /// Builds a shell command string that changes into `rootFolder` and launches
    /// the orchestrator session.
    ///
    /// Single quotes wrap every path component; literal `'` characters inside a
    /// path are escaped as `'\''` (end quote, escaped quote, reopen quote).
    /// This is the string passed to `TerminalScript.openWindow(command:)`.
    ///
    /// - Parameters:
    ///   - claudePath: Absolute path to the `claude` binary.
    ///   - rootFolder: Working directory to `cd` into before launching.
    ///   - mcpConfigPath: Path to the MCP config JSON file.
    public static func shellCommand(
        claudePath: String,
        rootFolder: String,
        mcpConfigPath: String
    ) -> String {
        let args = claudeArguments(mcpConfigPath: mcpConfigPath)
        let argString = args.map { shellQuote($0) }.joined(separator: " ")
        return "cd \(shellQuote(rootFolder)) && \(shellQuote(claudePath)) \(argString)"
    }

    /// Builds a plain `cd` + `claude` command with no orchestrator flags.
    ///
    /// Used by Task 7 to open a regular project session in a folder.
    ///
    /// - Parameters:
    ///   - claudePath: Absolute path to the `claude` binary.
    ///   - folder: Working directory to `cd` into.
    public static func sessionShellCommand(claudePath: String, folder: String) -> String {
        "cd \(shellQuote(folder)) && \(shellQuote(claudePath))"
    }

    // MARK: - MCP config JSON

    /// Returns a JSON string for `--mcp-config` that registers Talk2Me's MCP server.
    ///
    /// Format: `{"mcpServers":{"talk2me":{"command":"<path>"}}}`.
    ///
    /// - Parameter serverPath: Absolute path to the MCP server binary.
    public static func mcpConfigJSON(serverPath: String) -> String {
        // Build manually to avoid Foundation import overhead and guarantee key order.
        // Escape characters in order: backslash, quote, then control characters.
        let escaped = serverPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
        return #"{"mcpServers":{"talk2me":{"command":"\#(escaped)"}}}"#
    }

    // MARK: - Private helpers

    /// Wraps `s` in single quotes for POSIX shell, escaping any `'` inside as `'\''`.
    private static func shellQuote(_ s: String) -> String {
        // End the single-quoted segment, emit a literal quote, reopen single-quoting.
        // The replacement string is: '  then \'  then '
        // Written as concat to avoid quoting issues inside the Swift literal.
        let replacement = "'" + "\\" + "'" + "'"
        let escaped = s.replacingOccurrences(of: "'", with: replacement)
        return "'" + escaped + "'"
    }
}
