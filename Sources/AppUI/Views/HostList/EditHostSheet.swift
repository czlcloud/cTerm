import SwiftUI
import HostStoreModule

struct EditHostSheet: View {
    let host: HostDefinition
    let onSave: (HostDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var label = ""
    @State private var hostname = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keyPath = ""
    @State private var group = ""
    @State private var keepAlive = true
    @State private var showPassword = false

    enum EditAuthMode: String, CaseIterable { case password, keyFile, sshAgent }
    @State private var editAuthMode: EditAuthMode = .password

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Host").font(.title2).fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding()

            Divider()

            Form {
                TextField("Label:", text: $label)
                TextField("Hostname:", text: $hostname)
                TextField("Port:", text: $portText)
                TextField("Username:", text: $username)

                Picker("Auth:", selection: $editAuthMode) {
                    Text("Password").tag(EditAuthMode.password)
                    Text("SSH Key").tag(EditAuthMode.keyFile)
                    Text("SSH Agent").tag(EditAuthMode.sshAgent)
                }.pickerStyle(.segmented)

                if editAuthMode == .password {
                    HStack {
                        if showPassword {
                            TextField("Password:", text: $password)
                        } else {
                            SecureField("Password:", text: $password)
                        }
                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }.buttonStyle(.plain)
                    }
                }

                if editAuthMode == .keyFile {
                    TextField("Private Key:", text: $keyPath)
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

                Toggle("Keep-Alive (30s heartbeat)", isOn: $keepAlive)

                TextField("Group:", text: $group)
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Save") {
                    var updated = host
                    updated.label = label
                    updated.hostname = hostname
                    updated.port = UInt16(portText) ?? 22
                    updated.username = username
                    updated.group = group.isEmpty ? nil : group
                    updated.keepAliveInterval = keepAlive ? host.keepAliveInterval : 0
                    updated.lastUpdateTime = Date()

                    // Update auth mode
                    switch editAuthMode {
                    case .password:
                        let ref = (host.authMode.keychainRefIfPassword) ?? "password_\(UUID())"
                        updated.authMode = .password(keychainRef: ref)
                        if !password.isEmpty {
                            CredentialResolver.save(password: password, for: ref, preference: settingsStore.credentialPreference)
                        }
                    case .keyFile:
                        updated.authMode = .keyFile(path: keyPath, passphraseKeychainRef: nil)
                    case .sshAgent:
                        updated.authMode = .sshAgent
                    }

                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.isEmpty || hostname.isEmpty)
            }.padding()
        }
        .frame(width: 400, height: 420)
        .onAppear {
            label = host.label
            hostname = host.hostname
            portText = String(host.port)
            username = host.username
            group = host.group ?? ""
            if case .keyFile(let path, _) = host.authMode {
                keyPath = path
            }
            keepAlive = host.keepAliveInterval > 0
            switch host.authMode {
            case .password: editAuthMode = .password
            case .keyFile:  editAuthMode = .keyFile
            case .sshAgent: editAuthMode = .sshAgent
            case .certificate: editAuthMode = .password
            }
        }
    }
}
