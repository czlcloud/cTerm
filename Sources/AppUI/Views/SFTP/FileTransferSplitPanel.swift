import SwiftUI
import SessionManager
import HostStoreModule

// MARK: - Split Panel File Transfer

struct FileTransferSplitPanel: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var hostStore: HostStore
    var initialSessionId: UUID? = nil
    var activeWorkspaceId: UUID = Workspace.defaultId

    @StateObject private var leftFS = FileTransferState()
    @StateObject private var rightFS = FileTransferState()
    @State private var leftSelectedHostId: UUID?
    @State private var rightSelectedHostId: UUID?

    private var availableHosts: [HostDefinition] {
        // Only show password-auth hosts, dedup by hostname:port, most recent wins
        let hosts = hostStore.hosts.filter { h in
            h.authMode.isPasswordAuth && (h.workspaceId == activeWorkspaceId || h.workspaceId == nil)
        }
        var best: [String: HostDefinition] = [:]
        for h in hosts {
            let key = "\(h.hostname):\(h.port)"
            if let existing = best[key] {
                if (h.lastUpdateTime ?? .distantPast) > (existing.lastUpdateTime ?? .distantPast) {
                    best[key] = h
                }
            } else {
                best[key] = h
            }
        }
        return Array(best.values).sorted { ($0.lastUpdateTime ?? .distantPast) > ($1.lastUpdateTime ?? .distantPast) }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                FileBrowserPanel(
                    fs: leftFS, selectedHostId: $leftSelectedHostId,
                    availableHosts: availableHosts,
                    isLeft: true, defaultLocal: true,
                    sessionManager: sessionManager, hostStore: hostStore
                )
                .frame(width: geo.size.width / 2)

                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)

                FileBrowserPanel(
                    fs: rightFS, selectedHostId: $rightSelectedHostId,
                    availableHosts: availableHosts,
                    isLeft: false, defaultLocal: false,
                    sessionManager: sessionManager, hostStore: hostStore
                )
                .frame(width: geo.size.width / 2 - 1)
            }
        }
        .onAppear {
            SFTPLogger.log("ui", "FileTransferSplitPanel appeared, initialSessionId=\(initialSessionId?.uuidString ?? "nil")")
            leftFS.isLocalMode = true
            leftFS.remotePath = NSHomeDirectory()
            leftFS.loadLocalDirectory()
            rightFS.remotePath = "/"
            if let sid = initialSessionId, let conn = sessionManager.activeConnections[sid] {
                let hostname = conn.hostname ?? ""
                if let host = hostStore.hosts.first(where: { $0.hostname == hostname }) {
                    rightSelectedHostId = host.id
                }
            }
        }
        .onChange(of: initialSessionId) { sid in
            guard let sid = sid, let conn = sessionManager.activeConnections[sid] else { return }
            let hostname = conn.hostname ?? ""
            if let host = hostStore.hosts.first(where: { $0.hostname == hostname }) {
                rightSelectedHostId = host.id
            }
        }
    }
}

// MARK: - Single File Browser Panel

struct FileBrowserPanel: View {
    @ObservedObject var fs: FileTransferState
    @Binding var selectedHostId: UUID?
    let availableHosts: [HostDefinition]
    let isLeft: Bool
    let defaultLocal: Bool
    let sessionManager: SessionManager
    let hostStore: HostStore
    @State private var showQuickConnect = false

    private var selectedHost: HostDefinition? {
        availableHosts.first(where: { $0.id == selectedHostId })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: isLeft ? "folder" : "server.rack")
                    .font(.caption).foregroundColor(.secondary)
                Text(isLeft ? "Local" : "Remote")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)

                if !defaultLocal {
                    Picker("", selection: $selectedHostId) {
                        Text("Select host...").tag(nil as UUID?)
                        Text("Local").tag(UUID())
                        ForEach(availableHosts) { host in
                            Text("\(host.hostname):\(host.port)").tag(host.id as UUID?)
                        }
                    }
                    .frame(width: 160)
                    .onChange(of: selectedHostId) { newVal in
                        if let hid = newVal, let host = availableHosts.first(where: { $0.id == hid }) {
                            fs.isLocalMode = false
                            fs.remotePath = "/"
                            loadRemoteDirectory(host: host)
                        } else {
                            fs.isLocalMode = true
                            fs.remotePath = NSHomeDirectory()
                            fs.loadLocalDirectory()
                        }
                    }
                }

                Spacer()
                Button("Quick Connect") { showQuickConnect = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Path bar
            HStack(spacing: 4) {
                Button(action: { goUp() }) {
                    Image(systemName: "arrow.up").font(.caption)
                }.buttonStyle(.plain).disabled(fs.remotePath == "/")

                TextField("/", text: $fs.remotePath).textFieldStyle(.plain).font(.caption)
                    .onSubmit { loadCurrentDir() }

                Button(action: { loadCurrentDir() }) {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }.buttonStyle(.plain).disabled(fs.isLoading)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)

            Divider()

            // Content
            if let error = fs.errorMessage {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.title3).foregroundColor(.orange)
                    Text(error).font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 4)
                    Button("Retry") { loadCurrentDir() }.buttonStyle(.bordered).controlSize(.small)
                }.frame(maxHeight: .infinity)
            } else if fs.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else if fs.entries.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "folder").font(.title3).foregroundColor(.secondary)
                    Text(defaultLocal ? "Home" : "Select a session").font(.caption).foregroundColor(.secondary)
                }.frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(fs.entries) { entry in
                        HStack(spacing: 4) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .font(.caption).foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                            Text(entry.name).font(.caption).lineLimit(1)
                            Spacer()
                            if !entry.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 1)
                        .background(fs.selectedName == entry.name ? Color.accentColor.opacity(0.15) : Color.clear)
                        .onTapGesture(count: 2) {
                            if entry.isDirectory {
                                fs.remotePath = fs.remotePath.hasSuffix("/")
                                    ? fs.remotePath + entry.name
                                    : fs.remotePath + "/" + entry.name
                                fs.selectedName = nil
                                loadCurrentDir()
                            }
                        }
                        .onTapGesture {
                            fs.selectedName = entry.name
                        }
                        .onDrag {
                            let info = "\(isLeft ? "L" : "R"):\(entry.name):\(entry.isDirectory)"
                            return NSItemProvider(object: info as NSString)
                        }
                        .contextMenu {
                            if !entry.isDirectory {
                                Button("Download") { downloadFile(entry) }
                            }
                            Button("Delete") { deleteFile(entry) }
                            Divider()
                            Button("Copy Path") {
                                let fullPath = fs.remotePath.hasSuffix("/")
                                    ? fs.remotePath + entry.name
                                    : fs.remotePath + "/" + entry.name
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fullPath, forType: .string)
                            }
                            Button("Rename...") { renameFile(entry) }
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .sheet(isPresented: $showQuickConnect) {
            FileTransferQuickConnect { result in
                showQuickConnect = false
                switch result {
                case .sftp(let client):
                    fs.isLocalMode = false
                    fs.quickConnectClient = client
                    fs.errorMessage = nil
                    fs.remotePath = "/"
                    fs.loadSFTPDir()
                case .ftp(let host, let port, let user, let pass):
                    fs.isLocalMode = false
                    fs.ftpHost = host; fs.ftpPort = port; fs.ftpUser = user; fs.ftpPass = pass
                    fs.ftpConnected = true
                    fs.errorMessage = nil
                    fs.remotePath = "/"
                    fs.loadFTPDirectory()
                case .smb(let mountPoint, let label):
                    fs.isLocalMode = false
                    fs.smbConnected = true
                    fs.smbMountPoint = mountPoint; fs.smbLabel = label
                    fs.errorMessage = nil
                    fs.remotePath = "/"
                    fs.loadSMBDirectory()
                }
            }
        }
    }

    private func goUp() {
        let comps = fs.remotePath.split(separator: "/")
        fs.remotePath = comps.isEmpty ? "/" : "/" + comps.dropLast().joined(separator: "/")
        loadCurrentDir()
    }

    private func loadCurrentDir() {
        if fs.isLocalMode {
            fs.loadLocalDirectory()
        } else if let host = selectedHost {
            loadRemoteDirectory(host: host)
        }
    }

    private func loadRemoteDirectory(host: HostDefinition) {
        if fs.isLoading { return }
        guard case .password(let ref) = host.authMode else {
            fs.errorMessage = "Password auth required."; return
        }
        let pwd = CredentialResolver.password(for: ref, preference: .credentialStore)
        if pwd.isEmpty { fs.errorMessage = "Password not stored."; return }

        fs.isLoading = true; fs.errorMessage = nil; fs.entries = []
        let path = fs.remotePath
        let hostname = host.hostname; let port = Int(host.port); let user = host.username

        Task { @MainActor in
            do {
                SFTPLogger.log("ui", "loadRemoteDirectory \(hostname):\(port) path=\(path)")
                let c = try await SFTPConnectionPool.shared.borrow(host: hostname, port: port, username: user, password: pwd)
                let raw = try await c.listDirectory(path)
                fs.entries = raw.map { fsEntry($0) }; fs.isLoading = false
                SFTPConnectionPool.shared.returnClient(c)
            } catch {
                SFTPLogger.log("ui", "loadRemoteDirectory FAILED: \(error.localizedDescription)")
                fs.errorMessage = error.localizedDescription; fs.isLoading = false
            }
        }
    }

    private func fsEntry(_ e: CitadelFileEntry) -> FileTransferPanel.FileEntry {
        FileTransferPanel.FileEntry(name: e.name, isDirectory: e.isDirectory, size: e.size)
    }

    // MARK: - Context menu actions

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                guard let str = data as? String,
                      let colonIdx = str.firstIndex(of: ":") else { return }
                let fromLeft = str.first == "L"
                let rest = str[str.index(after: colonIdx)...]
                let parts = rest.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let fname = String(parts[0])
                let isDir = parts[1] == "true"
                guard fromLeft != isLeft, !isDir else { return }

                let hostInfo: (hostname: String, port: Int, user: String, pwd: String)? = {
                    if !fromLeft, isLeft, let h = selectedHost, case .password(let ref) = h.authMode {
                        let p = CredentialResolver.password(for: ref, preference: .credentialStore)
                        return (h.hostname, Int(h.port), h.username, p)
                    }
                    return nil
                }()
                DispatchQueue.main.async {
                    fs.isLoading = true
                    let dstPath = fs.remotePath.hasSuffix("/") ? fs.remotePath : fs.remotePath + "/"
                    let rp = fs.remotePath
                    Task.detached { [hostInfo] in
                        do {
                            if let hi = hostInfo {
                                let rPath = rp.hasSuffix("/") ? rp + fname : rp + "/" + fname
                                let localURL = URL(fileURLWithPath: dstPath + fname)
                                let c = try await SFTPConnectionPool.shared.borrow(host: hi.hostname, port: hi.port, username: hi.user, password: hi.pwd)
                                try await c.download(rPath, to: localURL)
                                await SFTPConnectionPool.shared.returnClient(c)
                            }
                            await MainActor.run { fs.isLoading = false; loadCurrentDir() }
                        } catch {
                            await MainActor.run { fs.errorMessage = error.localizedDescription; fs.isLoading = false }
                        }
                    }
                }
            }
        }
    }

    private func downloadFile(_ entry: FileTransferPanel.FileEntry) {
        guard !entry.isDirectory else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            fs.isLoading = true
            let path = fs.remotePath; let fname = entry.name
            let isLocal = fs.isLocalMode
            let host = selectedHost
            let hostCopy: (hostname: String, port: Int, user: String, pwd: String)? = {
                guard let h = host, case .password(let ref) = h.authMode else { return nil }
                let p = CredentialResolver.password(for: ref, preference: .credentialStore)
                if p.isEmpty { return nil }
                return (h.hostname, Int(h.port), h.username, p)
            }()
            Task.detached {
                do {
                    if isLocal {
                        let src = URL(fileURLWithPath: path.hasSuffix("/") ? path + fname : path + "/" + fname)
                        try FileManager.default.copyItem(at: src, to: url)
                    } else if let hc = hostCopy {
                        let c = try await SFTPConnectionPool.shared.borrow(host: hc.hostname, port: hc.port, username: hc.user, password: hc.pwd)
                        try await c.download(path.hasSuffix("/") ? path + fname : path + "/" + fname, to: url)
                        await SFTPConnectionPool.shared.returnClient(c)
                    }
                    await MainActor.run { fs.isLoading = false }
                } catch {
                    await MainActor.run { fs.errorMessage = error.localizedDescription; fs.isLoading = false }
                }
            }
        }
    }

    private func deleteFile(_ entry: FileTransferPanel.FileEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete '\(entry.name)'?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        fs.isLoading = true
        let path = fs.remotePath; let fname = entry.name
        let isLocal = fs.isLocalMode
        let hostCopy: (hostname: String, port: Int, user: String, pwd: String)? = {
            guard let h = selectedHost, case .password(let ref) = h.authMode else { return nil }
            let p = CredentialResolver.password(for: ref, preference: .credentialStore)
            if p.isEmpty { return nil }
            return (h.hostname, Int(h.port), h.username, p)
        }()
        Task.detached {
            do {
                if isLocal {
                    let full = URL(fileURLWithPath: path.hasSuffix("/") ? path + fname : path + "/" + fname)
                    try FileManager.default.removeItem(at: full)
                } else if let hc = hostCopy {
                    let c = try await SFTPConnectionPool.shared.borrow(host: hc.hostname, port: hc.port, username: hc.user, password: hc.pwd)
                    try await c.remove(path.hasSuffix("/") ? path + fname : path + "/" + fname)
                    await SFTPConnectionPool.shared.returnClient(c)
                }
                await MainActor.run { fs.isLoading = false; loadCurrentDir() }
            } catch {
                await MainActor.run { fs.errorMessage = error.localizedDescription; fs.isLoading = false }
            }
        }
    }

    // Same pattern: extract hostCopy before Task.detached
    // (already done above for download/delete — rename follows below)
    private func renameFile(_ entry: FileTransferPanel.FileEntry) {
        let alert = NSAlert(); alert.messageText = "Rename '\(entry.name)'"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = entry.name; alert.accessoryView = input
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != entry.name else { return }
        let path = fs.remotePath
        let oldPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
        let newPath = path.hasSuffix("/") ? path + newName : path + "/" + newName
        let isLocal = fs.isLocalMode
        let hostCopy: (hostname: String, port: Int, user: String, pwd: String)? = {
            guard let h = selectedHost, case .password(let ref) = h.authMode else { return nil }
            let p = CredentialResolver.password(for: ref, preference: .credentialStore)
            if p.isEmpty { return nil }
            return (h.hostname, Int(h.port), h.username, p)
        }()
        Task.detached {
            do {
                if isLocal {
                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                } else if let hc = hostCopy {
                    let c = try await SFTPConnectionPool.shared.borrow(host: hc.hostname, port: hc.port, username: hc.user, password: hc.pwd)
                    try await c.rename(from: oldPath, to: newPath)
                    await SFTPConnectionPool.shared.returnClient(c)
                }
                await MainActor.run { loadCurrentDir() }
            } catch {
                await MainActor.run { fs.errorMessage = error.localizedDescription }
            }
        }
    }
}

