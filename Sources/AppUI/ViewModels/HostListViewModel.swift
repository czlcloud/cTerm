import SwiftUI
import HostStoreModule
import SessionManager
import SSHClient
import Combine

@MainActor
final class HostListViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedGroup: String?
    @Published var editingHost: HostDefinition?
    @Published var showAddSheet = false
    @Published var showEditSheet = false

    private let hostStore: HostStore
    private let sessionManager: SessionManager
    private var cancellables = Set<AnyCancellable>()

    var filteredHosts: [HostDefinition] {
        var hosts = hostStore.hosts

        if let group = selectedGroup {
            hosts = hosts.filter { $0.group == group }
        }

        if !searchText.isEmpty {
            hosts = hosts.filter {
                $0.label.localizedCaseInsensitiveContains(searchText) ||
                $0.hostname.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }

        return hosts.sorted { $0.label < $1.label }
    }

    var groups: [String] { hostStore.groups }

    init(hostStore: HostStore, sessionManager: SessionManager) {
        self.hostStore = hostStore
        self.sessionManager = sessionManager
    }

    func connect(to host: HostDefinition) async {
        let sessionId = sessionManager.createSession(
            hostId: host.id,
            title: "\(host.username)@\(host.hostname)"
        )

        let config = SSHConfig(
            hostname: host.hostname,
            port: Int(host.port),
            username: host.username,
            authMethod: authMethod(for: host)
        )

        do {
            try await sessionManager.connectSession(sessionId, config: config)
        } catch {
            print("Failed to connect: \(error)")
            sessionManager.closeSession(sessionId)
        }
    }

    private func authMethod(for host: HostDefinition) -> AuthMethod {
        switch host.authMode {
        case .password(let ref):
            if let password = try? KeychainStore.shared.read(key: ref) {
                return .password(password)
            }
            return .password("")
        case .keyFile(let path, let passphraseRef):
            let passphrase = passphraseRef.flatMap { try? KeychainStore.shared.read(key: $0) }
            return .pkeyFile(privateKey: path, passphrase: passphrase)
        case .sshAgent:
            return .sshAgent
        case .certificate(let data):
            return .certificate(data.base64EncodedString())
        }
    }

    func deleteHost(_ host: HostDefinition) {
        try? hostStore.deleteHost(host)
    }

    func selectGroup(_ group: String?) {
        selectedGroup = group
    }
}
