import Foundation
import Talk2MeCore

// talk2me-mcp: stdio JSON-RPC 2.0 / MCP server for the Talk2Me orchestrator.
//
// Claude Code connects here via --mcp-config. It calls the four tools
// (open_session, focus_session, list_sessions, reveal_folder) and receives
// plain-text results that appear in the orchestrator's terminal session.
//
// Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout. Each response
// line is flushed immediately so Claude Code doesn't wait for the buffer.

// MARK: - Error type

/// User-readable errors that surface as tool results (not JSON-RPC errors).
struct MCPToolError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - osascript runner

/// Runs an AppleScript source string via /usr/bin/osascript -e and returns stdout (trimmed).
/// Throws MCPToolError with osascript's stderr on non-zero exit.
func runAppleScript(_ source: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let out = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let err = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard process.terminationStatus == 0 else {
        throw MCPToolError(err.isEmpty ? "osascript exited \(process.terminationStatus)" : err)
    }
    return out
}

// MARK: - LiveOrchestratorTools

/// Real implementation: manages Terminal windows and the session registry.
/// Logic lives here rather than in Talk2MeCore because it spawns processes
/// and cannot be unit-tested without side effects.
struct LiveOrchestratorTools: OrchestratorTools {

    // MARK: open_session

    func openSession(folder: String) throws -> String {
        let expanded = (folder as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw MCPToolError("folder does not exist: \(expanded)")
        }
        guard let claudeURL = ClaudeCodeBackend.locate() else {
            throw MCPToolError("claude binary not found; install Claude Code and try again")
        }

        let command = OrchestratorLaunch.sessionShellCommand(
            claudePath: claudeURL.path,
            folder: expanded
        )
        let script = TerminalScript.openWindow(command: command)
        let output = try runAppleScript(script)

        guard let windowID = Int(output) else {
            throw MCPToolError("unexpected window id from osascript: '\(output)'")
        }

        var registry = SessionRegistry.load(from: SessionRegistry.defaultURL())
        let name = registry.register(folder: expanded, windowID: windowID)
        try registry.save(to: SessionRegistry.defaultURL())

        _ = try runAppleScript(TerminalScript.focusWindow(id: windowID))

        return "Opened session \(name) in \(expanded)"
    }

    // MARK: focus_session

    func focusSession(name: String) throws -> String {
        let registry = SessionRegistry.load(from: SessionRegistry.defaultURL())
        guard let session = registry.sessions.first(where: { $0.name == name }) else {
            throw MCPToolError("no session named \(name)")
        }

        let existsOutput = try runAppleScript(TerminalScript.windowExists(id: session.windowID))
        guard existsOutput == "true" else {
            // The window is gone — prune it from the registry before throwing.
            let pruned = registry.pruned { id in id != session.windowID }
            try? pruned.save(to: SessionRegistry.defaultURL())
            throw MCPToolError("session \(name)'s window is gone")
        }

        _ = try runAppleScript(TerminalScript.focusWindow(id: session.windowID))
        return "Focused \(name)"
    }

    // MARK: list_sessions

    func listSessions() throws -> String {
        var registry = SessionRegistry.load(from: SessionRegistry.defaultURL())
        if registry.sessions.isEmpty { return "No sessions yet." }

        // Build a single liveness map by checking each window once.
        var aliveMap: [Int: Bool] = [:]
        for session in registry.sessions {
            let existsOutput = (try? runAppleScript(TerminalScript.windowExists(id: session.windowID))) ?? "false"
            aliveMap[session.windowID] = (existsOutput == "true")
        }

        // Build the display list from the original set using the pre-computed map.
        var lines: [String] = []
        for session in registry.sessions {
            let alive = aliveMap[session.windowID] ?? false
            lines.append("\(session.name) — \(session.folder) (\(alive ? "alive" : "dead"))")
        }

        // Persist pruned registry so dead sessions don't accumulate.
        let anyDead = aliveMap.values.contains(false)
        if anyDead {
            registry = registry.pruned { id in aliveMap[id] ?? false }
            try? registry.save(to: SessionRegistry.defaultURL())
        }

        return lines.joined(separator: "\n")
    }

    // MARK: reveal_folder

    func revealFolder(path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw MCPToolError("folder does not exist: \(expanded)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [expanded]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MCPToolError("open failed for \(expanded) (exit code \(process.terminationStatus))")
        }

        return "Opened \(expanded) in Finder"
    }
}

// MARK: - stdio loop

// Unbuffered stdout: each response is flushed immediately so Claude Code doesn't
// wait for a full buffer before reading the reply.
let stdout = FileHandle.standardOutput
let stdin = FileHandle.standardInput
let server = MCPServer(tools: LiveOrchestratorTools())

// Read stdin line by line. FileHandle.availableData blocks until EOF in a pipe,
// so we read the raw data and split on newlines ourselves.
var buffer = Data()

while true {
    // availableData on a pipe blocks until at least one byte is available,
    // then returns everything currently in the kernel buffer (not necessarily a full line).
    let chunk = stdin.availableData
    if chunk.isEmpty { break }   // EOF
    buffer.append(chunk)

    // Process every complete newline-terminated line in the buffer.
    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let lineData = buffer[buffer.startIndex...newlineIndex]
        buffer.removeSubrange(buffer.startIndex...newlineIndex)

        if let response = server.handle(lineData) {
            // MCPServer.handle already appends the newline delimiter.
            stdout.write(response)
        }
    }
}

// Flush any partial line at EOF (no trailing newline in the input).
if !buffer.isEmpty, let response = server.handle(buffer) {
    stdout.write(response)
}
