import Foundation
import AIProvider
import SSHClient

// MARK: - AgentService

/// The central coordinator for autonomous agent tasks.
///
/// `AgentService` manages the full lifecycle of an agent task:
///   1. **Creation** — a new task is recorded with its context.
///   2. **Planning** — the AI provider generates a sequence of shell commands.
///   3. **Approval** — each step is checked by ``ApprovalFlow``; dangerous steps
///      wait for user confirmation.
///   4. **Execution** — approved commands run over an SSH channel.
///   5. **Completion / Cancellation** — results are collected and persisted.
///
/// All state is `@Published` so SwiftUI views can observe it directly.
@MainActor
public final class AgentService: ObservableObject {

    // MARK: - Published State

    /// Every task that has been created in this session (including those
    /// loaded from disk on launch).
    @Published public var tasks: [AgentTask] = []

    /// The task that is currently being planned, awaiting approval, or
    /// executing. `nil` when no task is active.
    @Published public var activeTask: AgentTask?

    // MARK: - Private Dependencies

    private let planner = TaskPlanner()
    private let approvalFlow = ApprovalFlow()
    private let store = AgentTaskStore()

    /// Cache of planned steps keyed by task id. Populated by ``startTask(_:)``
    /// and consumed by ``executeStep(taskId:stepIndex:connection:)``.
    private var plannedStepsCache: [UUID: [PlannedStep]] = [:]

    // MARK: - Init

    public init() {
        tasks = store.load()
    }

    // MARK: - Task Lifecycle

    /// Creates a new task with the given parameters and appends it to the
    /// task list. The task is persisted immediately.
    ///
    /// - Parameters:
    ///   - skillId: The skill that this task belongs to.
    ///   - hostId: The target host for command execution.
    ///   - providerId: The AI provider used for planning.
    ///   - modelId: The AI model used for planning.
    ///   - context: The task instruction and variable context.
    /// - Returns: The newly created task (already persisted).
    public func createTask(
        skillId: UUID,
        hostId: UUID,
        providerId: UUID,
        modelId: UUID,
        context: TaskContext
    ) -> AgentTask {
        let task = AgentTask(
            skillId: skillId,
            hostId: hostId,
            providerId: providerId,
            modelId: modelId,
            context: context
        )
        tasks.append(task)
        store.save(tasks)
        return task
    }

    /// Starts the planning-and-approval flow for the given task.
    ///
    /// The method sends the task's instruction to the AI provider, parses the
    /// planned steps, evaluates each step for risk, and creates approval records
    /// where necessary. If all steps are ``ApprovalRequirement/autoApprove`` the
    /// task transitions to ``TaskStatus/running``; otherwise it transitions to
    /// ``TaskStatus/waitingApproval``.
    ///
    /// - Parameter taskId: The id of the task to start.
    public func startTask(_ taskId: UUID) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard tasks[index].status == .pending || tasks[index].status == .waitingApproval else { return }

        tasks[index].status = .running
        tasks[index].updatedAt = Date()
        activeTask = tasks[index]

        let snapshot = tasks[index] // capture before async boundary

        do {
            let predictedSteps = try await planner.plan(
                task: snapshot,
                providerRegistry: AIProviderRegistry.shared
            )

            // Re-acquire index after the async call (the array may have changed).
            guard let updatedIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }

            plannedStepsCache[taskId] = predictedSteps

            // Create approval records for steps that require them.
            var approvals: [ApprovalRecord] = []
            for (i, step) in predictedSteps.enumerated() {
                let requirement = approvalFlow.requiresApproval(step: step)
                switch requirement {
                case .autoApprove:
                    break
                case .confirm, .confirmWithYES:
                    approvals.append(ApprovalRecord(
                        stepIndex: i,
                        command: step.command,
                        reasoning: step.reasoning,
                        riskLevel: step.riskLevel,
                        status: .pending
                    ))
                }
            }

            tasks[updatedIndex].approvals = approvals
            tasks[updatedIndex].updatedAt = Date()

            if approvals.isEmpty {
                // All steps are auto-approved; caller should drive execution.
                tasks[updatedIndex].status = .running
            } else {
                tasks[updatedIndex].status = .waitingApproval
            }

            store.save(tasks)
            activeTask = tasks.first(where: { $0.id == taskId })

        } catch {
            if let errorIndex = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[errorIndex].status = .failed
                tasks[errorIndex].updatedAt = Date()
                store.save(tasks)
                activeTask = tasks[errorIndex]
            }
        }
    }

    // MARK: - Approval

    /// Marks the specified step as approved.
    ///
    /// When all pending approvals for the task have been resolved (approved or
    /// rejected) the task's status is updated accordingly:
    ///   - All approved -> ``TaskStatus/running``
    ///   - Any rejected -> ``TaskStatus/cancelled``
    ///
    /// - Parameters:
    ///   - taskId: The task containing the step.
    ///   - stepIndex: The index of the step within the planned steps.
    public func approveStep(taskId: UUID, stepIndex: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard let approvalIndex = tasks[index].approvals.firstIndex(where: { $0.stepIndex == stepIndex }) else { return }

        tasks[index].approvals[approvalIndex].status = .approved
        tasks[index].updatedAt = Date()

        // Check whether all approvals have been resolved.
        let pending = tasks[index].approvals.filter { $0.status == .pending }.count
        let rejected = tasks[index].approvals.filter { $0.status == .rejected }.count

        if pending == 0 {
            tasks[index].status = rejected > 0 ? .cancelled : .running
        }

        store.save(tasks)
        activeTask = tasks.first(where: { $0.id == taskId })
    }

    /// Marks the specified step as rejected and cancels the entire task.
    ///
    /// - Parameters:
    ///   - taskId: The task containing the step.
    ///   - stepIndex: The index of the step to reject.
    public func rejectStep(taskId: UUID, stepIndex: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard let approvalIndex = tasks[index].approvals.firstIndex(where: { $0.stepIndex == stepIndex }) else { return }

        tasks[index].approvals[approvalIndex].status = .rejected
        tasks[index].status = .cancelled
        tasks[index].updatedAt = Date()
        store.save(tasks)
        activeTask = tasks.first(where: { $0.id == taskId })
    }

    // MARK: - Execution

    /// Executes a single planned step over an SSH connection.
    ///
    /// The method opens a channel on the provided connection, runs the command,
    /// captures the output and exit code, and stores the result in the task's
    /// ``TaskResult``. If this was the last planned step the task transitions
    /// to ``TaskStatus/completed`` (or ``TaskStatus/failed`` on error).
    ///
    /// - Parameters:
    ///   - taskId: The task being executed.
    ///   - stepIndex: The index of the step to run.
    ///   - connection: An authenticated ``SSHConnection`` to the target host.
    public func executeStep(
        taskId: UUID,
        stepIndex: Int,
        connection: SSHConnection
    ) async {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard tasks[taskIndex].status == .running else { return }
        guard let plannedSteps = plannedStepsCache[taskId],
              stepIndex < plannedSteps.count else { return }

        let step = plannedSteps[stepIndex]
        let startTime = Date()

        do {
            let channel = try SSHChannel(connection: connection)
            try channel.exec(step.command)

            // Collect all output from the async stream until the channel closes.
            let output = await collectOutput(from: channel.outputStream)
            let exitCode = channel.exitStatus ?? -1
            let duration = Date().timeIntervalSince(startTime)
            channel.close()

            // Re-acquire index (the array may have changed during the async call).
            guard let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }

            let stepResult = StepResult(
                stepIndex: stepIndex,
                command: step.command,
                output: output,
                exitCode: exitCode,
                success: exitCode == 0,
                duration: duration
            )

            appendStepResult(at: currentIndex, stepResult: stepResult)

            if stepIndex == plannedSteps.count - 1 {
                tasks[currentIndex].status = .completed
                finalizeTaskResult(at: currentIndex)
            }

            tasks[currentIndex].updatedAt = Date()
            store.save(tasks)
            activeTask = tasks.first(where: { $0.id == taskId })

        } catch {
            guard let currentIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }

            let duration = Date().timeIntervalSince(startTime)
            let stepResult = StepResult(
                stepIndex: stepIndex,
                command: step.command,
                output: "Error: \(error.localizedDescription)",
                exitCode: -1,
                success: false,
                duration: duration
            )

            appendStepResult(at: currentIndex, stepResult: stepResult)
            tasks[currentIndex].status = .failed
            tasks[currentIndex].updatedAt = Date()
            store.save(tasks)
            activeTask = tasks.first(where: { $0.id == taskId })
        }
    }

    // MARK: - Cancellation

    /// Cancels a task regardless of its current status.
    ///
    /// - Parameter taskId: The id of the task to cancel.
    public func cancelTask(_ taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }

        tasks[index].status = .cancelled
        tasks[index].updatedAt = Date()
        store.save(tasks)

        if activeTask?.id == taskId {
            activeTask = nil
        }
    }

    // MARK: - Queries

    /// Returns all pending approval records across every task that is currently
    /// in the ``TaskStatus/waitingApproval`` state.
    ///
    /// - Returns: An array of approval records whose status is `.pending`.
    public func getPendingApprovals() -> [ApprovalRecord] {
        tasks
            .filter { $0.status == .waitingApproval }
            .flatMap { $0.approvals.filter { $0.status == .pending } }
    }

    // MARK: - Private Helpers

    /// Collects all data from an ``AsyncStream`` of `Data` into a single UTF-8 string.
    /// Returns an empty string if the stream yields no data or encoding fails.
    private func collectOutput(from stream: AsyncStream<Data>) async -> String {
        var allData = Data()
        for await chunk in stream {
            allData.append(chunk)
        }
        return String(data: allData, encoding: .utf8) ?? ""
    }

    /// Ensures the result container exists on the task at the given index and
    /// appends the new step result.
    private func appendStepResult(at index: Int, stepResult: StepResult) {
        if tasks[index].result == nil {
            tasks[index].result = TaskResult(
                summary: "",
                steps: [],
                totalTokensUsed: 0,
                totalCost: 0,
                duration: 0
            )
        }
        tasks[index].result?.steps.append(stepResult)
    }

    /// Computes summary fields on the task's result.
    private func finalizeTaskResult(at index: Int) {
        guard var result = tasks[index].result else { return }

        let totalDuration = result.steps.reduce(0) { $0 + $1.duration }
        let successCount = result.steps.filter(\.success).count
        let totalCount = result.steps.count

        result.summary = "Completed \(totalCount) steps (\(successCount) successful, \(totalCount - successCount) failed) in \(String(format: "%.1f", totalDuration))s"
        result.duration = totalDuration
        tasks[index].result = result
        tasks[index].updatedAt = Date()
    }
}
