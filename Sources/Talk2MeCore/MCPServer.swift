import Foundation

// MARK: - OrchestratorTools protocol

/// Behavior injected into MCPServer for each tool call.
/// Real implementation uses AppleScript; tests use stubs.
public protocol OrchestratorTools {
    func openSession(folder: String) throws -> String
    func focusSession(name: String) throws -> String
    func listSessions() throws -> String
    func revealFolder(path: String) throws -> String
}

// MARK: - MCPServer

/// Stateless JSON-RPC 2.0 / MCP server core.
///
/// Call ``handle(_:)`` with one line of incoming data (the newline may or may not be present).
/// Returns response data for requests (messages with an `id`).
/// Returns nil for notifications (no `id`), so the caller can skip writing to stdout.
public struct MCPServer {

    private let tools: any OrchestratorTools

    public init(tools: any OrchestratorTools) {
        self.tools = tools
    }

    // MARK: - Entry point

    public func handle(_ line: Data) -> Data? {
        // Attempt to parse the incoming JSON.
        guard
            let obj = try? JSONSerialization.jsonObject(with: line),
            let request = obj as? [String: Any]
        else {
            // Unparseable → error -32700, id = null
            return encode(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }

        // Notifications have no "id" field — return nil and nothing is written to stdout.
        guard let id = request["id"] else {
            return nil
        }

        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(handleInitialize(id: id, params: params))

        case "tools/list":
            return encode(handleToolsList(id: id))

        case "tools/call":
            return encode(handleToolsCall(id: id, params: params))

        default:
            // Unknown method → -32601
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - initialize

    private func handleInitialize(id: Any, params: [String: Any]) -> [String: Any] {
        // Echo back whatever protocolVersion the client sent.
        let clientVersion = params["protocolVersion"] as? String ?? ""
        let result: [String: Any] = [
            "protocolVersion": clientVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "talk2me", "version": "1.0"]
        ]
        return successResponse(id: id, result: result)
    }

    // MARK: - tools/list

    private func handleToolsList(id: Any) -> [String: Any] {
        let tools: [[String: Any]] = [
            makeTool(
                name: "open_session",
                description: "Open a new Claude Code session in a Terminal window for the given folder.",
                required: ["folder"],
                properties: ["folder": stringProp("Absolute path of the project folder to open.")]
            ),
            makeTool(
                name: "focus_session",
                description: "Bring an existing Claude Code session window to the foreground by name.",
                required: ["name"],
                properties: ["name": stringProp("Session name as returned by list_sessions.")]
            ),
            makeTool(
                name: "list_sessions",
                description: "Return all currently open Claude Code sessions as a JSON array.",
                required: [],
                properties: [:]
            ),
            makeTool(
                name: "reveal_folder",
                description: "Reveal a folder in Finder.",
                required: ["path"],
                properties: ["path": stringProp("Absolute path of the folder to reveal.")]
            ),
        ]
        return successResponse(id: id, result: ["tools": tools])
    }

    // MARK: - tools/call

    private func handleToolsCall(id: Any, params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text = try dispatch(name: name, arguments: arguments)
            return successResponse(id: id, result: toolResult(text: text, isError: false))
        } catch ToolDispatchError.unknownTool {
            // Unknown tool name is a JSON-RPC invalid-params error per spec.
            return errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
        } catch {
            // Tool itself threw — this is a result, NOT a JSON-RPC error.
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return successResponse(id: id, result: toolResult(text: message, isError: true))
        }
    }

    private enum ToolDispatchError: Error {
        case unknownTool
    }

    private func dispatch(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "open_session":
            let folder = arguments["folder"] as? String ?? ""
            return try tools.openSession(folder: folder)
        case "focus_session":
            let sessionName = arguments["name"] as? String ?? ""
            return try tools.focusSession(name: sessionName)
        case "list_sessions":
            return try tools.listSessions()
        case "reveal_folder":
            let path = arguments["path"] as? String ?? ""
            return try tools.revealFolder(path: path)
        default:
            throw ToolDispatchError.unknownTool
        }
    }

    // MARK: - Builders

    private func successResponse(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func toolResult(text: String, isError: Bool) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
    }

    private func makeTool(
        name: String,
        description: String,
        required: [String],
        properties: [String: Any]
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty {
            schema["required"] = required
        }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private func stringProp(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    // MARK: - Encoding

    private func encode(_ dict: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        data.append(0x0A) // newline delimiter for the stdio protocol
        return data
    }
}
