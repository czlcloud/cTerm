import Foundation

// MARK: - TaskStatus

public enum TaskStatus: String, Codable, Sendable {
    case pending
    case waitingApproval
    case running
    case completed
    case failed
    case cancelled
}

// MARK: - RiskLevel

public enum RiskLevel: String, Codable, Sendable {
    case safe
    case moderate
    case dangerous
}

// MARK: - ApprovalStatus

public enum ApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
    case timeout
}

// MARK: - TaskContext

public struct TaskContext: Codable, Sendable {
    public var instruction: String
    public var variables: [String: String]
    public var terminalSnapshot: String?
    public var attachedFiles: [URL]?

    public init(
        instruction: String,
        variables: [String: String] = [:],
        terminalSnapshot: String? = nil,
        attachedFiles: [URL]? = nil
    ) {
        self.instruction = instruction
        self.variables = variables
        self.terminalSnapshot = terminalSnapshot
        self.attachedFiles = attachedFiles
    }
}

// MARK: - ApprovalRecord

public struct ApprovalRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public var stepIndex: Int
    public var command: String
    public var reasoning: String
    public var riskLevel: RiskLevel
    public var status: ApprovalStatus

    public init(
        id: UUID = UUID(),
        stepIndex: Int,
        command: String,
        reasoning: String,
        riskLevel: RiskLevel,
        status: ApprovalStatus = .pending
    ) {
        self.id = id
        self.stepIndex = stepIndex
        self.command = command
        self.reasoning = reasoning
        self.riskLevel = riskLevel
        self.status = status
    }
}

// MARK: - StepResult

public struct StepResult: Codable, Sendable {
    public var stepIndex: Int
    public var command: String
    public var output: String
    public var exitCode: Int
    public var success: Bool
    public var duration: TimeInterval

    public init(
        stepIndex: Int,
        command: String,
        output: String,
        exitCode: Int,
        success: Bool,
        duration: TimeInterval
    ) {
        self.stepIndex = stepIndex
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.success = success
        self.duration = duration
    }
}

// MARK: - TaskResult

public struct TaskResult: Codable, Sendable {
    public var summary: String
    public var steps: [StepResult]
    public var totalTokensUsed: Int
    public var totalCost: Decimal
    public var duration: TimeInterval

    public init(
        summary: String,
        steps: [StepResult],
        totalTokensUsed: Int,
        totalCost: Decimal,
        duration: TimeInterval
    ) {
        self.summary = summary
        self.steps = steps
        self.totalTokensUsed = totalTokensUsed
        self.totalCost = totalCost
        self.duration = duration
    }
}

// MARK: - AgentTask

public struct AgentTask: Codable, Identifiable, Sendable {
    public let id: UUID
    public var skillId: UUID
    public var hostId: UUID
    public var providerId: UUID
    public var modelId: UUID
    public var status: TaskStatus
    public var context: TaskContext
    public var approvals: [ApprovalRecord]
    public var result: TaskResult?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        skillId: UUID,
        hostId: UUID,
        providerId: UUID,
        modelId: UUID,
        status: TaskStatus = .pending,
        context: TaskContext,
        approvals: [ApprovalRecord] = [],
        result: TaskResult? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.skillId = skillId
        self.hostId = hostId
        self.providerId = providerId
        self.modelId = modelId
        self.status = status
        self.context = context
        self.approvals = approvals
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - PlannedStep

/// A single step returned by the AI planner, representing a shell command to execute.
public struct PlannedStep: Codable, Sendable {
    public var command: String
    public var reasoning: String
    public var riskLevel: RiskLevel

    public init(command: String, reasoning: String, riskLevel: RiskLevel) {
        self.command = command
        self.reasoning = reasoning
        self.riskLevel = riskLevel
    }
}

// MARK: - ApprovalRequirement

/// Describes what level of user confirmation is required before executing a step.
public enum ApprovalRequirement: Sendable {
    /// The step is safe and can be executed without user interaction.
    case autoApprove
    /// The step requires a simple user confirmation (e.g. click "Approve").
    case confirm
    /// The step is dangerous and requires the user to explicitly type "YES".
    case confirmWithYES
}
