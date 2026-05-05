import SwiftUI

struct SnippetPanel: View {
    @State private var snippets: [CommandSnippet] = CommandSnippet.defaultSnippets
    @State private var searchText = ""
    @State private var showAddSheet = false

    var filtered: [CommandSnippet] {
        if searchText.isEmpty { return snippets }
        return snippets.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.command.localizedCaseInsensitiveContains(searchText) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search snippets...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No snippets")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { snippet in
                            SnippetCard(snippet: snippet, onRemove: {
                                snippets.removeAll { $0.id == snippet.id }
                            })
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

struct SnippetCard: View {
    let snippet: CommandSnippet
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snippet.name)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                ForEach(snippet.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            Text(snippet.command)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            if let desc = snippet.description {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet.command, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Send to Terminal") {
                    // Send command to active terminal
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CommandSnippet: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var description: String?
    var tags: [String]

    static let defaultSnippets: [CommandSnippet] = [
        .init(name: "Find large files", command: "find . -type f -size +100M -exec ls -lh {} \\;",
              description: "Find files larger than 100MB", tags: ["files", "disk"]),
        .init(name: "Check disk usage", command: "df -h", description: "Show disk usage in human-readable format", tags: ["disk"]),
        .init(name: "Memory usage", command: "free -m", description: "Show memory usage in MB", tags: ["system"]),
        .init(name: "NGINX error log", command: "tail -f /var/log/nginx/error.log",
              description: "Follow NGINX error log", tags: ["nginx", "logs"]),
        .init(name: "Docker cleanup", command: "docker system prune -af --volumes",
              description: "Remove all unused Docker data", tags: ["docker", "cleanup"]),
        .init(name: "List open ports", command: "lsof -i -P -n | grep LISTEN",
              description: "List all listening ports", tags: ["network"]),
    ]
}
