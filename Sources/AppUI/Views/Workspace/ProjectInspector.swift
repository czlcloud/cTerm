import SwiftUI
import HostStoreModule
import SessionManager

struct ProjectInspectorView: View {
    let project: ProjectDefinition
    let workspace: WorkspaceDefinition
    @EnvironmentObject var hostStore: HostStore
    @State private var selectedHosts: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(project.name).font(.headline)
                    if let desc = project.description {
                        Text(desc).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            // Hosts section
            Text("Hosts").font(.subheadline).fontWeight(.medium)

            let projectHosts = hostStore.hosts.filter { project.hosts.contains($0.id) }

            if projectHosts.isEmpty {
                Text("No hosts assigned to this project")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(projectHosts) { host in
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .font(.caption)
                        VStack(alignment: .leading) {
                            Text(host.label).font(.caption).fontWeight(.medium)
                            Text("\(host.username)@\(host.hostname)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Tags
            if !project.tags.isEmpty {
                Text("Tags").font(.subheadline).fontWeight(.medium)
                FlowLayout(spacing: 4) {
                    ForEach(project.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("Open Layout") {
                    // Open project's default layout
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Run Health Check") {
                    // Run health checks
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? 0, subviews)
        let height = rows.last.map { $0.max(by: { $0.maxY < $1.maxY })?.maxY ?? 0 } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for row in rows {
            for frame in row {
                subviews[frame.index].place(at: CGPoint(x: bounds.minX + frame.minX,
                                                         y: bounds.minY + frame.minY),
                                             proposal: .unspecified)
            }
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [[(index: Int, minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)]] {
        var rows: [[(Int, CGFloat, CGFloat, CGFloat, CGFloat)]] = [[]]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
                rows.append([])
            }
            rows[rows.count - 1].append((i, x, x + size.width, y, y + size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}
