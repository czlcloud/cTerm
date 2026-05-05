import Foundation
import AIProvider
import TerminalCore

/// Convenience wrapper around ``AssistantService`` that generates shell commands
/// from natural-language descriptions, optionally including terminal context such
/// as the current working directory and recent output.
public struct CommandGenerator {
    private let service: AssistantService

    public init(service: AssistantService) {
        self.service = service
    }

    /// Generate a shell command from natural language.
    ///
    /// - Parameters:
    ///   - naturalLanguage: What the user wants to accomplish (e.g. "find all files
    ///     modified in the last hour").
    ///   - terminalContext: Optional context string that includes CWD and recent
    ///     terminal output. This helps the AI produce a more relevant command.
    ///   - providerId: Registered provider to use.
    ///   - modelId: Registered model to use.
    /// - Returns: The generated shell command.
    public func generate(
        from naturalLanguage: String,
        terminalContext: String?,
        providerId: UUID,
        modelId: UUID
    ) async throws -> String {
        let enriched: String
        if let ctx = terminalContext, !ctx.isEmpty {
            enriched = """
            Context:
            \(ctx)

            Intent:
            \(naturalLanguage)
            """
        } else {
            enriched = naturalLanguage
        }

        return try await service.generateCommand(enriched, providerId: providerId, modelId: modelId)
    }

    /// Build a context string from a ``TerminalEmulator`` instance.
    ///
    /// - Parameter terminal: The terminal to read state from.
    /// - Returns: A formatted context string, or `nil` if no useful context is available.
    public static func context(from terminal: TerminalEmulator) -> String? {
        var parts: [String] = []

        if let cwd = terminal.currentWorkingDirectory, !cwd.isEmpty {
            parts.append("Current directory: \(cwd)")
        }

        let visible = terminal.screenBuffer.visibleLines
        if !visible.isEmpty {
            let recent = visible.suffix(10).joined(separator: "\n")
            parts.append("Recent terminal output:\n\(recent)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
