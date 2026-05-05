import Foundation
import AIProvider
import TerminalCore

// MARK: - Risk Types

/// The risk level associated with a terminal command.
public enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case safe
    case moderate
    case dangerous
}

/// A structured risk assessment returned by the AI.
public struct RiskAssessment: Codable, Sendable {
    public let riskLevel: RiskLevel
    public let explanation: String
    public let warnings: [String]
    public let saferAlternative: String?

public enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case explanation
        case warnings
        case saferAlternative = "safer_alternative"
    }

    public init(
        riskLevel: RiskLevel,
        explanation: String,
        warnings: [String],
        saferAlternative: String?
    ) {
        self.riskLevel = riskLevel
        self.explanation = explanation
        self.warnings = warnings
        self.saferAlternative = saferAlternative
    }
}

// MARK: - Errors

/// Errors thrown by the assistant service.
public enum AssistantError: Error, LocalizedError, Sendable {
    case invalidProviderID
    case invalidModelID
    case apiKeyNotResolved(reference: String)
    case apiError(statusCode: Int, message: String)
    case decodingError(String)
    case noResponse
    case invalidResponseFormat
    case networkError(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidProviderID:
            return "The specified AI provider ID is not registered."
        case .invalidModelID:
            return "The specified model ID is not registered for this provider."
        case .apiKeyNotResolved(let ref):
            return "Could not resolve API key for reference \"\(ref)\". Set the key via APIKeyStore or an environment variable."
        case .apiError(let code, let message):
            return "API returned error \(code): \(message)"
        case .decodingError(let detail):
            return "Failed to decode AI response: \(detail)"
        case .noResponse:
            return "The AI provider returned an empty response."
        case .invalidResponseFormat:
            return "The AI response could not be parsed into the expected format."
        case .networkError(let underlying):
            return "Network request failed: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Assistant Service

/// Main actor-bound service that provides AI-powered assistance for terminal users.
///
/// All three capabilities (explain error, generate command, review risk) communicate
/// with the configured AI provider using ``APIRouter`` and record usage through
/// ``UsageTracker``.
@MainActor
public final class AssistantService: ObservableObject, @unchecked Sendable {
    private let registry: AIProviderRegistry
    private let keyStore: APIKeyStore
    private let router: APIRouter
    private let decoder: JSONDecoder

    // MARK: Initialization

    public init(
        registry: AIProviderRegistry,
        keyStore: APIKeyStore = .shared,
        router: APIRouter = APIRouter()
    ) {
        self.registry = registry
        self.keyStore = keyStore
        self.router = router
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API

    /// Send error log text to the AI and receive an explanation with suggested fixes.
    ///
    /// - Parameters:
    ///   - errorText: The error message or log output to analyse.
    ///   - providerId: UUID of the registered provider to use.
    ///   - modelId: UUID of the registered model to use.
    /// - Returns: A human-readable explanation and fix suggestions.
    public func explainError(
        _ errorText: String,
        providerId: UUID,
        modelId: UUID
    ) async throws -> String {
        let messages = [
            AIChatMessage(role: "system", content: Self.explainErrorPrompt),
            AIChatMessage(role: "user", content: errorText),
        ]
        return try await sendAndRecord(
            messages: messages,
            providerId: providerId,
            modelId: modelId,
            context: .assistant
        )
    }

    /// Generate a shell command from a natural-language description.
    ///
    /// - Parameters:
    ///   - intent: Natural-language description of what the user wants to do.
    ///   - providerId: UUID of the registered provider to use.
    ///   - modelId: UUID of the registered model to use.
    /// - Returns: The shell command string (no surrounding explanation).
    public func generateCommand(
        _ intent: String,
        providerId: UUID,
        modelId: UUID
    ) async throws -> String {
        let messages = [
            AIChatMessage(role: "system", content: Self.generateCommandPrompt),
            AIChatMessage(role: "user", content: intent),
        ]
        let result = try await sendAndRecord(
            messages: messages,
            providerId: providerId,
            modelId: modelId,
            context: .assistant
        )
        return Self.sanitizeCommand(result)
    }

    /// Analyse a shell command for risk and return a structured assessment.
    ///
    /// - Parameters:
    ///   - command: The shell command to evaluate.
    ///   - providerId: UUID of the registered provider to use.
    ///   - modelId: UUID of the registered model to use.
    /// - Returns: A ``RiskAssessment`` with risk level, explanation, warnings,
    ///   and an optional safer alternative.
    public func reviewRisk(
        _ command: String,
        providerId: UUID,
        modelId: UUID
    ) async throws -> RiskAssessment {
        let messages = [
            AIChatMessage(role: "system", content: Self.reviewRiskPrompt),
            AIChatMessage(role: "user", content: command),
        ]
        let content = try await sendAndRecord(
            messages: messages,
            providerId: providerId,
            modelId: modelId,
            context: .assistant
        )

        let cleaned = Self.extractJSON(from: content)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw AssistantError.invalidResponseFormat
        }

        do {
            return try decoder.decode(RiskAssessment.self, from: jsonData)
        } catch {
            throw AssistantError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Prompts

    private static let explainErrorPrompt = """
    You are a terminal and systems expert. Analyse the following error text and explain:
    1. What likely caused the error.
    2. How to fix it (specific commands or steps).

    Be concise but thorough. If the error is ambiguous, state what additional context would help.
    """

    private static let generateCommandPrompt = """
    You are a shell expert. Given a natural-language intent, generate the correct shell command.
    Return ONLY the command itself — no explanation, no markdown, no backticks, no prefix.
    If multiple commands are needed, join them with && or ; on a single line where possible.
    """

    private static let reviewRiskPrompt = """
    You are a security expert analysing shell commands. Determine the risk level and return your \
    assessment as **valid JSON only** (no markdown fences, no extra text) with these fields:
    - "risk_level": "safe", "moderate", or "dangerous"
    - "explanation": a short explanation of the risk
    - "warnings": an array of specific warning strings (can be empty)
    - "safer_alternative": a safer command string or null if not applicable

    Examples:
    {"risk_level":"safe","explanation":"Lists directory contents.","warnings":[],"safer_alternative":null}
    {"risk_level":"dangerous","explanation":"Recursively force-deletes the root filesystem.","warnings":["Irreversible data loss","Requires root"],"safer_alternative":"rm -rf /path/to/target"}
    """

    // MARK: - Internal

    /// Resolve provider + model, send via the router, record usage, and return text.
    private func sendAndRecord(
        messages: [AIChatMessage],
        providerId: UUID,
        modelId: UUID,
        context: UsageContext
    ) async throws -> String {
        // 1. Resolve provider config & model ---------------------------------
        guard let provider = registry.getProvider(by: providerId) else {
            throw AssistantError.invalidProviderID
        }
        guard let model = resolveModel(by: modelId) else {
            throw AssistantError.invalidModelID
        }

        // 2. Ensure the API key is available (early failure is friendlier) ----
        guard keyStore.resolve(provider.apiKeyRef) != nil else {
            throw AssistantError.apiKeyNotResolved(reference: provider.apiKeyRef)
        }

        // 3. Send via APIRouter ----------------------------------------------
        let (content, usage): (String, (input: Int, output: Int))
        do {
            let result = try await router.sendMessage(
                provider: provider,
                model: model,
                messages: messages,
                tools: nil
            )
            content = result.content
            usage = result.usage
        } catch let error as AIAPIError {
            throw convert(error: error)
        } catch {
            throw AssistantError.networkError(underlying: error)
        }

        // 4. Record usage ----------------------------------------------------
        let estimatedCost = calculateCost(
            inputTokens: usage.input,
            outputTokens: usage.output,
            model: model
        )
        UsageTracker.shared.record(
            providerId: providerId,
            modelId: modelId,
            inputTokens: usage.input,
            outputTokens: usage.output,
            estimatedCost: estimatedCost,
            context: context
        )

        return content
    }

    /// Search across all providers for a model with the given id.
    private func resolveModel(by id: UUID) -> AIModel? {
        for provider in registry.providers {
            if let model = provider.enabledModels.first(where: { $0.id == id }) {
                return model
            }
        }
        return nil
    }

    /// Compute the estimated monetary cost of a request from model pricing,
    /// or return 0 when no pricing data is configured.
    private func calculateCost(inputTokens: Int, outputTokens: Int, model: AIModel) -> Decimal {
        guard let pricing = model.pricing else { return 0 }
        let inputCost = Decimal(inputTokens) * pricing.inputPer1M / 1_000_000
        let outputCost = Decimal(outputTokens) * pricing.outputPer1M / 1_000_000
        return inputCost + outputCost
    }

    /// Map `AIAPIError` to our own error type so callers only deal with a
    /// single error domain.
    private func convert(error: AIAPIError) -> AssistantError {
        switch error {
        case .invalidURL, .invalidResponse, .unsupportedProvider, .missingAPIKey:
            return .apiError(statusCode: 0, message: error.localizedDescription ?? "Unknown API error")
        case .httpError(let code, let message):
            return .apiError(statusCode: code, message: message)
        case .decodingError(let underlying):
            return .decodingError(underlying.localizedDescription)
        case .apiError(let message):
            return .apiError(statusCode: 0, message: message)
        }
    }

    // MARK: - Text Cleanup

    /// Remove markdown code fences and leading/trailing whitespace from a command.
    private static func sanitizeCommand(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["```sh", "```bash", "```shell", "```zsh", "```"] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// Extract a JSON object from text that may be wrapped in markdown fences.
    private static func extractJSON(from text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading markdown fence (```json, ```, etc.) and trailing fence
        if lines.hasPrefix("```") {
            let body = lines
                .dropFirst(3)
                .drop(while: { !$0.isNewline })
                .dropFirst()
            let cleaned = body
                .dropLast(3)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = String(cleaned)
            if trimmed.hasPrefix("{") {
                return trimmed
            }
            // Fallback: extract the first {…} block
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}")
            {
                return String(trimmed[start ... end])
            }
            return trimmed
        }

        // No fences — try to extract the first {…} block
        if let start = lines.firstIndex(of: "{"),
           let end = lines.lastIndex(of: "}")
        {
            return String(lines[start ... end])
        }
        return lines
    }
}
