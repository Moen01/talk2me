import Foundation
import Talk2MeCore

/// Runs the Orchestrate voice channel: a dedicated Terminal window with a `claude` orchestrator
/// session that the user talks to. The controller reattaches to a live orchestrator window when one
/// exists, otherwise it launches a new one, then sends the spoken text to it.
///
/// All AppleScript runs through `/usr/bin/osascript` on a background executor so the main thread
/// never blocks on Terminal. The `@MainActor` isolation is for `state`/`onChange`, which the menu
/// bar and SwiftUI views read.
@MainActor
final class OrchestratorController {
    enum State: Equatable {
        case notRunning
        case running(windowID: Int)
    }

    private(set) var state: State = .notRunning { didSet { if state != oldValue { onChange?() } } }
    /// For the menu bar; SwiftUI views observe their own model instead.
    var onChange: (() -> Void)?

    private let settings: AppSettings

    /// Single-flight guard for `ensureLive()`. When a spawn is in progress any
    /// concurrent call to `send()`/`startIfNeeded()` awaits the same task instead
    /// of racing through the no-registry-id check and opening a second window.
    private var ensureTask: Task<Live, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Launches the orchestrator if it is not already live. Returns once the window exists (or the
    /// attempt failed). Used to warm it up before the first spoken line.
    func startIfNeeded() async {
        _ = await ensureLive()
    }

    /// Ensures a live orchestrator, sends `text` to it, focuses its window, and returns the line to
    /// show in the menu bar.
    func send(_ text: String) async -> String {
        let outcome = await ensureLive()
        let windowID: Int
        switch outcome {
        case .success(let id):
            windowID = id
        case .denied:
            return Self.deniedLine
        case .failure(let reason):
            return "Could not reach the orchestrator: \(reason)"
        }

        // Terminal's `do script "x" in window id N` writes to that window's currently SELECTED tab,
        // not a fixed tab. The orchestrator gets its own dedicated window, so this only misfires if
        // the user manually adds and switches tabs in that window — acceptable for v1.
        switch await run(TerminalScript.send(text, toWindowID: windowID)) {
        case .denied:
            return Self.deniedLine
        case .failure(let reason):
            return "Could not reach the orchestrator: \(reason)"
        case .success:
            break
        }

        // Focus is best-effort: the text already landed, so a failure here is not worth surfacing.
        _ = await run(TerminalScript.focusWindow(id: windowID))
        return "Sent to orchestrator."
    }

    // MARK: - Liveness

    private enum Live {
        case success(windowID: Int)
        case denied
        case failure(String)
    }

    /// Reattaches to the registered orchestrator window when it is still alive, otherwise spawns a
    /// fresh one. Keeps `state` and the registry in sync with what it finds.
    ///
    /// Single-flight: concurrent callers (e.g. two rapid `send()` calls) share one in-flight task.
    /// Because this method is `@MainActor` the check-and-set of `ensureTask` is atomic between
    /// suspension points — there is no data race.
    private func ensureLive() async -> Live {
        if let existing = ensureTask {
            return await existing.value
        }
        let task = Task { await self._doEnsureLive() }
        ensureTask = task
        defer { ensureTask = nil }
        return await task.value
    }

    private func _doEnsureLive() async -> Live {
        let registryURL = SessionRegistry.defaultURL()
        var registry = SessionRegistry.load(from: registryURL)

        if let existing = registry.orchestratorWindowID {
            switch await isLiveOrchestrator(windowID: existing) {
            case .alive:
                state = .running(windowID: existing)
                return .success(windowID: existing)
            case .denied:
                return .denied
            case .dead:
                // The window or its claude process is gone; drop it and spawn a new one below.
                registry.orchestratorWindowID = nil
                try? registry.save(to: registryURL)
                state = .notRunning
            }
        }

        return await spawn(registry: registry, registryURL: registryURL)
    }

    private enum Liveness { case alive, dead, denied }

    /// A window is a live orchestrator when it still exists AND its tty shows a `claude`/`node`
    /// process — a bare shell in a reused window is not the orchestrator.
    private func isLiveOrchestrator(windowID: Int) async -> Liveness {
        switch await run(TerminalScript.windowExists(id: windowID)) {
        case .denied: return .denied
        case .failure: return .dead
        case .success(let output):
            guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return .dead }
        }

        switch await run(TerminalScript.ttyOfWindow(id: windowID)) {
        case .denied: return .denied
        case .failure: return .dead
        case .success(let tty):
            let path = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return .dead }
            return await processOnTTYLooksLikeClaude(path) ? .alive : .dead
        }
    }

    /// True when `ps -t <tty>` lists a `claude` or `node` process — claude is an npm `node` script,
    /// so either name means the session is still up.
    private func processOnTTYLooksLikeClaude(_ tty: String) async -> Bool {
        // `ps -t` wants the tty name without the `/dev/` prefix.
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        let result = await Self.runProcess(
            executable: "/bin/ps",
            arguments: ["-t", name, "-o", "comm="]
        )
        guard case .success(let output) = result else { return false }
        return output.lowercased().contains("claude") || output.lowercased().contains("node")
    }

    // MARK: - Spawn

    private func spawn(registry: SessionRegistry, registryURL: URL) async -> Live {
        guard let claude = ClaudeCodeBackend.locate(customPath: claudeCustomPath) else {
            return .failure("Claude Code was not found. Set its path in Settings.")
        }

        let mcpConfigPath: String
        do {
            mcpConfigPath = try writeMCPConfig()
        } catch {
            return .failure("Could not write the MCP config: \(error.localizedDescription)")
        }

        let command = OrchestratorLaunch.shellCommand(
            claudePath: claude.path,
            rootFolder: settings.orchestrateRoot,
            mcpConfigPath: mcpConfigPath
        )

        switch await run(TerminalScript.openWindow(command: command)) {
        case .denied:
            return .denied
        case .failure(let reason):
            return .failure(reason)
        case .success(let output):
            guard let windowID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .failure("Terminal did not return a window id.")
            }
            var registry = registry
            registry.orchestratorWindowID = windowID
            try? registry.save(to: registryURL)
            state = .running(windowID: windowID)
            return .success(windowID: windowID)
        }
    }

    private var claudeCustomPath: String? {
        let trimmed = settings.claudePath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes the MCP config to `~/Library/Application Support/Talk2Me/mcp.json` and returns its path.
    private func writeMCPConfig() throws -> String {
        let json = OrchestratorLaunch.mcpConfigJSON(serverPath: Self.mcpServerPath())
        let url = Self.mcpConfigURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url, options: .atomic)
        return url.path
    }

    /// `~/Library/Application Support/Talk2Me/mcp.json`
    static func mcpConfigURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Talk2Me/mcp.json")
    }

    /// The bundled MCP server. In the packaged app it sits next to the Talk2Me executable; for dev
    /// runs outside a bundle, fall back to the same folder as whatever executable launched us.
    static func mcpServerPath() -> String {
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/talk2me-mcp"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            return dir.appendingPathComponent("talk2me-mcp").path
        }
        return bundled
    }

    // MARK: - osascript

    private static let deniedLine =
        "Allow Talk2Me to control Terminal in System Settings > Privacy & Security > Automation."

    private enum RunResult {
        case success(String)
        case denied
        case failure(String)
    }

    /// Runs AppleScript source through `/usr/bin/osascript -e`.
    private func run(_ script: String) async -> RunResult {
        await Self.runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    /// Runs `executable` with `arguments` off the main actor and classifies the result. An
    /// Apple-events denial (osascript exit code with -1743 / "Not authorized" in stderr) becomes
    /// `.denied`; any other non-zero exit becomes `.failure` carrying the stderr text.
    nonisolated private static func runProcess(executable: String, arguments: [String]) async -> RunResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
            // Detach so the Process setup and pipe reads never run on the main actor.
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(decoding: outData, as: UTF8.self)
                let err = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(out))
                } else if err.contains("-1743") || err.localizedCaseInsensitiveContains("Not authorized") {
                    continuation.resume(returning: .denied)
                } else {
                    continuation.resume(returning: .failure(err.isEmpty ? "exit status \(process.terminationStatus)" : err))
                }
            }
        }
    }
}
