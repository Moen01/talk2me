import Foundation
import Testing
@testable import Talk2MeCore

struct AnthropicMessagesBackendTests {
    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func requestCarriesKeyModelEffortAndTranscript() throws {
        let request = try AnthropicMessagesBackend.makeRequest(
            transcript: "hello there", model: .haiku, instructions: "SYSTEM", apiKey: "sk-test")
        #expect(request.url == AnthropicMessagesBackend.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try body(of: request)
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["system"] as? String == "SYSTEM")
        #expect((json["output_config"] as? [String: String])?["effort"] == "low")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["content"] == "<transcript>\nhello there\n</transcript>")
    }

    @Test func fallbacksOnlyForModelsThatSupportThem() throws {
        let haiku = try AnthropicMessagesBackend.makeRequest(transcript: "x", model: .haiku, instructions: "", apiKey: "k")
        #expect(try body(of: haiku)["fallbacks"] == nil)
        #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)

        let opus = try AnthropicMessagesBackend.makeRequest(transcript: "x", model: .opus, instructions: "", apiKey: "k")
        #expect(try body(of: opus)["fallbacks"] as? String == "default")
        #expect(opus.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
    }

    @Test func parsesTextBlocksAndSkipsThinking() throws {
        let json = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"  Hello, there. "}],"stop_reason":"end_turn"}"#
        #expect(try AnthropicMessagesBackend.parseResponse(data: Data(json.utf8), status: 200) == "Hello, there.")
    }

    @Test func refusalIsAnError() {
        let json = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: CleanupError.refused) {
            try AnthropicMessagesBackend.parseResponse(data: Data(json.utf8), status: 200)
        }
    }

    @Test func httpErrorsMapToCases() {
        let error = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(throws: CleanupError.invalidAPIKey("invalid x-api-key")) {
            try AnthropicMessagesBackend.parseResponse(data: Data(error.utf8), status: 401)
        }
        #expect(throws: CleanupError.rateLimited("slow down")) {
            try AnthropicMessagesBackend.parseResponse(
                data: Data(#"{"error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8), status: 429)
        }
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        let backend = AnthropicMessagesBackend { nil }
        await #expect(throws: CleanupError.missingAPIKey) {
            try await backend.cleanUp("x", model: .haiku, instructions: "")
        }
    }
}

struct ClaudeCodeBackendTests {
    @Test func argumentsRunOneToolFreeTurn() {
        let args = ClaudeCodeBackend.arguments(model: .sonnet, instructions: "SYS")
        #expect(args.first == "-p")
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args[args.firstIndex(of: "--model")! + 1] == "claude-sonnet-5-5")
        #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "SYS")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--output-format")! + 1] == "json")
        // --bare ignores the subscription login, so it must never be used here.
        #expect(!args.contains("--bare"))
    }

    @Test func parsesSuccessfulResult() throws {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"Move the meeting to Thursday.\n"}"#
        #expect(try ClaudeCodeBackend.parseOutput(Data(json.utf8)) == "Move the meeting to Thursday.")
    }

    @Test func reportsErrorResult() {
        let json = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(throws: CleanupError.claudeCode("Not logged in · Please run /login")) {
            try ClaudeCodeBackend.parseOutput(Data(json.utf8))
        }
    }

    @Test func nonJSONOutputIsAnError() {
        #expect(throws: CleanupError.self) { try ClaudeCodeBackend.parseOutput(Data("boom".utf8)) }
    }
}

struct ClaudeCodeStatusTests {
    @Test func parsesVersionLine() {
        #expect(ClaudeCodeBackend.parseVersion("2.1.206 (Claude Code)\n") == "2.1.206")
        #expect(ClaudeCodeBackend.parseVersion("command not found") == nil)
    }

    @Test func parsesAuthStatus() {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#
        let status = ClaudeCodeBackend.parseAuthStatus(Data(json.utf8))
        #expect(status.loggedIn)
        #expect(status.authMethod == "claude.ai")
        #expect(status.subscriptionType == "pro")
        #expect(!ClaudeCodeBackend.parseAuthStatus(Data("not json".utf8)).loggedIn)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ClaudeCodeBackend.compareVersions("2.1.206", "2.1.280") == .orderedAscending)
        #expect(ClaudeCodeBackend.compareVersions("2.10.0", "2.9.9") == .orderedDescending)
        #expect(ClaudeCodeBackend.compareVersions("2.1.280", "2.1.280") == .orderedSame)
    }

    @Test func opusNeedsANewerClaudeCode() {
        let old = ClaudeCodeBackend.Status(version: "2.1.206", loggedIn: true, authMethod: nil, subscriptionType: nil)
        #expect(!old.supports(.opus))
        #expect(old.supports(.sonnet))
        let unknown = ClaudeCodeBackend.Status(version: nil, loggedIn: true, authMethod: nil, subscriptionType: nil)
        #expect(unknown.supports(.opus))
    }
}
