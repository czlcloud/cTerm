import Foundation

// MARK: - Chat Message

/// A single message in a chat conversation. The `role` field uses standard
/// API roles: "system", "user", "assistant", or "tool".
public struct AIChatMessage: Codable, Sendable {
    public let role: String
    public let content: String
    /// Optional name of the participant (used by some providers for
    /// multi-agent scenarios).
    public let name: String?

    public init(role: String, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}

// MARK: - Tool Spec

/// Describes a function tool that the model may invoke.
public struct AIToolSpec {
    public let name: String
    public let description: String
    /// JSON Schema object describing the tool's parameters.
    /// Example: `["type": "object", "properties": [...], "required": [...]]`
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Errors

/// Errors that can occur during API communication.
public enum AIAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case apiError(String)
    case unsupportedProvider
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API endpoint URL."
        case .invalidResponse:
            return "Invalid or unexpected response from the API."
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .decodingError(let error):
            return "Failed to decode the API response: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .unsupportedProvider:
            return "The provider type is not supported."
        case .missingAPIKey:
            return "API key is missing. Check the provider configuration."
        }
    }
}

// MARK: - Router

/// Routes chat completion requests to the appropriate provider API
/// (OpenAI-compatible or Anthropic) and parses the response.
///
/// The following provider types are supported:
/// - `openAI`, `openAICompatible`, `ollama` → OpenAI Chat Completions format
/// - `anthropic` → Anthropic Messages API format
/// - `custom` → Uses the `baseURL` as-is; defaults to OpenAI format
public final class APIRouter: @unchecked Sendable {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Send Message

    /// Send a chat completion request and return the model's text response
    /// together with token usage counts.
    ///
    /// - Parameters:
    ///   - provider: The provider configuration (determines endpoint & auth).
    ///   - model:    The specific model to invoke.
    ///   - messages: Conversation history (system / user / assistant).
    ///   - tools:    Optional function-tool definitions.
    /// - Returns: A tuple containing the response text and `(input, output)`
    ///   token usage.
    /// - Throws: `AIAPIError` on network failure, HTTP error, or parse failure.
    public func sendMessage(
        provider: AIProviderConfig,
        model: AIModel,
        messages: [AIChatMessage],
        tools: [AIToolSpec]? = nil,
        apiKey: String? = nil
    ) async throws -> (content: String, usage: (input: Int, output: Int)) {

        // 1. Build endpoint URL --------------------------------------------------
        let url = try endpointURL(for: provider)

        // 2. Build headers --------------------------------------------------------
        let resolvedKey = apiKey ?? provider.apiKeyRef
        var headers: [String: String] = ["Content-Type": "application/json"]
        switch provider.providerType {
        case .anthropic:
            headers["x-api-key"] = resolvedKey
            headers["anthropic-version"] = "2023-06-01"
        default:
            headers["Authorization"] = "Bearer \(resolvedKey)"
        }

        // 3. Build request body ---------------------------------------------------
        let body: [String: Any]
        switch provider.providerType {
        case .anthropic:
            body = buildAnthropicBody(provider: provider, model: model, messages: messages, tools: tools)
        default:
            body = buildOpenAIBody(provider: provider, model: model, messages: messages, tools: tools)
        }

        // 4. Create URLRequest ----------------------------------------------------
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        // 5. Send -----------------------------------------------------------------
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIAPIError.apiError("Network request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAPIError.invalidResponse
        }

        // 6. Parse response -------------------------------------------------------
        switch provider.providerType {
        case .anthropic:
            return try parseAnthropicResponse(data: data, statusCode: httpResponse.statusCode)
        default:
            return try parseOpenAIResponse(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - URL Builder

    private func endpointURL(for provider: AIProviderConfig) throws -> URL {
        let base: String
        switch provider.providerType {
        case .openAI:
            base = provider.baseURL ?? "https://api.openai.com"
        case .anthropic:
            base = provider.baseURL ?? "https://api.anthropic.com"
        case .ollama:
            base = provider.baseURL ?? "http://localhost:11434"
        case .openAICompatible, .custom:
            guard let b = provider.baseURL else { throw AIAPIError.invalidURL }
            base = b
        }

        let path: String
        switch provider.providerType {
        case .anthropic:
            path = "/v1/messages"
        case .custom:
            path = "" // use the full URL as-is
        default:
            path = "/v1/chat/completions"
        }

        return try buildURL(base: base, path: path)
    }

    /// Joins `base` and `path` while handling trailing slashes cleanly.
    private func buildURL(base: String, path: String) throws -> URL {
        var baseStr = base
        if baseStr.hasSuffix("/") {
            baseStr = String(baseStr.dropLast())
        }
        guard var components = URLComponents(string: baseStr) else {
            throw AIAPIError.invalidURL
        }
        let currentPath = components.path
        if currentPath.hasSuffix("/") {
            components.path = String(currentPath.dropLast()) + path
        } else {
            components.path = currentPath + path
        }
        guard let url = components.url else {
            throw AIAPIError.invalidURL
        }
        return url
    }

    // MARK: - OpenAI-Compatible Body

    private func buildOpenAIBody(
        provider: AIProviderConfig,
        model: AIModel,
        messages: [AIChatMessage],
        tools: [AIToolSpec]?
    ) -> [String: Any] {
        var apiMessages: [[String: Any]] = []

        // Inject system prompt from model parameters
        if let sysPrompt = model.parameters.systemPrompt {
            apiMessages.append(["role": "system", "content": sysPrompt])
        }

        for msg in messages {
            var entry: [String: Any] = ["role": msg.role, "content": msg.content]
            if let name = msg.name {
                entry["name"] = name
            }
            apiMessages.append(entry)
        }

        var body: [String: Any] = [
            "model": model.modelId,
            "messages": apiMessages,
            "temperature": model.parameters.temperature,
            "max_tokens": model.parameters.maxTokensOverride ?? model.maxOutputTokens,
        ]

        if model.parameters.topP != 1.0 {
            body["top_p"] = model.parameters.topP
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema
                    ]
                ] as [String: Any]
            }
            // stream=false is the default; explicitly requesting streaming
            // would require breaking changes to the API surface.
        }

        return body
    }

    // MARK: - Anthropic Body

    private func buildAnthropicBody(
        provider: AIProviderConfig,
        model: AIModel,
        messages: [AIChatMessage],
        tools: [AIToolSpec]?
    ) -> [String: Any] {
        var systemParts: [String] = []
        if let sysPrompt = model.parameters.systemPrompt {
            systemParts.append(sysPrompt)
        }

        var apiMessages: [[String: Any]] = []
        for msg in messages {
            if msg.role == "system" {
                // Anthropic does not support "system" in the messages array;
                // collect them for the top-level "system" field instead.
                systemParts.append(msg.content)
            } else {
                let role = msg.role == "assistant" ? "assistant" : "user"
                apiMessages.append(["role": role, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": model.modelId,
            "messages": apiMessages,
            "max_tokens": model.parameters.maxTokensOverride ?? model.maxOutputTokens,
            "temperature": model.parameters.temperature,
        ]

        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n")
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema
                ]
            }
        }

        return body
    }

    // MARK: - Parse OpenAI Response

    /// Parses an OpenAI Chat Completions response (also used for Ollama and
    /// generic OpenAI-compatible endpoints).
    private func parseOpenAIResponse(data: Data, statusCode: Int) throws -> (String, (Int, Int)) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAPIError.invalidResponse
        }

        // Provider error
        if let errorDict = json["error"] as? [String: Any],
           let message = errorDict["message"] as? String {
            throw AIAPIError.apiError(message)
        }

        guard statusCode == 200 else {
            throw AIAPIError.httpError(
                statusCode: statusCode,
                message: json["error"].flatMap { $0 as? [String: Any] }.flatMap { $0["message"] as? String } ?? "Unknown error"
            )
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AIAPIError.invalidResponse
        }

        // Build content string (text + tool calls if present)
        var content = message["content"] as? String ?? ""

        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            let payload: [String: Any] = ["tool_calls": toolCalls]
            if let tcData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let tcStr = String(data: tcData, encoding: .utf8) {
                if !content.isEmpty { content += "\n" }
                content += tcStr
            }
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage?["completion_tokens"] as? Int ?? 0

        return (content, (inputTokens, outputTokens))
    }

    // MARK: - Parse Anthropic Response

    /// Parses an Anthropic Messages API response.
    private func parseAnthropicResponse(data: Data, statusCode: Int) throws -> (String, (Int, Int)) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAPIError.invalidResponse
        }

        // Provider error
        if let errorDict = json["error"] as? [String: Any],
           let message = errorDict["message"] as? String {
            throw AIAPIError.apiError(message)
        }

        guard statusCode == 200 else {
            throw AIAPIError.httpError(
                statusCode: statusCode,
                message: (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            )
        }

        guard let contentArray = json["content"] as? [[String: Any]] else {
            throw AIAPIError.invalidResponse
        }

        var text = ""
        for block in contentArray {
            guard let type = block["type"] as? String else { continue }
            if type == "text", let blockText = block["text"] as? String {
                text += blockText
            } else if type == "tool_use" {
                // Serialize tool_use blocks into the content so callers
                // can parse them downstream.
                if let tcData = try? JSONSerialization.data(withJSONObject: block, options: [.sortedKeys]),
                   let tcStr = String(data: tcData, encoding: .utf8) {
                    if !text.isEmpty { text += "\n" }
                    text += tcStr
                }
            }
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        return (text, (inputTokens, outputTokens))
    }
}
