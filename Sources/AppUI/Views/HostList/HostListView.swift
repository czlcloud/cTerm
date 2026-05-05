import SwiftUI
import HostStoreModule
import SessionManager
import SSHClient

struct HostListView: View {
    @EnvironmentObject var hostStore: HostStore
    @EnvironmentObject var sessionManager: SessionManager

    @Binding var showAddHost: Bool
    var onConnect: ((HostDefinition) -> Void)?
    var onConnectSFTP: ((HostDefinition) -> Void)?
    var activeWorkspaceId: UUID = Workspace.defaultId
    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var connectError: String?
    @State private var showError = false
    @State private var editingHost: HostDefinition?

    var filteredHosts: [HostDefinition] {
        var hosts = hostStore.hosts.filter { h in
            h.workspaceId == activeWorkspaceId || h.workspaceId == nil
        }
        if let group = selectedGroup {
            hosts = hosts.filter { $0.group == group }
        }
        if !searchText.isEmpty {
            hosts = hosts.filter {
                $0.label.localizedCaseInsensitiveContains(searchText) ||
                $0.hostname.localizedCaseInsensitiveContains(searchText)
            }
        }
        return hosts.sorted { $0.label < $1.label }
    }

    var groups: [String] { hostStore.groups }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search hosts...", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))

            // Group filter
            if !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        FilterChip(label: "All", selected: selectedGroup == nil) { selectedGroup = nil }
                        ForEach(groups, id: \.self) { group in
                            FilterChip(label: group, selected: selectedGroup == group) { selectedGroup = group }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }

            Divider()

            // Host list
            List {
                ForEach(filteredHosts) { host in
                    HostRow(host: host, onConnect: { onConnect?(host) },
                        onConnectSFTP: onConnectSFTP.map { sftp in { sftp(host) } },
                        onEdit: { editingHost = host },
                        onDelete: { try? hostStore.deleteHost(host) }
                    )
                }
            }
            .listStyle(.plain)

            // Bottom toolbar
            HStack {
                Button(action: { showAddHost = true }) {
                    Label("Add Host", systemImage: "plus")
                }
                Spacer()
                Text("\(filteredHosts.count) hosts").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .sheet(isPresented: $showAddHost) {
            AddHostSheet(
                onSave: { newHost in
                    try? hostStore.addLocalHost(newHost)
                    showAddHost = false
                },
                availableHosts: hostStore.hosts,
                activeWorkspaceId: activeWorkspaceId
            )
        }
        .alert("Connection Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(connectError ?? "Unknown error")
        }
        .sheet(item: $editingHost) { host in
            EditHostSheet(host: host) { updatedHost in
                try? hostStore.updateHost(updatedHost)
                editingHost = nil
            }
        }
    }

    private func connect(to host: HostDefinition) async {
        let sessionId = sessionManager.createSession(hostId: host.id, title: "\(host.username)@\(host.hostname)")

        // Use local PTY for localhost connections
        let isLocal = host.hostname == "localhost" || host.hostname == "127.0.0.1" || host.hostname == "::1"
        if isLocal && host.source == .local {
            do {
                try sessionManager.connectLocalSession(sessionId)
            } catch {
                connectError = error.localizedDescription
                showError = true
                sessionManager.closeSession(sessionId)
            }
            return
        }

        let config = SSHConfig(
            hostname: host.hostname,
            port: Int(host.port),
            username: host.username,
            authMethod: makeAuthMethod(for: host)
        )
        do {
            try await sessionManager.connectSession(sessionId, config: config)
        } catch {
            connectError = error.localizedDescription
            showError = true
            sessionManager.closeSession(sessionId)
        }
    }

    private func makeAuthMethod(for host: HostDefinition) -> AuthMethod {
        switch host.authMode {
        case .password(let ref):
            let pwd = (try? KeychainStore.shared.read(key: ref)) ?? ""
            return .password(pwd)
        case .keyFile(let path, let passRef):
            let pass = passRef.flatMap { try? KeychainStore.shared.read(key: $0) }
            return .pkeyFile(privateKey: path, passphrase: pass)
        case .sshAgent:
            return .sshAgent
        case .certificate(let data):
            return .certificate(data.base64EncodedString())
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? Color.accentColor : Color(nsColor: .controlColor))
                .foregroundColor(selected ? .white : .primary)
                .clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}
