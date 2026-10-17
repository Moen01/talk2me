import Foundation

/// Cleans up a transcript with the Claude Messages API, using the user's own API key.
///
/// Swift has no official Anthropic SDK, so this calls `POST /v1/messages` directly.
public struct AnthropicMessagesBackend: CleanupBackend {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: @Sendable () -> String?
    private let session: URLSession

    public init(session: URLSession = .shared, apiKey: @escaping @Sendable () -> String?) {
        self.session = session
        self.apiKey = apiKey
    }

    public func cleanUp(_ transcript: String, model: ClaudeModel, instructions: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw CleanupError.missingAPIKey
        }
        let request = try Self.makeRequest(transcript: transcript, model: model, instructions: instructions, apiKey: key)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parseResponse(data: data, status: status)
    }

    // MARK: - Wire format

    struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct OutputConfig: Encodable {
            let effort: String
        }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let output_config: OutputConfig
        /// Re-runs a refused request on a fallback model chosen by the API. Omitted when nil.
        let fallbacks: String?
    }

    struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    struct ErrorBody: Decodable {
        struct APIError: Decodable {
            let type: String
            let message: String
        }
        let error: APIError
    }

    public static func makeRequest(transcript: String, model: ClaudeModel, instructions: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if model.supportsServerFallbacks {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        let body = RequestBody(
            model: model.rawValue,
            max_tokens: 16_000,
            system: instructions,
            messages: [.init(role: "user", content: CleanupPrompt.userMessage(for: transcript))],
            // Cleanup is a light task; low effort keeps the hotkey-to-paste delay short.
            output_config: .init(effort: "low"),
            fallbacks: model.supportsServerFallbacks ? "default" : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public static func parseResponse(data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch status {
            case 401, 403: throw CleanupError.invalidAPIKey(message)
            case 429: throw CleanupError.rateLimited(message)
            default: throw CleanupError.http(status: status, message: message)
            }
        }
        let body: ResponseBody
        do {
            body = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw CleanupError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if body.stop_reason == "refusal" { throw CleanupError.refused }
        // Thinking and fallback blocks carry no output text; only text blocks are the answer.
        let text = body.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        return CleanupPrompt.sanitize(text)
    }
}
