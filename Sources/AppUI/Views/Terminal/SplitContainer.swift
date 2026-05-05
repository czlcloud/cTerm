import SwiftUI
import TerminalCore
import SessionManager

// MARK: - Session View

struct SessionView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        if sessionManager.workspaceState.windows.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "terminal").font(.system(size: 48)).foregroundColor(.secondary)
                Text("No Active Sessions").font(.title2)
                Text("Open a local terminal or connect to a host.").foregroundColor(.secondary)
            }
        } else {
            // Simple non-recursive view: show one terminal per window
            ForEach(sessionManager.workspaceState.windows) { window in
                WindowTerminalView(window: window, sessionManager: sessionManager)
            }
        }
    }
}

struct WindowTerminalView: View {
    let window: WindowState
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        let leaves = window.rootNode.allLeaves
        if let firstLeaf = leaves.first {
            VStack(spacing: 0) {
                if let tab = firstLeaf.activeTab {
                    Text(tab.title)
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
                if sessionManager.activeSessions[firstLeaf.id] != nil {
                    TerminalView(sessionId: firstLeaf.id, sessionManager: sessionManager)
                } else {
                    Text("VIEW WORKING - Emulator found").foregroundColor(.green).padding().background(Color.black)
                }
            }
        }
    }
}
