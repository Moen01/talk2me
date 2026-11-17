import Foundation
import Testing
@testable import Talk2MeCore

// MARK: - Stub

/// A simple stub conforming to OrchestratorTools for use in tests.
/// Returns a preset string from each method, or throws if told to.
struct StubTools: OrchestratorTools {
    var openSessionResult: String = "opened"
    var focusSessionResult: String = "focused"
    var listSessionsResult: String = "[]"
    var revealFolderResult: String = "revealed"
    var shouldThrow: Bool = false
    var errorMessage: String = "tool exploded"

    func openSession(folder: String) throws -> String {
        if shouldThrow { throw StubError(message: errorMessage) }
        return openSessionResult
    }

    func focusSession(name: String) throws -> String {
        if shouldThrow { throw StubError(message: errorMessage) }
        return focusSessionResult
    }

    func listSessions() throws -> String {
        if shouldThrow { throw StubError(message: errorMessage) }
        return listSessionsResult
    }

    func revealFolder(path: String) throws -> String {
        if shouldThrow { throw StubError(message: errorMessage) }
        return revealFolderResult
    }
}

struct StubError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Helpers

/// Encodes a dictionary to a newline-terminated JSON Data line.
private func jsonLine(_ dict: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: dict)
    data.append(0x0A) // newline
    return data
}

/// Decodes a Data response from MCPServer.handle into a dictionary.
private func decode(_ data: Data) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: data)
    return try #require(obj as? [String: Any])
}

// MARK: - Tests

struct MCPServerTests {

    // MARK: - initialize

    @Test func initializeEchoesProtocolVersion() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05", "clientInfo": ["name": "test", "version": "0"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
    }

    @Test func initializeReturnsServerInfo() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "talk2me")
        #expect(serverInfo["version"] as? String == "1.0")
    }

    @Test func initializeReturnsToolsCapability() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        // capabilities.tools must be present (empty object is fine)
        #expect(capabilities["tools"] != nil)
    }

    @Test func initializeEchoesId() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 42,
            "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        #expect(dict["id"] as? Int == 42)
    }

    // MARK: - notifications/initialized

    @Test func notificationsInitializedReturnsNil() throws {
        let server = MCPServer(tools: StubTools())
        let notification = try jsonLine([
            "jsonrpc": "2.0",
            // No "id" field — this is a notification
            "method": "notifications/initialized"
        ])
        let result = server.handle(notification)
        #expect(result == nil)
    }

    // MARK: - tools/list

    @Test func toolsListReturnsExactFourTools() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 4)
    }

    @Test func toolsListNamesInOrder() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["open_session", "focus_session", "list_sessions", "reveal_folder"])
    }

    @Test func toolsListEachHasDescription() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        for tool in tools {
            let desc = tool["description"] as? String
            #expect(desc != nil && !desc!.isEmpty)
        }
    }

    @Test func toolsListOpenSessionHasFolderProperty() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let openSession = try #require(tools.first { $0["name"] as? String == "open_session" })
        let inputSchema = try #require(openSession["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let required = try #require(inputSchema["required"] as? [String])
        #expect(properties["folder"] != nil)
        #expect(required.contains("folder"))
    }

    @Test func toolsListFocusSessionHasNameProperty() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let focusSession = try #require(tools.first { $0["name"] as? String == "focus_session" })
        let inputSchema = try #require(focusSession["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let required = try #require(inputSchema["required"] as? [String])
        #expect(properties["name"] != nil)
        #expect(required.contains("name"))
    }

    @Test func toolsListRevealFolderHasPathProperty() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let revealFolder = try #require(tools.first { $0["name"] as? String == "reveal_folder" })
        let inputSchema = try #require(revealFolder["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let required = try #require(inputSchema["required"] as? [String])
        #expect(properties["path"] != nil)
        #expect(required.contains("path"))
    }

    @Test func toolsListListSessionsHasNoRequiredProps() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let listSessions = try #require(tools.first { $0["name"] as? String == "list_sessions" })
        let inputSchema = try #require(listSessions["inputSchema"] as? [String: Any])
        // required array must be absent or empty
        let required = inputSchema["required"] as? [String] ?? []
        #expect(required.isEmpty)
    }

    // MARK: - tools/call: success

    @Test func toolsCallOpenSessionReachesStub() throws {
        var stub = StubTools()
        stub.openSessionResult = "Session opened at /tmp/myproject"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": ["name": "open_session", "arguments": ["folder": "/tmp/myproject"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let first = try #require(content.first)
        #expect(first["type"] as? String == "text")
        #expect(first["text"] as? String == "Session opened at /tmp/myproject")
        #expect(result["isError"] as? Bool == false)
    }

    @Test func toolsCallFocusSessionReachesStub() throws {
        var stub = StubTools()
        stub.focusSessionResult = "Focused on myproject"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": ["name": "focus_session", "arguments": ["name": "myproject"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Focused on myproject")
        #expect(result["isError"] as? Bool == false)
    }

    @Test func toolsCallListSessionsReachesStub() throws {
        var stub = StubTools()
        stub.listSessionsResult = "[\"myproject\"]"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": ["name": "list_sessions", "arguments": [:] as [String: Any]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "[\"myproject\"]")
        #expect(result["isError"] as? Bool == false)
    }

    @Test func toolsCallRevealFolderReachesStub() throws {
        var stub = StubTools()
        stub.revealFolderResult = "Revealed /tmp"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": ["name": "reveal_folder", "arguments": ["path": "/tmp"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Revealed /tmp")
        #expect(result["isError"] as? Bool == false)
    }

    // MARK: - tools/call: error (tool throws)

    @Test func toolsCallThrowingToolReturnsIsErrorTrue() throws {
        var stub = StubTools()
        stub.shouldThrow = true
        stub.errorMessage = "tool exploded"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": ["name": "open_session", "arguments": ["folder": "/tmp"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        // Must be a result (not a JSON-RPC error) even when the tool throws
        #expect(dict["error"] == nil)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "tool exploded")
    }

    @Test func toolsCallThrowingToolPreservesErrorMessage() throws {
        var stub = StubTools()
        stub.shouldThrow = true
        stub.errorMessage = "AppleScript failed: cannot open window"
        let server = MCPServer(tools: stub)
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 21,
            "method": "tools/call",
            "params": ["name": "focus_session", "arguments": ["name": "x"]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        let result = try #require(dict["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "AppleScript failed: cannot open window")
    }

    // MARK: - tools/call: unknown tool name

    @Test func toolsCallUnknownToolNameReturnsError32602() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": ["name": "nonexistent_tool", "arguments": [:] as [String: Any]]
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        #expect(dict["result"] == nil)
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
    }

    // MARK: - Unknown method

    @Test func unknownMethodReturnsError32601() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 99,
            "method": "tools/something_we_dont_know"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        #expect(dict["result"] == nil)
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    // MARK: - Unparseable JSON

    @Test func unparseableInputReturnsError32700WithNullId() throws {
        let server = MCPServer(tools: StubTools())
        let garbage = Data("not json at all {{{".utf8)
        let response = try #require(server.handle(garbage))
        let dict = try decode(response)
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
        // id must be null — in JSONSerialization this comes back as NSNull
        #expect(dict["id"] is NSNull)
    }

    // MARK: - jsonrpc field in response

    @Test func responseAlwaysHasJsonrpc20() throws {
        let server = MCPServer(tools: StubTools())
        let request = try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        let response = try #require(server.handle(request))
        let dict = try decode(response)
        #expect(dict["jsonrpc"] as? String == "2.0")
    }
}
