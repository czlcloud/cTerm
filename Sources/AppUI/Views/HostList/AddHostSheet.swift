import SwiftUI
import HostStoreModule/* KeychainStore replaced by CredentialStore */
import SessionManager

struct AddHostSheet: View {
    let onSave: (HostDefinition) -> Void
    var availableHosts: [HostDefinition] = []
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsStore: SettingsStore
    var activeWorkspaceId: UUID = Workspace.defaultId

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = NSUserName()
    @State private var authMode: AuthModeChoice = .sshAgent
    @State private var password = ""
    @State private var keyPath = ""
    @State private var group = ""
    @State private var tags = ""
    @State private var keepAlive = true
    @State private var jumpHostId: UUID?

    enum AuthModeChoice: String, CaseIterable {
        case password = "Password"
        case keyFile = "SSH Key"
        case sshAgent = "SSH Agent"

        var icon: String {
            switch self {
            case .password: "key.fill"
            case .keyFile: "doc.badge.gearshape"
            case .sshAgent: "person.badge.key"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Host")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Connection
                    Group {
                        Label("Connection", systemImage: "network")
                            .font(.headline)

                        HStack(spacing: 8) {
                            VStack(alignment: .leading) {
                                Text("Label").font(.caption).foregroundColor(.secondary)
                                TextField("e.g. Production Web", text: $label)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading) {
                                Text("Port").font(.caption).foregroundColor(.secondary)
                                TextField("22", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                            }
                        }

                        VStack(alignment: .leading) {
                            Text("Hostname").font(.caption).foregroundColor(.secondary)
                            TextField("192.168.1.1 or host.example.com", text: $hostname)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading) {
                            Text("Username").font(.caption).foregroundColor(.secondary)
                            TextField("root", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Divider()

                    // Authentication
                    Group {
                        Label("Authentication", systemImage: "lock.shield")
                            .font(.headline)

                        Picker("Method", selection: $authMode) {
                            ForEach(AuthModeChoice.allCases, id: \.self) { mode in
                                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch authMode {
                        case .password:
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        case .keyFile:
                            HStack {
                                TextField("Path to private key", text: $keyPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {
                                    let panel = NSOpenPanel()
                                    panel.showsHiddenFiles = true
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = false
                                    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                                    panel.begin { response in
                                        if response == .OK, let url = panel.url {
                                            keyPath = url.path
                                        }
                                    }
                                }
                            }
                        case .sshAgent:
                            Text("Will use SSH agent (ssh-agent) for authentication")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Connection options
                    Group {
                        Label("Options", systemImage: "gearshape").font(.headline)
                        Toggle("Keep-Alive (30s heartbeat)", isOn: $keepAlive)
                        if !availableHosts.isEmpty {
                            Picker("Jump Host (Bastion):", selection: $jumpHostId) {
                                Text("None (direct)").tag(nil as UUID?)
                                ForEach(availableHosts) { h in
                                    Text(h.label).tag(h.id as UUID?)
                                }
                            }
                        }
                    }

                    Divider()

                    // Organization
                    Group {
                        Label("Organization", systemImage: "folder")
                            .font(.headline)

                        VStack(alignment: .leading) {
                            Text("Group").font(.caption).foregroundColor(.secondary)
                            TextField("e.g. Production, Staging", text: $group)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading) {
                            Text("Tags").font(.caption).foregroundColor(.secondary)
                            TextField("comma, separated, tags", text: $tags)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    let host = buildHost()
                    // Save password to Keychain if using password auth
                    if case .password(let ref) = host.authMode, !password.isEmpty {
                        CredentialResolver.save(password: password, for: ref, preference: settingsStore.credentialPreference)
                    }
                    if case .keyFile(let path, let passRef) = host.authMode {
                        // TODO: save key passphrase to Keychain
                    }
                    onSave(host)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.isEmpty || hostname.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
        .onAppear {
            keepAlive = settingsStore.settings.globalKeepAlive
        }
    }

    private func buildHost() -> HostDefinition {
        let auth: AuthMode
        switch authMode {
        case .password:
            auth = .password(keychainRef: "password_\(UUID())")
        case .keyFile:
            auth = .keyFile(path: keyPath, passphraseKeychainRef: nil)
        case .sshAgent:
            auth = .sshAgent
        }

        return HostDefinition(
            label: label,
            hostname: hostname,
            port: UInt16(port) ?? 22,
            username: username,
            authMode: auth,
            keepAliveInterval: keepAlive ? settingsStore.settings.keepAliveInterval : 0,
            group: group.isEmpty ? nil : group,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            jumpHost: jumpHostId,
            lastUpdateTime: Date(),
            workspaceId: activeWorkspaceId
        )
    }
}
