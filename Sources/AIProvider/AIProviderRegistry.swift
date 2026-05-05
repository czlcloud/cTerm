import Foundation
import Combine

/// Main actor-bound registry that manages AI provider configurations and
/// provides a SwiftUI-friendly observable interface.
///
/// Persists provider data as JSON to:
/// `~/Library/Application Support/TerminalApp/ai_providers.json`
@MainActor
public final class AIProviderRegistry: ObservableObject {

    public static let shared: AIProviderRegistry = MainActor.assumeIsolated {
        AIProviderRegistry()
    }

    // MARK: - Published Properties

    /// All registered provider configurations.
    @Published public var providers: [AIProviderConfig] = []

    /// Recent usage records available for UI display. This is populated
    /// separately; the canonical usage log is managed by `UsageTracker`.
    @Published public var usageRecords: [UsageRecord] = []

    // MARK: - Coders

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - File URL

    private var providersURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TerminalApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        return appDir.appendingPathComponent("ai_providers.json")
    }

    // MARK: - Init

    public init() {
        loadProviders()
    }

    // MARK: - CRUD

    /// Add a new provider configuration. If a provider with the same `id`
    /// already exists the call is ignored.
    public func addProvider(_ provider: AIProviderConfig) {
        guard !providers.contains(where: { $0.id == provider.id }) else { return }
        providers.append(provider)
        saveProviders()
    }

    /// Remove the provider with the given `id`.
    public func removeProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        saveProviders()
    }

    /// Replace an existing provider configuration in-place.
    /// If no provider with the matching `id` exists the call is ignored.
    public func updateProvider(_ provider: AIProviderConfig) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        saveProviders()
    }

    // MARK: - Lookup

    /// Returns the provider with the given `id`, or `nil`.
    public func getProvider(by id: UUID) -> AIProviderConfig? {
        providers.first { $0.id == id }
    }

    /// Selects the default model for the given provider.
    ///
    /// The selection order is:
    /// 1. The model whose `id` matches the provider's `defaultModelId`.
    /// 2. The first model in `enabledModels`.
    /// 3. `nil` if the provider has no enabled models.
    public func selectModel(for providerId: UUID) -> AIModel? {
        guard let provider = getProvider(by: providerId) else { return nil }
        if let defaultModel = provider.enabledModels.first(where: { $0.id == provider.defaultModelId }) {
            return defaultModel
        }
        return provider.enabledModels.first
    }

    // MARK: - Persistence

    private func saveProviders() {
        do {
            let data = try encoder.encode(providers)
            try data.write(to: providersURL, options: .atomic)
        } catch {
            print("AIProviderRegistry: Failed to save providers – \(error.localizedDescription)")
        }
    }

    private func loadProviders() {
        guard FileManager.default.fileExists(atPath: providersURL.path) else { return }
        do {
            let data = try Data(contentsOf: providersURL)
            providers = try decoder.decode([AIProviderConfig].self, from: data)
        } catch {
            print("AIProviderRegistry: Failed to load providers – \(error.localizedDescription)")
            providers = []
        }
    }
}
