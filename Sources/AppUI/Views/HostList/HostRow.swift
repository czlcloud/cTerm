import SwiftUI
import HostStoreModule

struct HostRow: View {
    let host: HostDefinition
    let onConnect: () async -> Void
    let onConnectSFTP: (() -> Void)?
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        HStack {
            if let color = host.colorMark {
                Circle().fill(parseColor(color)).frame(width: 8, height: 8)
            }

            Image(systemName: host.source == .sshConfig ? "doc.text" : "desktopcomputer")
                .foregroundColor(host.source == .sshConfig ? .orange : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label).font(.body).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.caption).foregroundColor(.secondary)
                    if let updateTime = host.lastUpdateTime {
                        Text(updateTime, style: .relative)
                            .font(.caption2).foregroundColor(.secondary.opacity(0.6))
                    }
                    if let group = host.group {
                        Text(group)
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .background(Color(nsColor: .controlColor))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            if let error = errorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .help(error)
            }

            Button(action: {
                errorMessage = nil
                isConnecting = true
                Task {
                    await onConnect()
                    isConnecting = false
                }
            }) {
                if isConnecting {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3).foregroundColor(.accentColor)
                }
            }
            .buttonStyle(.plain)
            .help("Connect to \(host.label)")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Connect") { Task { await onConnect() } }
            if let onSFTP = onConnectSFTP {
                Button("Connect by SFTP") { onSFTP() }
            }
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func parseColor(_ name: String) -> Color {
        switch name {
        case "red": .red; case "orange": .orange; case "yellow": .yellow
        case "green": .green; case "blue": .blue; case "purple": .purple
        default: .gray
        }
    }
}
