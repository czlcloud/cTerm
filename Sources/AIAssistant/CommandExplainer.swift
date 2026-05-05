import Foundation
import AIProvider
import TerminalCore

/// Convenience wrapper around ``AssistantService`` that includes terminal context
/// when asking the AI to explain an error or selected text.
public struct CommandExplainer {
    private let service: AssistantService

    public init(service: AssistantService) {
        self.service = service
    }

    /// Explain the given text (typically an error) in the context of the visible
    /// terminal buffer.
    ///
    /// - Parameters:
    ///   - selectedText: The error or text the user wants explained.
    ///   - terminal: The terminal emulator whose visible buffer provides context.
    ///   - providerId: Registered provider to use.
    ///   - modelId: Registered model to use.
    /// - Returns: An AI-generated explanation with suggested fixes.
    public func explain(
        selectedText: String,
        in terminal: TerminalEmulator,
        providerId: UUID,
        modelId: UUID
    ) async throws -> String {
        let contextLines = terminal.screenBuffer.visibleLines
        let contextText = contextLines.isEmpty
            ? "(no visible terminal output)"
            : contextLines.joined(separator: "\n")

        let fullInput = """
        Terminal output (visible buffer):
        \(contextText)

        ---

        Selected text / error:
        \(selectedText)
        """

        return try await service.explainError(fullInput, providerId: providerId, modelId: modelId)
    }

    /// Explain an error directly, with optional extra terminal context provided as a string.
    ///
    /// - Parameters:
    ///   - errorText: The error text to explain.
    ///   - terminalContext: Optional visible buffer content to include.
    ///   - providerId: Registered provider to use.
    ///   - modelId: Registered model to use.
    /// - Returns: An AI-generated explanation.
    public func explain(
        errorText: String,
        terminalContext: String?,
        providerId: UUID,
        modelId: UUID
    ) async throws -> String {
        var fullInput = errorText
        if let ctx = terminalContext, !ctx.isEmpty {
            fullInput = """
            Terminal output:
            \(ctx)

            Error:
            \(errorText)
            """
        }
        return try await service.explainError(fullInput, providerId: providerId, modelId: modelId)
    }
}
