import SwiftUI
import AIProvider
import AIAgent

@MainActor
final class AIViewModel: ObservableObject {
    @Published var selectedProviderId: UUID?
    @Published var selectedModelId: UUID?
    @Published var userPrompt = ""
    @Published var aiResponse = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeApprovals: [ApprovalRecord] = []
    @Published var selectedTab: AITab = .assistant

    enum AITab: String, CaseIterable {
        case assistant = "Assistant"
        case agent = "Agent"
        case skills = "Skills"
        case usage = "Usage"
    }

    weak var aiRegistry: AIProviderRegistry?

    func generateCommand(from intent: String) async {
        guard let registry = aiRegistry,
              let providerId = selectedProviderId,
              let provider = registry.getProvider(by: providerId),
              let modelId = selectedModelId ?? provider.defaultModelId as? UUID
        else { return }

        isLoading = true
        errorMessage = nil

        do {
            let router = APIRouter()
            let messages: [AIChatMessage] = [
                .init(role: "system", content: "You are a shell expert. Generate ONLY the shell command, no explanation."),
                .init(role: "user", content: intent)
            ]
            let result = try await router.sendMessage(
                provider: provider, model: provider.enabledModels.first!,
                messages: messages, tools: nil
            )
            aiResponse = result.content
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func explainError(_ errorText: String) async {
        guard let registry = aiRegistry,
              let providerId = selectedProviderId,
              let provider = registry.getProvider(by: providerId)
        else { return }

        isLoading = true
        do {
            let router = APIRouter()
            let messages: [AIChatMessage] = [
                .init(role: "system", content: "You are a terminal expert. Explain this error concisely and suggest fixes."),
                .init(role: "user", content: errorText)
            ]
            let result = try await router.sendMessage(
                provider: provider, model: provider.enabledModels.first!,
                messages: messages, tools: nil
            )
            aiResponse = result.content
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func reviewCommand(_ command: String) async -> RiskAssessment? {
        guard let registry = aiRegistry,
              let providerId = selectedProviderId,
              let provider = registry.getProvider(by: providerId)
        else { return nil }

        do {
            let router = APIRouter()
            let messages: [AIChatMessage] = [
                .init(role: "system", content: "Analyze this shell command for safety. Return JSON: {riskLevel, explanation, warnings}"),
                .init(role: "user", content: command)
            ]
            let result = try await router.sendMessage(
                provider: provider, model: provider.enabledModels.first!,
                messages: messages, tools: nil
            )
            return RiskAssessment(riskLevel: .safe, explanation: result.content, warnings: [], saferAlternative: nil)
        } catch {
            return nil
        }
    }
}

struct RiskAssessment {
    let riskLevel: RiskLevel
    let explanation: String
    let warnings: [String]
    let saferAlternative: String?
}
