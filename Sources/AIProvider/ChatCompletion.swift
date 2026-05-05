import Foundation

// MARK: - AIMessage

/// A single message in an AI chat conversation, with a typed role.
public struct AIMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - AICompletionResult

/// The result of an AI completion request, including the generated text
/// and token usage information.
public struct TokenUsage: Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AICompletionResult: Sendable {
    public var content: String
    public var usage: TokenUsage

    public init(content: String, usage: TokenUsage) {
        self.content = content
        self.usage = usage
    }
}

// MARK: - AIProviderError

/// Errors that can occur during AI provider operations.
public enum AIProviderError: Error, LocalizedError, Sendable {
    case notImplemented
    case providerNotFound(UUID)
    case modelNotFound(UUID)
    case requestFailed(String)
    case rateLimited
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "This AI provider feature is not yet implemented."
        case .providerNotFound(let id):
            return "No AI provider found with id \(id)."
        case .modelNotFound(let id):
            return "No model found with id \(id)."
        case .requestFailed(let detail):
            return "AI provider request failed: \(detail)"
        case .rateLimited:
            return "Rate limited by AI provider."
        case .authenticationFailed:
            return "AI provider authentication failed."
        }
    }
}

// MARK: - AIProviderRegistry + Completion

extension AIProviderRegistry {
    /// Sends a chat completion request to the specified provider/model.
    /// Returns the response text together with token usage information.
    public func complete(
        providerId: UUID,
        modelId: UUID,
        messages: [AIMessage]
    ) async throws -> AICompletionResult {
        throw AIProviderError.notImplemented
    }
}
