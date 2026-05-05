import Foundation

// MARK: - ExecutionContext

/// Information about the environment in which a skill is executed.
public struct ExecutionContext: Sendable {
    public var hostId: String
    public var workingDirectory: String
    public var environment: [String: String]

    public init(
        hostId: String,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.hostId = hostId
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

// MARK: - ExecutionResult

/// The outcome of a skill execution.
public struct ExecutionResult: Sendable {
    /// The fully rendered prompt text, if the skill wraps a prompt template.
    public var renderedPrompt: String?

    /// Shell commands to run, if the skill produces commands.
    public var commands: [String]?

    /// Whether the execution completed without errors.
    public var success: Bool

    public init(
        renderedPrompt: String? = nil,
        commands: [String]? = nil,
        success: Bool = true
    ) {
        self.renderedPrompt = renderedPrompt
        self.commands = commands
        self.success = success
    }
}

// MARK: - SkillExecutor

/// Prepares a skill for execution by resolving variables and producing
/// executable output (rendered prompts, shell commands, or script invocations).
public final class SkillExecutor: Sendable {

    public init() {}

    /// Execute a skill by resolving variable placeholders against the provided
    /// dictionary and producing the appropriate output for the skill's definition type.
    ///
    /// - Parameters:
    ///   - skill: The skill to execute.
    ///   - variables: Key-value pairs used to replace `{{variable}}` placeholders.
    ///   - context: Environment information for the execution.
    /// - Returns: The result containing rendered output, commands, or success state.
    public func execute(
        skill: Skill,
        variables: [String: String] = [:],
        context: ExecutionContext = ExecutionContext(hostId: "localhost")
    ) async throws -> ExecutionResult {
        guard skill.enabled else {
            return ExecutionResult(success: false)
        }

        switch skill.definition {
        case .promptTemplate(let text):
            return executePromptTemplate(text, variables: variables)

        case .commandSequence(let steps):
            return executeCommandSequence(steps, variables: variables, context: context)

        case .script(let path, let interpreter):
            return executeScript(path: path, interpreter: interpreter, variables: variables)

        case .toolDefinition(let schema):
            return try validateToolSchema(schema)
        }
    }

    // MARK: - Prompt Template

    /// Substitutes `{{variable}}` placeholders in the template text and
    /// returns the rendered prompt.
    private func executePromptTemplate(
        _ text: String,
        variables: [String: String]
    ) -> ExecutionResult {
        let rendered = substituteVariables(in: text, variables: variables)
        return ExecutionResult(renderedPrompt: rendered, success: true)
    }

    // MARK: - Command Sequence

    /// Substitutes variables in each step and returns the resolved command list.
    private func executeCommandSequence(
        _ steps: [CommandStep],
        variables: [String: String],
        context: ExecutionContext
    ) -> ExecutionResult {
        let commands: [String] = steps.map { step in
            var cmd = substituteVariables(in: step.command, variables: variables)
            // Also substitute known context variables.
            cmd = cmd.replacingOccurrences(of: "{{hostId}}", with: context.hostId)
            cmd = cmd.replacingOccurrences(of: "{{workingDirectory}}", with: context.workingDirectory)
            return cmd
        }
        return ExecutionResult(commands: commands, success: true)
    }

    // MARK: - Script

    /// Resolves script path and interpreter, then returns the invocation command.
    private func executeScript(
        path: String,
        interpreter: String,
        variables: [String: String]
    ) -> ExecutionResult {
        let resolvedPath = substituteVariables(in: path, variables: variables)
        let resolvedInterpreter = substituteVariables(in: interpreter, variables: variables)
        let command = "\(resolvedInterpreter) \(resolvedPath)"
        return ExecutionResult(commands: [command], success: true)
    }

    // MARK: - Tool Definition

    /// Validates that the schema data is valid JSON; returns success/failure.
    private func validateToolSchema(_ schema: Data) throws -> ExecutionResult {
        guard !schema.isEmpty else {
            return ExecutionResult(success: false)
        }
        do {
            _ = try JSONSerialization.jsonObject(with: schema)
            return ExecutionResult(success: true)
        } catch {
            return ExecutionResult(success: false)
        }
    }

    // MARK: - Variable Substitution

    /// Replaces all `{{key}}` placeholders with their corresponding values.
    /// Unmatched placeholders are preserved verbatim in the output.
    private func substituteVariables(
        in template: String,
        variables: [String: String]
    ) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
