import Foundation
import AIProvider

// MARK: - TaskPlannerError

public enum TaskPlannerError: Error, LocalizedError, Sendable {
    case invalidResponse
    case decodingFailed(Error)
    case planEmpty

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI returned an unparseable response."
        case .decodingFailed(let error):
            return "Failed to decode AI response: \(error.localizedDescription)"
        case .planEmpty:
            return "The AI returned an empty plan with no steps."
        }
    }
}

// MARK: - TaskPlanner

/// Generates an ordered list of shell commands (``PlannedStep``) from a task
/// description by sending a prompt to the configured AI provider.
public final class TaskPlanner: @unchecked Sendable {

    public init() {}

    /// Asks the AI to produce a step-by-step plan for the given task.
    ///
    /// The planner sends the task instruction and variable context to the AI
    /// provider, then parses the returned JSON into an array of `PlannedStep`.
    ///
    /// - Parameters:
    ///   - task: The agent task whose ``TaskContext/instruction`` drives the plan.
    ///   - providerRegistry: Registry from which the provider's completion API is called.
    /// - Returns: An ordered list of planned steps.
    /// - Throws: ``TaskPlannerError`` if the AI response cannot be parsed.
    public func plan(
        task: AgentTask,
        providerRegistry: AIProviderRegistry
    ) async throws -> [PlannedStep] {
        let systemPrompt = """
        You are an autonomous ops agent. Your job is to plan shell commands that \
        accomplish a task on a remote server. Always prefer idempotent commands, \
        handle errors gracefully, and use safe defaults.
        """

        let userPrompt = buildUserPrompt(for: task)

        let messages: [AIMessage] = [
            AIMessage(role: .system, content: systemPrompt),
            AIMessage(role: .user, content: userPrompt),
        ]

        let result = try await providerRegistry.complete(
            providerId: task.providerId,
            modelId: task.modelId,
            messages: messages
        )

        let jsonString = extractJSON(from: result.content)

        guard let data = jsonString.data(using: .utf8) else {
            throw TaskPlannerError.invalidResponse
        }

        let decoder = JSONDecoder()
        let steps: [PlannedStep]
        do {
            steps = try decoder.decode([PlannedStep].self, from: data)
        } catch {
            throw TaskPlannerError.decodingFailed(error)
        }

        guard !steps.isEmpty else {
            throw TaskPlannerError.planEmpty
        }

        return steps
    }

    // MARK: - Private Helpers

    /// Builds the user-facing prompt from the task's instruction and variables.
    private func buildUserPrompt(for task: AgentTask) -> String {
        var prompt = """
        Plan the shell commands to accomplish this task. Return ONLY a valid JSON \
        array of objects. Each object must have exactly three keys:

          - "command"    (string): the shell command to run
          - "reasoning"  (string): a short explanation of why this command is needed
          - "riskLevel"  (string): one of "safe", "moderate", or "dangerous"

        Task instruction: \(task.context.instruction)
        """

        if !task.context.variables.isEmpty {
            prompt += "\n\nVariables:\n"
            for (key, value) in task.context.variables {
                prompt += "  \(key)=\(value)\n"
            }
        }

        if let snapshot = task.context.terminalSnapshot, !snapshot.isEmpty {
            prompt += "\n\nTerminal context:\n\(snapshot)\n"
        }

        return prompt
    }

    /// Strips surrounding markdown code fences (```json … ```) if present and
    /// returns only the raw JSON text.
    private func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle ```json ... ``` fences
        if trimmed.hasPrefix("```") {
            let afterPrefix = trimmed
                .dropFirst(3)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let endRange = afterPrefix.range(of: "```") {
                return String(afterPrefix[afterPrefix.startIndex..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // No closing fence found; strip the optional language hint line.
            if let newlineRange = afterPrefix.range(of: "\n") {
                return String(afterPrefix[newlineRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return String(afterPrefix)
        }

        return trimmed
    }
}
