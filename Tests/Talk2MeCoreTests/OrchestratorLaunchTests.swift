import Foundation
import Testing
@testable import Talk2MeCore

struct OrchestratorLaunchTests {

    // MARK: - allowedTools / disallowedTools

    @Test func allowedToolsExactList() {
        #expect(OrchestratorLaunch.allowedTools == [
            "mcp__talk2me__*",
            "Read",
            "Glob",
            "Grep",
            "Bash(ls:*)",
            "Bash(git status:*)",
        ])
    }

    @Test func allowedToolsHasNoWriteCapableBashPrefixes() {
        // find (-delete/-exec), tree (-o) and git log (--output) can all write to disk.
        let joined = OrchestratorLaunch.allowedTools.joined(separator: ",")
        #expect(!joined.contains("Bash(find"))
        #expect(!joined.contains("Bash(tree"))
        #expect(!joined.contains("Bash(git log"))
    }

    @Test func disallowedToolsExactList() {
        #expect(OrchestratorLaunch.disallowedTools == ["Edit", "Write", "NotebookEdit"])
    }

    // MARK: - claudeArguments

    @Test func claudeArgumentsContainsAllFlags() {
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: "/tmp/mcp.json")
        // Flags must appear in order per spec
        let appendIdx = args.firstIndex(of: "--append-system-prompt")
        let mcpIdx = args.firstIndex(of: "--mcp-config")
        let strictIdx = args.firstIndex(of: "--strict-mcp-config")
        let allowedIdx = args.firstIndex(of: "--allowedTools")
        let disallowedIdx = args.firstIndex(of: "--disallowedTools")

        #expect(appendIdx != nil)
        #expect(mcpIdx != nil)
        #expect(strictIdx != nil)
        #expect(allowedIdx != nil)
        #expect(disallowedIdx != nil)
    }

    @Test func claudeArgumentsSystemPromptFollowsFlag() {
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: "/tmp/mcp.json")
        guard let idx = args.firstIndex(of: "--append-system-prompt") else {
            Issue.record("--append-system-prompt flag missing")
            return
        }
        #expect(idx + 1 < args.count)
        #expect(args[idx + 1] == OrchestratorLaunch.systemPrompt)
    }

    @Test func claudeArgumentsMcpConfigPathFollowsFlag() {
        let path = "/some/path/mcp.json"
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: path)
        guard let idx = args.firstIndex(of: "--mcp-config") else {
            Issue.record("--mcp-config flag missing")
            return
        }
        #expect(idx + 1 < args.count)
        #expect(args[idx + 1] == path)
    }

    @Test func claudeArgumentsAllowedToolsJoined() {
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: "/tmp/mcp.json")
        guard let idx = args.firstIndex(of: "--allowedTools") else {
            Issue.record("--allowedTools flag missing")
            return
        }
        #expect(idx + 1 < args.count)
        #expect(args[idx + 1] == OrchestratorLaunch.allowedTools.joined(separator: ","))
    }

    @Test func claudeArgumentsDisallowedToolsJoined() {
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: "/tmp/mcp.json")
        guard let idx = args.firstIndex(of: "--disallowedTools") else {
            Issue.record("--disallowedTools flag missing")
            return
        }
        #expect(idx + 1 < args.count)
        #expect(args[idx + 1] == OrchestratorLaunch.disallowedTools.joined(separator: ","))
    }

    @Test func claudeArgumentsExactSequence() {
        let path = "/tmp/mcp.json"
        let args = OrchestratorLaunch.claudeArguments(mcpConfigPath: path)
        #expect(args == [
            "--append-system-prompt",
            OrchestratorLaunch.systemPrompt,
            "--mcp-config",
            path,
            "--strict-mcp-config",
            "--allowedTools",
            OrchestratorLaunch.allowedTools.joined(separator: ","),
            "--disallowedTools",
            OrchestratorLaunch.disallowedTools.joined(separator: ","),
        ])
    }

    // MARK: - shellCommand

    @Test func shellCommandEscapesSingleQuoteInFolder() {
        // root folder with both a space and a single quote — the worst case for sh quoting
        let cmd = OrchestratorLaunch.shellCommand(
            claudePath: "/usr/local/bin/claude",
            rootFolder: "/home/user/my's folder",
            mcpConfigPath: "/tmp/mcp.json"
        )
        // The folder part must use shell single-quote escaping: ' → '\''
        #expect(cmd.hasPrefix("cd '/home/user/my'\\''s folder'"))
    }

    @Test func shellCommandEscapesSingleQuoteInClaudePath() {
        let cmd = OrchestratorLaunch.shellCommand(
            claudePath: "/path/with'quote/claude",
            rootFolder: "/home/user",
            mcpConfigPath: "/tmp/mcp.json"
        )
        #expect(cmd.contains("'/path/with'\\''quote/claude'"))
    }

    @Test func shellCommandStructure() {
        let cmd = OrchestratorLaunch.shellCommand(
            claudePath: "/usr/bin/claude",
            rootFolder: "/workspace",
            mcpConfigPath: "/tmp/mcp.json"
        )
        #expect(cmd.hasPrefix("cd '/workspace' && '/usr/bin/claude'"))
    }

    @Test func shellCommandQuotesSystemPromptCorrectly() {
        let cmd = OrchestratorLaunch.shellCommand(
            claudePath: "/bin/claude",
            rootFolder: "/tmp",
            mcpConfigPath: "/tmp/mcp.json"
        )

        // The system prompt must be single-quote-escaped in the command.
        // Verify that the prompt is wrapped in single quotes and any interior
        // single quotes would be escaped as '\''
        let prompt = OrchestratorLaunch.systemPrompt
        let expectedQuoted = "'" + prompt.replacingOccurrences(of: "'", with: "'" + "\\" + "'" + "'") + "'"

        // The command must contain the correctly quoted prompt.
        // This pins the quoting rule so a future quote in the prompt cannot silently break the command.
        #expect(cmd.contains(expectedQuoted), "Prompt must be properly quoted in command")
    }

    // MARK: - sessionShellCommand

    @Test func sessionShellCommandStructure() {
        let cmd = OrchestratorLaunch.sessionShellCommand(
            claudePath: "/usr/bin/claude",
            folder: "/workspace"
        )
        #expect(cmd == "cd '/workspace' && '/usr/bin/claude'")
    }

    @Test func sessionShellCommandEscapesSpaceAndQuote() {
        let cmd = OrchestratorLaunch.sessionShellCommand(
            claudePath: "/usr/bin/claude",
            folder: "/home/user/my's folder"
        )
        #expect(cmd == "cd '/home/user/my'\\''s folder' && '/usr/bin/claude'")
    }

    // MARK: - mcpConfigJSON

    @Test func mcpConfigJSONStructure() throws {
        let json = OrchestratorLaunch.mcpConfigJSON(serverPath: "/usr/local/bin/talk2me-mcp")
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let mcpServers = try #require(decoded["mcpServers"] as? [String: Any])
        let talk2me = try #require(mcpServers["talk2me"] as? [String: Any])
        let command = try #require(talk2me["command"] as? String)
        #expect(command == "/usr/local/bin/talk2me-mcp")
    }

    @Test func mcpConfigJSONContainsServerKey() {
        let json = OrchestratorLaunch.mcpConfigJSON(serverPath: "/bin/mcp")
        #expect(json.contains("\"talk2me\""))
        #expect(json.contains("\"mcpServers\""))
        #expect(json.contains("\"/bin/mcp\""))
    }

    @Test func mcpConfigJSONOmitsEnvWhenClaudePathEmpty() {
        #expect(!OrchestratorLaunch.mcpConfigJSON(serverPath: "/bin/mcp").contains("env"))
        #expect(!OrchestratorLaunch.mcpConfigJSON(serverPath: "/bin/mcp", claudePath: "").contains("env"))
        #expect(!OrchestratorLaunch.mcpConfigJSON(serverPath: "/bin/mcp", claudePath: "   ").contains("env"))
    }

    @Test func mcpConfigJSONEmitsClaudePathInEnv() throws {
        let json = OrchestratorLaunch.mcpConfigJSON(
            serverPath: "/bin/mcp", claudePath: "/opt/homebrew/bin/claude")
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mcpServers = try #require(decoded["mcpServers"] as? [String: Any])
        let talk2me = try #require(mcpServers["talk2me"] as? [String: Any])
        #expect(talk2me["command"] as? String == "/bin/mcp")
        let env = try #require(talk2me["env"] as? [String: Any])
        #expect(env["TALK2ME_CLAUDE_PATH"] as? String == "/opt/homebrew/bin/claude")
    }

    @Test func mcpConfigJSONEscapesClaudePath() throws {
        // A claude path with a quote and a backslash must round-trip through valid JSON.
        let weird = #"/path/with"quote\back/claude"#
        let json = OrchestratorLaunch.mcpConfigJSON(serverPath: "/bin/mcp", claudePath: weird)
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mcpServers = try #require(decoded["mcpServers"] as? [String: Any])
        let talk2me = try #require(mcpServers["talk2me"] as? [String: Any])
        let env = try #require(talk2me["env"] as? [String: Any])
        #expect(env["TALK2ME_CLAUDE_PATH"] as? String == weird)
    }

    @Test func mcpConfigJSONEscapesControlCharacters() throws {
        // Path with newline, tab, and carriage return must be escaped
        let pathWithNewline = "/path/with\nnewline"
        let json = OrchestratorLaunch.mcpConfigJSON(serverPath: pathWithNewline)

        // The JSON must be valid and round-trip correctly
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let mcpServers = try #require(decoded["mcpServers"] as? [String: Any])
        let talk2me = try #require(mcpServers["talk2me"] as? [String: Any])
        let command = try #require(talk2me["command"] as? String)

        // Path must round-trip exactly
        #expect(command == pathWithNewline)

        // Also test with tab and carriage return
        let pathWithTab = "/path/with\ttab"
        let jsonTab = OrchestratorLaunch.mcpConfigJSON(serverPath: pathWithTab)
        let dataTab = try #require(jsonTab.data(using: .utf8))
        let decodedTab = try #require(
            JSONSerialization.jsonObject(with: dataTab) as? [String: Any]
        )
        let mcpServersTab = try #require(decodedTab["mcpServers"] as? [String: Any])
        let talk2meTab = try #require(mcpServersTab["talk2me"] as? [String: Any])
        let commandTab = try #require(talk2meTab["command"] as? String)
        #expect(commandTab == pathWithTab)

        let pathWithCR = "/path/with\rcarriage"
        let jsonCR = OrchestratorLaunch.mcpConfigJSON(serverPath: pathWithCR)
        let dataCR = try #require(jsonCR.data(using: .utf8))
        let decodedCR = try #require(
            JSONSerialization.jsonObject(with: dataCR) as? [String: Any]
        )
        let mcpServersCR = try #require(decodedCR["mcpServers"] as? [String: Any])
        let talk2meCR = try #require(mcpServersCR["talk2me"] as? [String: Any])
        let commandCR = try #require(talk2meCR["command"] as? String)
        #expect(commandCR == pathWithCR)
    }

    // MARK: - systemPrompt

    @Test func systemPromptIsNonEmpty() {
        #expect(!OrchestratorLaunch.systemPrompt.isEmpty)
    }

    @Test func systemPromptMentionsMCPTools() {
        // Must reference the MCP tools by name so the model knows what to call
        let prompt = OrchestratorLaunch.systemPrompt.lowercased()
        #expect(prompt.contains("open_session") || prompt.contains("mcp"))
    }
}
