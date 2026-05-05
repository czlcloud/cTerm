import SwiftUI
import TerminalCore
import SessionManager
import HostStoreModule
import SSHClient
import AIProvider

struct ClaudeSessionConfig: Codable {
    var model: String = "sonnet"
    var permissionMode: String = "default"
    var allowedTools: Set<String> = ["Bash", "Read", "Edit", "Write"]
    var sessionName: String?
    var sessionId: UUID = UUID()
    var resume: Bool = false
    var workingDirectory: String?
}

extension Notification.Name {
    static let claudeApproval = Notification.Name("claudeApproval")
    static let launchClaudeCode = Notification.Name("launchClaudeCode")
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var hostStore: HostStore
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var aiRegistry: AIProviderRegistry

    enum SidebarTab: String, CaseIterable {
        case hosts = "Hosts", sessions = "Sessions", files = "File Transfer", ports = "Ports", keys = "Keys"
        case ai = "AI", snippets = "Snippets", settings = "Settings"

        var icon: String {
            switch self {
            case .hosts: "server.rack"; case .sessions: "terminal"; case .files: "arrow.triangle.branch"
            case .ports: "arrow.triangle.swap"; case .keys: "key"
            case .ai: "brain"; case .snippets: "text.alignleft"; case .settings: "gear"
            }
        }

        var isWorkspaceScoped: Bool {
            switch self {
            case .hosts, .sessions, .files, .ports, .keys: true
            case .ai, .snippets, .settings: false
            }
        }
    }

    struct TerminalTab: Identifiable {
        let id: UUID
        var title: String
        var profile: TerminalSettings
        var claudeConfig: ClaudeSessionConfig?
    }

    @State private var selectedTab: SidebarTab = .hosts
    @State private var showAddHost = false
    @State private var splitSessionId: UUID?
    @State private var sidebarVisible = false
    @State private var panelVisible: SidebarTab?
    @State private var claudeCodeError: String?
    @State private var showClaudeSheet = false
    @State private var claudeMonitors: [UUID: TokenMonitor] = [:]
    @State private var showWorkspaceSheet = false
    @State private var editingWorkspace: Workspace?
    @StateObject private var wm = WorkspaceManager()
    @State private var pendingSFTPHostId: UUID?

    var body: some View {
        ZStack {
            // Terminal always visible as background
            TerminalTabsView(tabs: $wm.openTabs, activeTabId: $wm.activeTabId,
                            splitSessionId: $splitSessionId, sessionManager: sessionManager,
                            settingsStore: settingsStore, workspaceManager: wm,
                            claudeMonitors: claudeMonitors,
                            onCloseTab: { tab in
                                claudeMonitors[tab.id]?.stop()
                                claudeMonitors.removeValue(forKey: tab.id)
                                wm.closeTab(tab)
                            })

            // Floating sidebar toggle button
            VStack {
                HStack {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }) {
                        Image(systemName: sidebarVisible ? "xmark" : "sidebar.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8).padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }

            // Floating sidebar overlay
            if sidebarVisible {
                HStack(spacing: 0) {
                    SidebarView(selectedTab: $selectedTab, onNewTerminal: newTerminalInWorkspace,
                                onHide: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } },
                                workspaces: wm.workspaces, activeWorkspaceId: $wm.activeWorkspaceId,
                                onSwitchWorkspace: { switchToWorkspace($0) },
                                onNewWorkspace: { newWorkspace() },
                                onEditWorkspace: { editWorkspace($0) },
                                onDeleteWorkspace: { deleteWorkspace($0) },
                                onClaudeCode: { launchClaudeDirect() },
                                onSelectTab: { tab in
                                    selectedTab = tab
                                    withAnimation { sidebarVisible = false }
                                    if tab != .sessions { panelVisible = tab }
                                })
                        .frame(width: 230)
                        .background(.regularMaterial)
                        .shadow(radius: 8)
                    Color.black.opacity(0.001)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } }
                }
                .transition(.move(edge: .leading))
            }

            // Overlay panel for non-terminal sidebar tabs
            if let panel = panelVisible {
                panelOverlay(for: panel)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Claude Code", isPresented: Binding(get: { claudeCodeError != nil }, set: { if !$0 { claudeCodeError = nil } })) {
            Button("OK") { claudeCodeError = nil }
            Button("AI Settings") { claudeCodeError = nil; selectedTab = .ai }
        } message: { Text(claudeCodeError ?? "") }
        .sheet(isPresented: $showClaudeSheet) {
            let ws = wm.workspaces.first(where: { $0.id == wm.activeWorkspaceId })
            let cwd = ws?.resolvedDirectory(baseDir: settingsStore.workspaceBaseDir)
            ClaudeLaunchSheet(defaultWorkDir: cwd, onLaunch: launchClaudeCode)
        }
        .sheet(isPresented: $showWorkspaceSheet) {
            EditWorkspaceSheet(workspace: editingWorkspace, defaultBaseDir: settingsStore.workspaceBaseDir,
                onSave: { name, dir in saveWorkspace(name: name, directory: dir) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeApproval)) { note in
            guard let key = note.userInfo?["key"] as? String, let activeId = wm.activeTabId,
                  let tab = wm.openTabs.first(where: { $0.id == activeId }), tab.claudeConfig != nil else { return }
            sessionManager.writeToSession(activeId, data: (key + "\r").data(using: .utf8) ?? Data())
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchClaudeCode)) { _ in showClaudeSheet = true }
    }

    @State private var panelSize: CGSize = .zero
    @State private var panelDragStart: CGSize?

    @ViewBuilder
    private func panelOverlay(for tab: SidebarTab) -> some View {
        let defaultW: CGFloat = 640, defaultH: CGFloat = 500
        let w = panelSize.width > 0 ? panelSize.width : defaultW
        let h = panelSize.height > 0 ? panelSize.height : defaultH
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { panelVisible = nil; panelSize = .zero }
            VStack(spacing: 0) {
                // Title bar with close + resize
                HStack {
                    Text(tab.rawValue).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                    Spacer()
                    Button(action: { panelVisible = nil; panelSize = .zero }) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).padding(5)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.top, 10)
                Divider().padding(.top, 8)
                // Content
                switch tab {
                case .hosts:
                    HostListView(showAddHost: $showAddHost, onConnect: openSession,
                                onConnectSFTP: openSessionForSFTP, activeWorkspaceId: wm.activeWorkspaceId)
                case .files:
                    FileTransferSplitPanel(initialSessionId: pendingSFTPHostId, activeWorkspaceId: wm.activeWorkspaceId)
                        .onAppear { pendingSFTPHostId = nil }
                case .ports: PortForwardPanel()
                case .keys: KeyManagerView()
                case .ai: AIPanel()
                case .snippets: SnippetPanel()
                case .settings: SettingsView()
                default: EmptyView()
                }
                Spacer(minLength: 0)
                // Resize handle — bottom-right corner
                HStack {
                    Spacer()
                    ZStack {
                        Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                            .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.4))
                    }.frame(width: 24, height: 24)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { val in
                            if panelDragStart == nil { panelDragStart = CGSize(width: w, height: h) }
                            panelSize = CGSize(
                                width: max(400, (panelDragStart?.width ?? defaultW) + val.translation.width),
                                height: max(300, (panelDragStart?.height ?? defaultH) + val.translation.height)
                            )
                        }
                        .onEnded { _ in panelDragStart = nil }
                )
            }
            .frame(width: w, height: h)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 16)
            .padding(40)
        }
    }

    // MARK: - Actions

    private func newTerminalInWorkspace() {
        let s = settingsStore.settings
        let ws = wm.workspaces.first(where: { $0.id == wm.activeWorkspaceId })
        let cwd = ws?.resolvedDirectory(baseDir: settingsStore.workspaceBaseDir)
        if let dir = cwd { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

        let title = "Terminal \(wm.openTabs.count + 1)"
        let id = sessionManager.createSession(hostId: UUID(), title: title,
                                               foregroundColor: s.foregroundColor.nsColor,
                                               backgroundColor: s.backgroundColor.nsColor)
        wm.openTabs.append(TerminalTab(id: id, title: title, profile: s, claudeConfig: nil))
        wm.activeTabId = id; sidebarVisible = false
        wm.trackTab(sessionId: id)

        Task {
            do {
                dlog("CV", "newTerminal sid=\(id) cwd=\(cwd ?? "nil")")
                try await sessionManager.connectLocalSessionAsync(id, shellPath: s.shellPath, workingDirectory: cwd)
            }
            catch { sessionManager.sessionErrors[id] = error.localizedDescription }
        }
    }

    private func launchClaudeDirect() {
        let s = settingsStore.settings
        let ws = wm.workspaces.first(where: { $0.id == wm.activeWorkspaceId })
        let cwd = ws?.resolvedDirectory(baseDir: settingsStore.workspaceBaseDir)
        if let dir = cwd { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

        let title = "Claude"
        let id = sessionManager.createSession(hostId: UUID(), title: title,
                                               foregroundColor: s.foregroundColor.nsColor,
                                               backgroundColor: s.backgroundColor.nsColor)
        wm.openTabs.append(TerminalTab(id: id, title: title, profile: s, claudeConfig: nil))
        wm.activeTabId = id; sidebarVisible = false
        wm.trackTab(sessionId: id)

        Task {
            do {
                try await sessionManager.connectLocalSessionAsync(id, shellPath: s.shellPath, workingDirectory: cwd)
                try await Task.sleep(nanoseconds: 500_000_000)
                let cmd: String = {
                    if let dir = cwd { return "cd \"\(dir)\" && claude --add-dir \"\(dir)\"\r" }
                    return "claude\r"
                }()
                await MainActor.run { sessionManager.writeToSession(id, data: cmd.data(using: .utf8) ?? Data()) }
            } catch { await MainActor.run { sessionManager.sessionErrors[id] = error.localizedDescription } }
        }
    }

    private func launchClaudeCode(config: ClaudeSessionConfig) {
        guard let provider = aiRegistry.providers.first(where: { $0.providerType == .anthropic }) else {
            claudeCodeError = "No Anthropic provider configured."; return
        }
        guard let apiKey = try? CredentialStore.shared.read(key: provider.apiKeyRef), !apiKey.isEmpty else {
            claudeCodeError = "API key not found."; return
        }
        let s = settingsStore.settings
        let title = config.sessionName ?? "Claude Code"
        let id = sessionManager.createSession(hostId: UUID(), title: title,
                                               foregroundColor: s.foregroundColor.nsColor,
                                               backgroundColor: s.backgroundColor.nsColor)
        let tab = TerminalTab(id: id, title: title, profile: s, claudeConfig: config)
        wm.openTabs.append(tab); wm.activeTabId = id; sidebarVisible = false
        wm.trackTab(sessionId: id)

        let monitor = TokenMonitor(sessionId: config.sessionId, model: resolveClaudeModel() ?? "sonnet")
        claudeMonitors[id] = monitor

        Task {
            do {
                if let dir = config.workingDirectory { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
                try await sessionManager.connectLocalSessionAsync(id, shellPath: s.shellPath, workingDirectory: config.workingDirectory, environment: ["ANTHROPIC_API_KEY": apiKey])
                try await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { sessionManager.writeToSession(id, data: buildClaudeArgs(config: config).data(using: .utf8) ?? Data()) }
            } catch { await MainActor.run { sessionManager.sessionErrors[id] = error.localizedDescription } }
        }
    }

    private func resolveClaudeModel() -> String? {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let model = env["ANTHROPIC_MODEL"] as? String else { return nil }
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("haiku") || lower.contains("flash") { return "haiku" }
        return "sonnet"
    }

    private func buildClaudeArgs(config: ClaudeSessionConfig) -> String {
        let model = resolveClaudeModel() ?? config.model
        var cmd = "claude --model \(model) --permission-mode \(config.permissionMode)"
        if !config.allowedTools.isEmpty {
            cmd += " --allowedTools \"\(config.allowedTools.sorted().joined(separator: ","))\""
        }
        cmd += " --session-id \(config.sessionId.uuidString)"
        if config.resume { cmd += " --continue" }
        if let name = config.sessionName { cmd += " --name \"\(name)\"" }
        if let dir = config.workingDirectory { cmd += " --add-dir \"\(dir)\"" }
        cmd += "\r"; return cmd
    }

    // MARK: - Sessions

    private func openSession(host: HostDefinition) {
        let id = sessionManager.createSession(hostId: host.id, title: host.label,
                                               foregroundColor: settingsStore.settings.foregroundColor.nsColor,
                                               backgroundColor: settingsStore.settings.backgroundColor.nsColor)
        wm.openTabs.append(TerminalTab(id: id, title: host.label, profile: settingsStore.settings, claudeConfig: nil))
        wm.activeTabId = id; sidebarVisible = false; wm.trackTab(sessionId: id)

        if let jumpId = host.jumpHost, let jumpHost = hostStore.hosts.first(where: { $0.id == jumpId }) {
            let jumpPort = jumpHost.port != 22 ? ":\(jumpHost.port)" : ""
            let jumpSpec = jumpHost.username.isEmpty ? "\(jumpHost.hostname)\(jumpPort)" : "\(jumpHost.username)@\(jumpHost.hostname)\(jumpPort)"
            let targetSpec = "\(host.username)@\(host.hostname)"
            let portFlag = host.port != 22 ? " -p \(host.port)" : ""
            let cmd = "ssh -J \(jumpSpec) \(targetSpec)\(portFlag)"
            Task {
                do { try await sessionManager.connectLocalSessionAsync(id, shellPath: "/bin/zsh"); await MainActor.run { sessionManager.writeToSession(id, data: (cmd + "\r").data(using: .utf8) ?? Data()) } }
                catch { print("Jump host failed: \(error)") }
            }
            return
        }
        let method = authMethod(for: host)
        let ka = settingsStore.settings.globalKeepAlive ? host.keepAliveInterval : 0
        let config = SSHConfig(hostname: host.hostname, port: Int(host.port), username: host.username, authMethod: method, keepAliveInterval: ka)
        Task { do { try await sessionManager.connectSession(id, config: config) } catch { print("SSH failed: \(error)") } }
    }

    private func openSessionForSFTP(host: HostDefinition) {
        let id = sessionManager.createSession(hostId: host.id, title: host.label,
                                               foregroundColor: settingsStore.settings.foregroundColor.nsColor,
                                               backgroundColor: settingsStore.settings.backgroundColor.nsColor)
        wm.openTabs.append(TerminalTab(id: id, title: host.label, profile: settingsStore.settings, claudeConfig: nil))
        wm.activeTabId = id; sidebarVisible = false; wm.trackTab(sessionId: id)
        let method = authMethod(for: host)
        let ka = settingsStore.settings.globalKeepAlive ? host.keepAliveInterval : 0
        let config = SSHConfig(hostname: host.hostname, port: Int(host.port), username: host.username, authMethod: method, keepAliveInterval: ka)
        Task {
            do { try await sessionManager.connectSession(id, config: config); await MainActor.run { pendingSFTPHostId = id; panelVisible = .files } }
            catch { print("SSH failed: \(error)") }
        }
    }

    private func authMethod(for host: HostDefinition) -> AuthMethod {
        switch host.authMode {
        case .password(let ref):
            if let pwd = try? CredentialStore.shared.read(key: ref) { return .password(pwd) }
            if let pwd = try? KeychainStore.shared.read(key: ref), !pwd.isEmpty { return .password(pwd) }
            return .password("")
        case .keyFile(let path, let passRef):
            let pass = passRef.flatMap { (try? CredentialStore.shared.read(key: $0)) ?? (try? KeychainStore.shared.read(key: $0)) }
            return .pkeyFile(privateKey: path, passphrase: pass)
        case .sshAgent: return .sshAgent
        case .certificate(let data): return .certificate(data.base64EncodedString())
        }
    }

    // MARK: - Workspace

    private func switchToWorkspace(_ ws: Workspace) {
        wm.switchToWorkspace(ws, sessionManager: sessionManager, settings: settingsStore.settings)
        splitSessionId = nil
    }

    private func newWorkspace() { editingWorkspace = nil; showWorkspaceSheet = true }
    private func editWorkspace(_ ws: Workspace) { editingWorkspace = ws; showWorkspaceSheet = true }

    private func deleteWorkspace(_ ws: Workspace) {
        guard ws.id != Workspace.defaultId else { return }
        let tabCount = (wm.workspaceTabs[ws.id] ?? []).count
        let alert = NSAlert()
        alert.messageText = "Delete workspace \"\(ws.name)\"?"
        alert.informativeText = tabCount > 0 ? "\(tabCount) active tab(s) will be closed." : "This cannot be undone."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { wm.deleteWorkspace(ws) }
    }

    private func saveWorkspace(name: String, directory: String?) {
        if let ws = editingWorkspace { wm.updateWorkspace(ws, name: name, directory: directory) }
        else { wm.createWorkspace(name: name, directory: directory) }
    }
}

// MARK: - TerminalTabsView

struct TerminalTabsView: View {
    @Binding var tabs: [ContentView.TerminalTab]
    @Binding var activeTabId: UUID?
    @Binding var splitSessionId: UUID?
    @ObservedObject var sessionManager: SessionManager
    var settingsStore: SettingsStore
    @ObservedObject var workspaceManager: WorkspaceManager
    var claudeMonitors: [UUID: TokenMonitor] = [:]
    var onCloseTab: ((ContentView.TerminalTab) -> Void)?

    private func newTerminal() {
        let s = settingsStore.settings
        let title = "Terminal \(tabs.count + 1)"
        let id = sessionManager.createSession(hostId: UUID(), title: title,
                                               foregroundColor: s.foregroundColor.nsColor,
                                               backgroundColor: s.backgroundColor.nsColor)
        tabs.append(ContentView.TerminalTab(id: id, title: title, profile: s, claudeConfig: nil))
        activeTabId = id; workspaceManager.trackTab(sessionId: id)
        Task { do { try await sessionManager.connectLocalSessionAsync(id, shellPath: s.shellPath) } catch { sessionManager.sessionErrors[id] = error.localizedDescription } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "terminal").font(.system(size: 48)).foregroundColor(.secondary)
                    Text("No Active Terminals").font(.title2)
                    Button(action: { newTerminal() }) {
                        Label("New Terminal", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.clear)
            } else {
                let slices = tabSlices()
                HStack(spacing: 0) {
                    HStack(spacing: 2) {
                        ForEach(slices.visible) { tab in
                            TabChip(title: tab.title, isActive: tab.id == activeTabId,
                                    onSelect: { activeTabId = tab.id }, onClose: { closeTab(tab) },
                                    onClone: { cloneTab(tab) }, onDuplicate: { duplicateTab(tab) })
                        }
                    }.padding(.horizontal, 4)
                    if !slices.overflow.isEmpty {
                        Menu { ForEach(slices.overflow) { tab in
                            Button(tab.title) { activeTabId = tab.id }
                            Button("Close \(tab.title)") { closeTab(tab) }
                        }} label: { Image(systemName: "ellipsis.circle").font(.caption) }
                            .menuStyle(.borderlessButton).frame(width: 24)
                    }
                    Spacer()
                    Button(action: { newTerminal() }) { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }.buttonStyle(.plain).padding(.horizontal, 6).help("New terminal")
                }.frame(height: 28).background(Color(nsColor: .controlBackgroundColor))
                Divider().opacity(0.4)

                ZStack {
                    ForEach(tabs.filter { sessionManager.activeSessions[$0.id] != nil }) { tab in
                        let isActive = tab.id == activeTabId
                        TerminalView(sessionId: tab.id, profile: tab.profile, claudeConfig: tab.claudeConfig, tokenMonitor: claudeMonitors[tab.id], isActive: isActive, sessionManager: sessionManager)
                            .id(tab.id)
                            .zIndex(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .disabled(!isActive)
                            .opacity(isActive ? 1 : 0)
                    }
                }
            }
        }
    }

    private func closeTab(_ tab: ContentView.TerminalTab) {
        sessionManager.closeSession(tab.id); tabs.removeAll { $0.id == tab.id }
        if activeTabId == tab.id { activeTabId = tabs.last?.id }
        if splitSessionId == tab.id { splitSessionId = nil }
        onCloseTab?(tab)
    }

    private func tabSlices() -> (visible: [ContentView.TerminalTab], overflow: [ContentView.TerminalTab]) {
        let maxVisible = 8
        guard tabs.count > maxVisible else { return (tabs, []) }
        if let activeId = activeTabId, let idx = tabs.firstIndex(where: { $0.id == activeId }), idx >= maxVisible {
            var visible = Array(tabs.prefix(maxVisible - 1)); visible.append(tabs[idx])
            var overflow = [ContentView.TerminalTab]()
            for i in (maxVisible - 1)..<tabs.count where i != idx { overflow.append(tabs[i]) }
            return (visible, overflow)
        }
        return (Array(tabs.prefix(maxVisible)), Array(tabs.dropFirst(maxVisible)))
    }

    private func cloneTab(_ tab: ContentView.TerminalTab) {
        let s = settingsStore.settings
        let newId = sessionManager.createSession(hostId: UUID(), title: "Terminal \(tabs.count + 1)", foregroundColor: s.foregroundColor.nsColor, backgroundColor: s.backgroundColor.nsColor)
        tabs.append(ContentView.TerminalTab(id: newId, title: "Terminal \(tabs.count + 1)", profile: s, claudeConfig: nil))
        activeTabId = newId
        Task { do { try await sessionManager.connectLocalSessionAsync(newId, shellPath: s.shellPath) } catch { print("Clone failed: \(error)") } }
    }

    private func duplicateTab(_ tab: ContentView.TerminalTab) {
        var p = tab.profile; p.workingDirectory = sessionManager.activeLocalShells[tab.id]?.currentDirectory
        let title = "\(tab.title) copy"
        let newId = sessionManager.createSession(hostId: UUID(), title: title, foregroundColor: p.foregroundColor.nsColor, backgroundColor: p.backgroundColor.nsColor)
        tabs.append(ContentView.TerminalTab(id: newId, title: title, profile: p, claudeConfig: nil))
        activeTabId = newId
        Task { do { try sessionManager.connectLocalSession(newId, shellPath: p.shellPath, workingDirectory: p.workingDirectory) } catch { print("Duplicate failed: \(error)") } }
    }

    private func splitActiveTab() {
        guard let activeId = activeTabId, let activeTab = tabs.first(where: { $0.id == activeId }) else { return }
        let p = activeTab.profile
        let newId = sessionManager.createSession(hostId: UUID(), title: "Pane \(tabs.count + 1)", foregroundColor: p.foregroundColor.nsColor, backgroundColor: p.backgroundColor.nsColor)
        tabs.append(ContentView.TerminalTab(id: newId, title: "Pane \(tabs.count + 1)", profile: p, claudeConfig: nil))
        splitSessionId = newId
        Task { do { try sessionManager.connectLocalSession(newId, shellPath: p.shellPath) } catch { print("Pane failed: \(error)") } }
    }
}

// MARK: - Workspace

struct Workspace: Identifiable, Codable {
    let id: UUID; var name: String; var directory: String?
    static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    init(id: UUID = UUID(), name: String, directory: String? = nil) {
        self.id = id; self.name = name; self.directory = directory
    }

    func resolvedDirectory(baseDir: String) -> String {
        if let d = directory, !d.isEmpty { return d }
        let shortName = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return baseDir + "/" + shortName + "-" + id.uuidString.prefix(4)
    }
}

@MainActor
final class WorkspaceManager: ObservableObject {
    @Published var workspaces: [Workspace] = [Workspace(name: "Default")]
    @Published var activeWorkspaceId: UUID = Workspace.defaultId
    @Published var openTabs: [ContentView.TerminalTab] = []
    @Published var activeTabId: UUID?
    @Published var workspaceTabs: [UUID: [(id: UUID, title: String)]] = [:]

    func switchToWorkspace(_ ws: Workspace, sessionManager: SessionManager, settings: TerminalSettings) {
        workspaceTabs[activeWorkspaceId] = openTabs.map { (id: $0.id, title: $0.title) }
        activeWorkspaceId = ws.id
        let saved = workspaceTabs[ws.id] ?? []
        openTabs = saved.compactMap {
            if sessionManager.activeSessions[$0.id] != nil || sessionManager.activeConnections[$0.id] != nil {
                return ContentView.TerminalTab(id: $0.id, title: $0.title, profile: settings, claudeConfig: nil)
            }
            return nil
        }
        activeTabId = openTabs.last?.id
    }

    func createWorkspace(name: String, directory: String?) {
        workspaceTabs[activeWorkspaceId] = openTabs.map { (id: $0.id, title: $0.title) }
        let ws = Workspace(name: name, directory: directory)
        workspaces.append(ws); activeWorkspaceId = ws.id; openTabs = []; activeTabId = nil
    }

    func updateWorkspace(_ ws: Workspace, name: String, directory: String?) {
        guard let idx = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[idx].name = name; workspaces[idx].directory = directory
    }

    func deleteWorkspace(_ ws: Workspace) {
        guard ws.id != Workspace.defaultId else { return }
        workspaceTabs.removeValue(forKey: ws.id); workspaces.removeAll { $0.id == ws.id }
        if activeWorkspaceId == ws.id { activeWorkspaceId = workspaces.first?.id ?? Workspace.defaultId; openTabs = []; activeTabId = nil }
    }

    func trackTab(sessionId: UUID) {
        var tabs = workspaceTabs[activeWorkspaceId] ?? []
        if !tabs.contains(where: { $0.id == sessionId }) {
            let title = openTabs.first(where: { $0.id == sessionId })?.title ?? "Terminal"
            tabs.append((id: sessionId, title: title))
        }
        workspaceTabs[activeWorkspaceId] = tabs
    }

    func closeTab(_ tab: ContentView.TerminalTab) {
        var wt = workspaceTabs[activeWorkspaceId] ?? []
        wt.removeAll { $0.id == tab.id }; workspaceTabs[activeWorkspaceId] = wt
    }
}

// MARK: - Tab Chip

struct TabChip: View {
    let title: String; let isActive: Bool; let onSelect: () -> Void; let onClose: () -> Void
    let onClone: (() -> Void)?; let onDuplicate: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: 120)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 7, weight: .medium)) }.buttonStyle(.plain).opacity(0.5)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isActive ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { if isActive { Color.accentColor.frame(height: 2) } }
        .contentShape(Rectangle()).onTapGesture { onSelect() }
        .contextMenu {
            Button("Clone Tab") { onClone?() }
            Button("Clone with Profile") { onDuplicate?() }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selectedTab: ContentView.SidebarTab
    var onNewTerminal: () -> Void; var onHide: (() -> Void)?
    var workspaces: [Workspace]; @Binding var activeWorkspaceId: UUID
    var onSwitchWorkspace: (Workspace) -> Void; var onNewWorkspace: () -> Void
    var onEditWorkspace: (Workspace) -> Void; var onDeleteWorkspace: (Workspace) -> Void
    var onClaudeCode: (() -> Void)?
    var onSelectTab: ((ContentView.SidebarTab) -> Void)?

    private var activeWorkspace: Workspace? { workspaces.first(where: { $0.id == activeWorkspaceId }) }
    private var activeWorkspaceName: String { activeWorkspace?.name ?? "Default" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onHide = onHide { Button(action: onHide) { Image(systemName: "sidebar.left").font(.caption) }.buttonStyle(.plain).help("Hide sidebar") }
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider().opacity(0.5)

            // Workspace picker — larger
            VStack(spacing: 2) {
                Menu {
                    ForEach(workspaces) { ws in
                        Button(action: { onSwitchWorkspace(ws) }) {
                            HStack { Text(ws.name).font(.system(size: 13)); if ws.id == activeWorkspaceId { Image(systemName: "checkmark") } }
                        }
                    }
                    Divider()
                    Button("New Workspace...") { onNewWorkspace() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.split.2x2").font(.system(size: 14))
                        Text(activeWorkspaceName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 8)
                }.menuStyle(.borderlessButton)

                if let ws = activeWorkspace, ws.id != Workspace.defaultId {
                    HStack(spacing: 2) {
                        Button(action: { onEditWorkspace(ws) }) { Image(systemName: "pencil").font(.system(size: 10)) }.buttonStyle(.plain).help("Edit")
                        Button(action: { onDeleteWorkspace(ws) }) { Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red) }.buttonStyle(.plain).help("Delete")
                        Spacer()
                    }.padding(.horizontal, 14).padding(.bottom, 4)
                }
            }
            Divider().opacity(0.5).padding(.vertical, 4)

            // New Terminal dropdown — left-aligned with sidebar items
            HStack(spacing: 0) {
                Menu {
                    Button(action: onNewTerminal) { Label("New Terminal", systemImage: "terminal.fill") }
                    Button(action: { onClaudeCode?() }) { Label("New Claude Session", systemImage: "sparkles") }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill").frame(width: 18).font(.system(size: 14))
                        Text("New Terminal").font(.system(size: 13))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 5))
                }.menuStyle(.borderlessButton)
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider().opacity(0.5)

            // Workspace tabs
            VStack(spacing: 2) {
                ForEach(ContentView.SidebarTab.allCases.filter(\.isWorkspaceScoped), id: \.self) { tab in
                    sidebarButton(tab)
                }
            }
            Divider().opacity(0.5).padding(.vertical, 4)

            // Global tabs + Claude Code
            VStack(spacing: 2) {
                ForEach(ContentView.SidebarTab.allCases.filter { !$0.isWorkspaceScoped }, id: \.self) { tab in
                    sidebarButton(tab)
                }
                // Claude Code as a regular sidebar item
                Button(action: { onClaudeCode?() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").frame(width: 18).font(.system(size: 14))
                        Text("Claude Code").font(.system(size: 13)); Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
        }.frame(width: 220).background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(_ tab: ContentView.SidebarTab) -> some View {
        Button(action: { onSelectTab?(tab) }) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon).frame(width: 18).font(.system(size: 14))
                Text(tab.rawValue).font(.system(size: 13)); Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
            .background(selectedTab == tab ? Color.primary.opacity(0.06) : Color.clear)
            .overlay(alignment: .leading) { if selectedTab == tab { Color.accentColor.frame(width: 2.5) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Edit Workspace Sheet

struct EditWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace?; let defaultBaseDir: String; let onSave: (String, String?) -> Void
    @State private var name: String = ""; @State private var directory: String = ""

    private var isEditing: Bool { workspace != nil }
    private var hintPath: String { isEditing ? workspace!.resolvedDirectory(baseDir: defaultBaseDir) : defaultBaseDir + "/{id}" }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(isEditing ? "Edit Workspace" : "New Workspace").font(.title2).fontWeight(.bold); Spacer(); Button("Cancel") { dismiss() } }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) { Text("Name").font(.headline); TextField("My Workspace", text: $name).textFieldStyle(.roundedBorder) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Directory (optional)").font(.headline)
                    HStack { TextField("", text: $directory).textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            panel.directoryURL = URL(fileURLWithPath: directory.isEmpty ? defaultBaseDir : directory)
                            if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                        }
                    }
                    Text("Leave empty → \(hintPath)").font(.caption).foregroundColor(.secondary)
                }
            }.padding()
            Divider()
            HStack { Spacer(); Button("Save") { let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }; let d = directory.trimmingCharacters(in: .whitespaces); onSave(n, d.isEmpty ? nil : d); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command]).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding()
        }
        .frame(width: 440, height: 260)
        .onAppear {
            if let ws = workspace { name = ws.name; directory = ws.directory ?? "" }
            else { name = "Workspace \(UUID().uuidString.prefix(4))"; directory = "" }
        }
    }
}
