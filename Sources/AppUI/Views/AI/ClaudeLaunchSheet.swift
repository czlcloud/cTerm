import SwiftUI

struct ClaudeLaunchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessionName: String = ""
    @State private var resumePrevious = false
    @State private var workingDirectory: String = ""

    var defaultWorkDir: String?
    var onLaunch: (ClaudeSessionConfig) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Claude Session").font(.title2).fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding()

            HStack {
                Text("Model and permissions are configured in AI panel settings.json.")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
            }.padding(.horizontal).padding(.bottom, 4)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Working Directory
                VStack(alignment: .leading, spacing: 6) {
                    Text("Working Directory").font(.headline)
                    HStack {
                        TextField("", text: $workingDirectory).textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if !workingDirectory.isEmpty {
                                panel.directoryURL = URL(fileURLWithPath: workingDirectory)
                            } else if let d = defaultWorkDir {
                                panel.directoryURL = URL(fileURLWithPath: d)
                            }
                            if panel.runModal() == .OK, let url = panel.url {
                                workingDirectory = url.path
                            }
                        }
                    }
                    if let d = defaultWorkDir {
                        Text("Default: \(d)").font(.caption).foregroundColor(.secondary)
                    }
                }

                Divider()

                // Session Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session Name (optional)").font(.headline)
                    TextField("My Claude session", text: $sessionName).textFieldStyle(.roundedBorder)
                }

                // Resume
                Toggle("Resume previous session", isOn: $resumePrevious)
                    .font(.headline)
            }
            .padding()

            Divider()

            // Launch Button
            HStack {
                Spacer()
                Button(action: {
                    let config = ClaudeSessionConfig(
                        model: "sonnet",
                        permissionMode: "default",
                        allowedTools: ["Bash", "Read", "Edit", "Write"],
                        sessionName: sessionName.isEmpty ? nil : sessionName,
                        sessionId: UUID(),
                        resume: resumePrevious,
                        workingDirectory: workingDirectory.isEmpty ? defaultWorkDir : workingDirectory
                    )
                    onLaunch(config)
                    dismiss()
                }) {
                    Label("Launch", systemImage: "sparkles")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }.padding()
        }
        .frame(width: 460, height: 380)
        .onAppear {
            if let d = defaultWorkDir { workingDirectory = d }
        }
    }
}
