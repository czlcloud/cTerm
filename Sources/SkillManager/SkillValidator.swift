import Foundation

// MARK: - ValidationError

/// Describes a single validation failure found in a skill.
public struct ValidationError: Sendable {
    /// The dot-delimited path to the field that failed validation
    /// (e.g. `"definition.text"`, `"metadata.requiredTools"`).
    public let field: String
    /// A human-readable description of the problem.
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

// MARK: - SkillValidator

/// Validates skill definitions, metadata, and configuration against a set of rules.
public final class SkillValidator: Sendable {

    public init() {}

    /// Validates a skill and returns all found issues.
    ///
    /// - Parameters:
    ///   - skill: The skill to validate.
    ///   - availableCommands: Commands that are available on the target system.
    ///                        When empty, required-tools checks that depend on
    ///                        system commands are skipped.
    /// - Returns: An array of `ValidationError`. Empty when the skill is valid.
    public func validate(
        _ skill: Skill,
        availableCommands: [String] = []
    ) -> [ValidationError] {
        var errors: [ValidationError] = []

        errors.append(contentsOf: validateName(skill.name))
        errors.append(contentsOf: validateDescription(skill.description))
        errors.append(contentsOf: validateDefinition(skill.definition))
        errors.append(contentsOf: validateMetadata(skill.metadata, availableCommands: availableCommands))

        return errors
    }

    // MARK: - Name

    private func validateName(_ name: String) -> [ValidationError] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [ValidationError(field: "name", message: "Skill name must not be empty.")]
        }
        return []
    }

    // MARK: - Description

    private func validateDescription(_ description: String) -> [ValidationError] {
        // Description is optional – we only flag an issue if it is nil/missing,
        // but since it is a non-optional String we simply allow empty strings.
        // The model layer does not require it, so no error here.
        []
    }

    // MARK: - Definition

    private func validateDefinition(_ definition: SkillDefinition) -> [ValidationError] {
        switch definition {
        case .promptTemplate(let text):
            return validatePromptTemplate(text)
        case .script(let path, let interpreter):
            return validateScript(path: path, interpreter: interpreter)
        case .commandSequence(let steps):
            return validateCommandSequence(steps)
        case .toolDefinition(let schema):
            return validateToolSchema(schema)
        }
    }

    private func validatePromptTemplate(_ text: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        if text.isEmpty {
            errors.append(ValidationError(
                field: "definition.text",
                message: "Prompt template must not be empty."
            ))
            return errors
        }
        // Check that every `{{` has a matching `}}` and they are properly nested.
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "{" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "{" {
                depth += 1
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            } else if text[i] == "}" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "}" {
                depth -= 1
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            } else {
                i = text.index(after: i)
            }
        }
        if depth != 0 {
            errors.append(ValidationError(
                field: "definition.text",
                message: "Prompt template contains unmatched '{{' or '}}' delimiters."
            ))
        }
        return errors
    }

    private func validateScript(path: String, interpreter: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ValidationError(
                field: "definition.path",
                message: "Script path must not be empty."
            ))
        }
        if interpreter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ValidationError(
                field: "definition.interpreter",
                message: "Script interpreter must not be empty."
            ))
        }
        return errors
    }

    private func validateCommandSequence(_ steps: [CommandStep]) -> [ValidationError] {
        guard !steps.isEmpty else {
            return [ValidationError(
                field: "definition.steps",
                message: "Command sequence must contain at least one step."
            )]
        }

        var errors: [ValidationError] = []
        for (index, step) in steps.enumerated() {
            if step.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(ValidationError(
                    field: "definition.steps[\(index)].command",
                    message: "Command at step \(index) must not be empty."
                ))
            }
            if step.timeout <= 0 {
                errors.append(ValidationError(
                    field: "definition.steps[\(index)].timeout",
                    message: "Timeout must be greater than zero (got \(step.timeout))."
                ))
            }
            if step.retryCount < 0 {
                errors.append(ValidationError(
                    field: "definition.steps[\(index)].retryCount",
                    message: "Retry count must be non-negative (got \(step.retryCount))."
                ))
            }
        }
        return errors
    }

    private func validateToolSchema(_ schema: Data) -> [ValidationError] {
        guard !schema.isEmpty else {
            return [ValidationError(
                field: "definition.schema",
                message: "Tool schema data must not be empty."
            )]
        }
        do {
            let json = try JSONSerialization.jsonObject(with: schema)
            guard let dict = json as? [String: Any] else {
                return [ValidationError(
                    field: "definition.schema",
                    message: "Tool schema must be a JSON object (dictionary)."
                )]
            }
            // A minimal JSON Schema must have at least one of these top-level keys.
            let recognizedKeys: Set<String> = ["type", "title", "properties", "$schema", "definitions"]
            if recognizedKeys.isDisjoint(with: dict.keys) {
                return [ValidationError(
                    field: "definition.schema",
                    message: "Tool schema must contain at least one of: type, title, properties, $schema, definitions."
                )]
            }
        } catch {
            return [ValidationError(
                field: "definition.schema",
                message: "Tool schema is not valid JSON – \(error.localizedDescription)."
            )]
        }
        return []
    }

    // MARK: - Metadata

    private func validateMetadata(
        _ metadata: SkillMetadata,
        availableCommands: [String]
    ) -> [ValidationError] {
        var errors: [ValidationError] = []

        if metadata.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ValidationError(
                field: "metadata.version",
                message: "Version must not be empty."
            ))
        }

        // Validate required tools against the available-commands list.
        if let required = metadata.requiredTools, !required.isEmpty {
            if availableCommands.isEmpty {
                // Cannot validate when no command list is provided – skip.
                return errors
            }
            for tool in required {
                if !availableCommands.contains(tool) {
                    errors.append(ValidationError(
                        field: "metadata.requiredTools",
                        message: "Required tool '\(tool)' is not in the list of available commands."
                    ))
                }
            }
        }

        return errors
    }
}
