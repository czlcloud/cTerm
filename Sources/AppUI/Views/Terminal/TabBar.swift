import SwiftUI
import TerminalCore
import SessionManager

struct TabBar: View {
    let leafId: UUID
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabItem(
                            tab: tab,
                            isActive: tab.id == activeTab?.id,
                            onSelect: { selectTab(tab.id) },
                            onClose: { closeTab(tab.id) }
                        )
                    }
                }
            }

            Button(action: addTab) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tabs: [TabState] {
        sessionManager.workspaceState.windows
            .flatMap { $0.rootNode.allLeaves }
            .first { $0.id == leafId }?.tabs ?? []
    }

    private var activeTab: TabState? {
        sessionManager.workspaceState.windows
            .flatMap { $0.rootNode.allLeaves }
            .first { $0.id == leafId }?.activeTab
    }

    private func selectTab(_ tabId: UUID) {
        // Update activeTabIndex in workspaceState
    }

    private func closeTab(_ tabId: UUID) {
        // Remove tab from leaf
    }

    private func addTab() {
        // Create new tab in current leaf
    }
}

struct TabItem: View {
    let tab: TabState
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? Color(nsColor: .selectedControlColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { onSelect() }
    }
}
