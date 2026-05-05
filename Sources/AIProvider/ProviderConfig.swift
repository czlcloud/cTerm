import Foundation

// MARK: - Provider Type

/// The type of AI provider, determining which API format and endpoint to use.
public enum ProviderType: Codable, Equatable, Hashable, Sendable {
    case openAI
    case anthropic
    case ollama
    case openAICompatible
    case custom(schema: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case schema
    }

    private enum Kind: String, Codable {
        case openAI
        case anthropic
        case ollama
        case openAICompatible
        case custom
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openAI:
            try container.encode(Kind.openAI, forKey: .type)
        case .anthropic:
            try container.encode(Kind.anthropic, forKey: .type)
        case .ollama:
            try container.encode(Kind.ollama, forKey: .type)
        case .openAICompatible:
            try container.encode(Kind.openAICompatible, forKey: .type)
        case .custom(let schema):
            try container.encode(Kind.custom, forKey: .type)
            try container.encode(schema, forKey: .schema)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .openAI:
            self = .openAI
        case .anthropic:
            self = .anthropic
        case .ollama:
            self = .ollama
        case .openAICompatible:
            self = .openAICompatible
        case .custom:
            let schema = try container.decode(String.self, forKey: .schema)
            self = .custom(schema: schema)
        }
    }
}

// MARK: - Provider Configuration

/// A complete provider configuration including endpoint details, authentication
/// reference, and the list of enabled models.
public struct AIProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var providerType: ProviderType
    /// Keychain reference or opaque key identifier used to retrieve the
    /// actual API key at request time.
    public var apiKeyRef: String
    /// Custom base URL. When nil a sensible default for the provider type
    /// is used (e.g. https://api.openai.com).
    public var baseURL: String?
    public var enabledModels: [AIModel]
    public var defaultModelId: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        providerType: ProviderType,
        apiKeyRef: String,
        baseURL: String? = nil,
        enabledModels: [AIModel],
        defaultModelId: UUID
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.apiKeyRef = apiKeyRef
        self.baseURL = baseURL
        self.enabledModels = enabledModels
        self.defaultModelId = defaultModelId
    }
}

// MARK: - AI Model

/// A single model that a provider offers, together with its capabilities and
/// default inference parameters.
public struct AIModel: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The model identifier sent in API requests, e.g. "gpt-4o" or
    /// "claude-sonnet-4-20250514".
    public var modelId: String
    /// Human-readable name shown in UI, e.g. "GPT-4o" or "Claude Sonnet 4".
    public var displayName: String
    /// Maximum context window size in tokens.
    public var contextWindow: Int
    /// Default maximum output tokens for this model.
    public var maxOutputTokens: Int
    public var supportsVision: Bool
    public var supportsToolUse: Bool
    /// Per-token pricing information, if known.
    public var pricing: Pricing?
    /// Default inference parameters applied when this model is selected.
    public var parameters: ModelParameters

    public init(
        id: UUID = UUID(),
        modelId: String,
        displayName: String,
        contextWindow: Int = 8192,
        maxOutputTokens: Int = 4096,
        supportsVision: Bool = false,
        supportsToolUse: Bool = true,
        pricing: Pricing? = nil,
        parameters: ModelParameters = ModelParameters()
    ) {
        self.id = id
        self.modelId = modelId
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsToolUse = supportsToolUse
        self.pricing = pricing
        self.parameters = parameters
    }
}

// MARK: - Model Parameters

/// Per-model inference parameters sent together with every API request.
public struct ModelParameters: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    /// An optional system prompt prepended to the conversation for this model.
    public var systemPrompt: String?
    /// When set, overrides the model's default `maxOutputTokens`.
    public var maxTokensOverride: Int?

    public init(
        temperature: Double = 0.7,
        topP: Double = 1.0,
        systemPrompt: String? = nil,
        maxTokensOverride: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.systemPrompt = systemPrompt
        self.maxTokensOverride = maxTokensOverride
    }
}

// MARK: - Pricing

/// Token-based pricing for a model, expressed per 1M tokens.
public struct Pricing: Codable, Hashable, Sendable {
    /// Cost per 1M input tokens.
    public var inputPer1M: Decimal
    /// Cost per 1M output tokens.
    public var outputPer1M: Decimal
    /// ISO 4217 currency code, e.g. "USD".
    public var currency: String

    public init(
        inputPer1M: Decimal,
        outputPer1M: Decimal,
        currency: String = "USD"
    ) {
        self.inputPer1M = inputPer1M
        self.outputPer1M = outputPer1M
        self.currency = currency
    }
}

// MARK: - Usage Record

/// A single API usage event recording token consumption, estimated cost,
/// and the context in which the request was made.
public struct UsageRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var providerId: UUID
    public var modelId: UUID
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCost: Decimal
    public var context: UsageContext

    public init(
        id: UUID = UUID(),
        providerId: UUID,
        modelId: UUID,
        timestamp: Date = Date(),
        inputTokens: Int,
        outputTokens: Int,
        estimatedCost: Decimal,
        context: UsageContext
    ) {
        self.id = id
        self.providerId = providerId
        self.modelId = modelId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost
        self.context = context
    }
}

// MARK: - Usage Context

/// Identifies the origin of a usage event.
public enum UsageContext: Codable, Equatable, Hashable, Sendable {
    case assistant
    case agent(taskId: UUID)
    case skill(skillId: UUID)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case taskId
        case skillId
    }

    private enum Kind: String, Codable {
        case assistant
        case agent
        case skill
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .assistant:
            try container.encode(Kind.assistant, forKey: .type)
        case .agent(let taskId):
            try container.encode(Kind.agent, forKey: .type)
            try container.encode(taskId, forKey: .taskId)
        case .skill(let skillId):
            try container.encode(Kind.skill, forKey: .type)
            try container.encode(skillId, forKey: .skillId)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .assistant:
            self = .assistant
        case .agent:
            let taskId = try container.decode(UUID.self, forKey: .taskId)
            self = .agent(taskId: taskId)
        case .skill:
            let skillId = try container.decode(UUID.self, forKey: .skillId)
            self = .skill(skillId: skillId)
        }
    }
}
