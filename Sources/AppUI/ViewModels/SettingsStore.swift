import Foundation
import TerminalCore
import Combine

// MARK: - Credential Store Preference

public enum CredentialStorePreference: String, CaseIterable, Codable {
    case credentialStore = "Encrypted File"
    case keychain = "macOS Keychain"
    case both = "Both (auto)"
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: TerminalSettings {
        didSet { save() }
    }
    @Published public var credentialPreference: CredentialStorePreference = .credentialStore {
        didSet { save() }
    }
    @Published public var workspaceBaseDir: String = NSHomeDirectory() + "/.claude_workspaces" {
        didSet { save() }
    }
    @Published public var claudeModel: String = "sonnet" {
        didSet { save() }
    }
    @Published public var claudePermissionMode: String = "default" {
        didSet { save() }
    }

    private let url: URL

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalApp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) {
            settings = decoded.settings
            credentialPreference = decoded.credentialPreference ?? .both
            workspaceBaseDir = decoded.workspaceBaseDir ?? NSHomeDirectory() + "/.claude_workspaces"
            claudeModel = decoded.claudeModel ?? "sonnet"
            claudePermissionMode = decoded.claudePermissionMode ?? "default"
        } else {
            settings = .default
        }
    }

    private func save() {
        let data = SettingsData(settings: settings, credentialPreference: credentialPreference, workspaceBaseDir: workspaceBaseDir, claudeModel: claudeModel, claudePermissionMode: claudePermissionMode)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: url)
        }
    }

    private struct SettingsData: Codable {
        let settings: TerminalSettings
        var credentialPreference: CredentialStorePreference?
        var workspaceBaseDir: String?
        var claudeModel: String?
        var claudePermissionMode: String?
    }
}
