import Foundation

// MARK: - SkillCategory

public enum SkillCategory: String, Codable, CaseIterable, Sendable {
    case commandTemplate
    case diagnosis
    case deployment
    case monitoring
    case custom
}

// MARK: - CommandStep

public struct CommandStep: Codable, Sendable {
    public var command: String
    public var expectOutput: String?
    public var timeout: TimeInterval
    public var retryCount: Int

    public init(
        command: String,
        expectOutput: String? = nil,
        timeout: TimeInterval = 30,
        retryCount: Int = 0
    ) {
        self.command = command
        self.expectOutput = expectOutput
        self.timeout = timeout
        self.retryCount = retryCount
    }
}

// MARK: - SkillPermission

public enum SkillPermission: Codable, Sendable {
    case readOnly
    case confirmEach(command: Bool)
    case confirmTask
    case autoApproved

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, command
    }

    private enum PermissionType: String, Codable {
        case readOnly
        case confirmEach
        case confirmTask
        case autoApproved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PermissionType.self, forKey: .type)
        switch type {
        case .readOnly:
            self = .readOnly
        case .confirmEach:
            let command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
            self = .confirmEach(command: command)
        case .confirmTask:
            self = .confirmTask
        case .autoApproved:
            self = .autoApproved
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .readOnly:
            try container.encode(PermissionType.readOnly, forKey: .type)
        case .confirmEach(let command):
            try container.encode(PermissionType.confirmEach, forKey: .type)
            try container.encode(command, forKey: .command)
        case .confirmTask:
            try container.encode(PermissionType.confirmTask, forKey: .type)
        case .autoApproved:
            try container.encode(PermissionType.autoApproved, forKey: .type)
        }
    }
}

// MARK: - SkillMetadata

public struct SkillMetadata: Codable, Sendable {
    public var author: String?
    public var version: String
    public var tags: [String]
    public var targetOS: [String]?
    public var requiredTools: [String]?

    public init(
        author: String? = nil,
        version: String = "1.0.0",
        tags: [String] = [],
        targetOS: [String]? = nil,
        requiredTools: [String]? = nil
    ) {
        self.author = author
        self.version = version
        self.tags = tags
        self.targetOS = targetOS
        self.requiredTools = requiredTools
    }
}

// MARK: - SkillDefinition

public enum SkillDefinition: Codable, Sendable {
    case promptTemplate(text: String)
    case script(path: String, interpreter: String)
    case commandSequence(steps: [CommandStep])
    case toolDefinition(schema: Data)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, text, path, interpreter, steps, schema
    }

    private enum DefinitionType: String, Codable {
        case promptTemplate
        case script
        case commandSequence
        case toolDefinition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(DefinitionType.self, forKey: .type)
        switch type {
        case .promptTemplate:
            let text = try container.decode(String.self, forKey: .text)
            self = .promptTemplate(text: text)
        case .script:
            let path = try container.decode(String.self, forKey: .path)
            let interpreter = try container.decode(String.self, forKey: .interpreter)
            self = .script(path: path, interpreter: interpreter)
        case .commandSequence:
            let steps = try container.decode([CommandStep].self, forKey: .steps)
            self = .commandSequence(steps: steps)
        case .toolDefinition:
            let schema = try container.decode(Data.self, forKey: .schema)
            self = .toolDefinition(schema: schema)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .promptTemplate(let text):
            try container.encode(DefinitionType.promptTemplate, forKey: .type)
            try container.encode(text, forKey: .text)
        case .script(let path, let interpreter):
            try container.encode(DefinitionType.script, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(interpreter, forKey: .interpreter)
        case .commandSequence(let steps):
            try container.encode(DefinitionType.commandSequence, forKey: .type)
            try container.encode(steps, forKey: .steps)
        case .toolDefinition(let schema):
            try container.encode(DefinitionType.toolDefinition, forKey: .type)
            try container.encode(schema, forKey: .schema)
        }
    }
}

// MARK: - Skill

public struct Skill: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String
    public var category: SkillCategory
    public var definition: SkillDefinition
    public var permission: SkillPermission
    public var enabled: Bool
    public var metadata: SkillMetadata

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        category: SkillCategory,
        definition: SkillDefinition,
        permission: SkillPermission = .confirmTask,
        enabled: Bool = true,
        metadata: SkillMetadata = SkillMetadata()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.definition = definition
        self.permission = permission
        self.enabled = enabled
        self.metadata = metadata
    }
}
