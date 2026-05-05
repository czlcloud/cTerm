import SwiftUI
import SSHClient
import SessionManager
import HostStoreModule

// MARK: - Helpers

private func createCitadelSFTP(host: String, port: Int, username: String, password: String) async throws -> CitadelSFTP {
    let client = CitadelSFTP()
    try await client.connect(host: host, port: port, username: username, password: password)
    return client
}

// MARK: - Unified File Transfer Panel (SFTP / FTP + SMB via Quick Connect)

// MARK: - FileTransfer State (ObservableObject for background task access)

@MainActor
final class FileTransferState: ObservableObject {
    @Published var remotePath = "/"
    @Published var entries: [FileTransferPanel.FileEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedName: String?
    @Published var isLocalMode = false
    @Published var sftpClient: SFTPClient?
    var quickConnectClient: CitadelSFTP?
    var sftpConnectionCache: [UUID: Any] = [:]

    @Published var ftpConnected = false
    @Published var ftpHost = ""
    @Published var ftpPort = "21"
    @Published var ftpUser = ""
    @Published var ftpPass = ""
    @Published var smbConnected = false
    @Published var smbMountPoint: String?
    @Published var smbLabel: String = ""

    func loadLocalDirectory() {
        isLoading = true; errorMessage = nil
        let dir = remotePath
        let rp = remotePath
        Task.detached {
            let fm = FileManager.default
            var result: [FileTransferPanel.FileEntry] = []
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for name in contents.sorted() {
                    let full = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    result.append(FileTransferPanel.FileEntry(
                        name: name, isDirectory: isDir.boolValue,
                        size: (attrs?[.size] as? Int64) ?? 0
                    ))
                }
            }
            await MainActor.run { self.entries = result; self.isLoading = false }
        }
    }

    func loadFTPDirectory() {
        isLoading = true; errorMessage = nil
        let path = remotePath; let host = ftpHost; let port = ftpPort
        let user = ftpUser; let pass = ftpPass
        Task.detached {
            var result: [FileTransferPanel.FileEntry] = []
            let ftpURL = "ftp://\(host):\(port)\(path)"
            let task = Process()
            task.launchPath = "/usr/bin/curl"
            var args = ["-s", "--list-only", ftpURL, "--connect-timeout", "15", "--max-time", "30"]
            if !user.isEmpty && user != "anonymous" { args.append(contentsOf: ["-u", "\(user):\(pass)"]) }
            task.arguments = args
            let outPipe = Pipe(); let errPipe = Pipe()
            task.standardOutput = outPipe; task.standardError = errPipe
            task.launch(); task.waitUntilExit()
            if task.terminationStatus == 0 {
                if let list = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    for line in list.split(separator: "\n") {
                        let name = line.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, name != ".", name != ".." else { continue }
                        result.append(FileTransferPanel.FileEntry(name: name, isDirectory: !name.contains("."), size: 0))
                    }
                }
                await MainActor.run { self.entries = result; self.isLoading = false }
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "FTP failed"
                await MainActor.run { self.errorMessage = errMsg; self.isLoading = false }
            }
        }
    }

    func loadSMBDirectory() {
        guard let mp = smbMountPoint else { return }
        isLoading = true
        let dir = mp + remotePath
        Task.detached {
            let fm = FileManager.default
            var result: [FileTransferPanel.FileEntry] = []
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for name in contents.sorted() {
                    let full = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    result.append(FileTransferPanel.FileEntry(name: name, isDirectory: isDir.boolValue, size: (attrs?[.size] as? Int64) ?? 0))
                }
            }
            await MainActor.run { self.entries = result; self.isLoading = false }
        }
    }

    /// Citadel-based directory listing (Quick Connect)
    func loadSFTPDir() {
        guard let client = quickConnectClient, !isLoading else { return }
        isLoading = true; errorMessage = nil
        let path = remotePath
        let clientCapture = client
        Task.detached {
            do {
                let raw = try await clientCapture.listDirectory(path)
                let mapped = raw.map { FileTransferPanel.FileEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size) }
                await MainActor.run { self.entries = mapped; self.isLoading = false }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription; self.isLoading = false }
            }
        }
    }

    func loadSFTPDir(client: SFTPClient) {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        let path = remotePath
        let clientCapture = client
        Task.detached {
            do {
                let list = try clientCapture.listDirectory(path)
                let mapped = list.map {
                    FileTransferPanel.FileEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
                }
                await MainActor.run {
                    self.entries = mapped
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.sftpClient = nil
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - FileTransferPanel

struct FileTransferPanel: View {
    @EnvironmentObject var sessionManager: SessionManager
    var initialSessionId: UUID? = nil
    @StateObject private var fs = FileTransferState()

    // --- UI state (not accessed from background) ---
    @State private var selectedHost: UUID?
    @State private var availableHosts: [(UUID, String)] = []
    @State private var showDirectConnect = false

    struct FileEntry: Identifiable {
        var id: String { name }
        var name: String
        var isDirectory: Bool
        var size: Int64
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                if fs.smbConnected {
                    Image(systemName: "externaldrive").foregroundColor(.green)
                    Text(fs.smbLabel).font(.body).fontWeight(.medium)
                    Spacer()
                    Button(action: disconnectSMB) {
                        HStack(spacing: 4) {
                            Image(systemName: "eject").foregroundColor(.red)
                            Text("Disconnect")
                        }
                    }.buttonStyle(.bordered).controlSize(.small)
                } else if fs.ftpConnected {
                    Image(systemName: "arrow.up.arrow.down").foregroundColor(.green)
                    Text("FTP \(fs.ftpHost):\(fs.ftpPort)").font(.body).fontWeight(.medium)
                    Spacer()
                    Button(action: disconnectFTP) {
                        HStack(spacing: 4) {
                            Image(systemName: "eject").foregroundColor(.red)
                            Text("Disconnect")
                        }
                    }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Picker("Session:", selection: $selectedHost) {
                        Text("Select session...").tag(nil as UUID?)
                        Text("💻 Local Filesystem").tag(localFilesystemTag)
                        ForEach(availableHosts, id: \.0) { id, label in
                            Text(label).tag(id as UUID?)
                        }
                    }.frame(width: 260)
                    .onChange(of: selectedHost) { newVal in
                        if newVal == localFilesystemTag {
                            fs.isLocalMode = true; fs.sftpClient = nil; fs.smbConnected = false
                            fs.remotePath = NSHomeDirectory()
                            fs.errorMessage = nil
                            loadDirectory()
                        } else {
                            fs.isLocalMode = false
                            setupSFTP()
                        }
                    }

                    if selectedHost != nil && fs.sftpClient == nil && !fs.smbConnected && !fs.isLocalMode && fs.errorMessage == nil {
                        Button("Connect") { DispatchQueue.main.async { setupSFTP() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    Spacer()
                    Button("Quick Connect...") { showDirectConnect = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

            // Path bar
            HStack {
                Image(systemName: "folder")
                TextField("/", text: $fs.remotePath).textFieldStyle(.roundedBorder)
                    .onSubmit { DispatchQueue.main.async { loadDirectory() } }
                Button(action: { DispatchQueue.main.async { loadDirectory() } }) {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).disabled(fs.isLoading || !isReady)
            }
            .padding(.horizontal).padding(.vertical, 6)

            Divider()

            // Content area
            if let error = fs.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error)
                        .font(.caption).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    HStack(spacing: 12) {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Retry") { DispatchQueue.main.async { loadDirectory() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Spacer()
            } else if fs.isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if fs.entries.isEmpty && isReady {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundColor(.secondary)
                    Text("No files").foregroundColor(.secondary)
                }
                Spacer()
            } else if !isReady {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.largeTitle).foregroundColor(.secondary)
                    if availableHosts.isEmpty && selectedHost == nil {
                        Text("No active SSH sessions.")
                            .font(.headline).foregroundColor(.secondary)
                        Text("Connect to a host from the Hosts panel first, or use Quick Connect for FTP/SMB.\n(Type \"ssh\" inside a terminal does not create an app-managed session.)")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                    } else {
                        Text("Select a session above or Quick Connect to browse files.")
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            } else {
                List {
                    // Parent directory navigation (double-click or single)
                    if fs.remotePath != "/" {
                        HStack {
                            Image(systemName: "arrow.up.doc").foregroundColor(.accentColor)
                            Text("..").font(.body).fontWeight(.medium)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            let components = fs.remotePath.split(separator: "/")
                            fs.remotePath = components.isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
                            loadDirectory()
                        }
                        .onTapGesture {
                            let components = fs.remotePath.split(separator: "/")
                            fs.remotePath = components.isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
                            loadDirectory()
                        }
                    }
                    ForEach(fs.entries) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.body)
                                if !entry.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if fs.selectedName == entry.name {
                                Image(systemName: "checkmark").foregroundColor(.accentColor).font(.caption)
                            }
                        }
                        .padding(.vertical, 1)
                        .background(fs.selectedName == entry.name
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory {
                                fs.remotePath = fs.remotePath.hasSuffix("/")
                                    ? fs.remotePath + entry.name
                                    : fs.remotePath + "/" + entry.name
                                fs.selectedName = nil
                                loadDirectory()
                            }
                        }
                        .onTapGesture {
                            fs.selectedName = entry.name
                        }
                    }
                }.listStyle(.inset)
            }

            Divider()

            // Bottom toolbar
            HStack(spacing: 12) {
                Button("Upload...") { uploadFile() }
                    .buttonStyle(.bordered).disabled(!isReady)
                Button("Download...") { downloadSelected() }
                    .buttonStyle(.bordered).disabled(!isReady)
                Spacer()
                Button("Delete") {}.buttonStyle(.bordered).tint(.red).disabled(true)
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
        .onAppear {
            fs.isLoading = false; fs.errorMessage = nil
            refreshHosts()
            if let sid = initialSessionId, availableHosts.contains(where: { $0.0 == sid }) {
                selectedHost = sid
            }
        }
        .onChange(of: initialSessionId) { sid in
            guard let sid = sid else { return }
            refreshHosts()
            if availableHosts.contains(where: { $0.0 == sid }) { selectedHost = sid }
        }
        .sheet(isPresented: $showDirectConnect) {
            FileTransferQuickConnect { result in
                showDirectConnect = false
                switch result {
                case .sftp(let client):
                    fs.smbConnected = false; selectedHost = nil
                    fs.quickConnectClient = client
                    fs.ftpConnected = false; fs.isLocalMode = false
                    fs.errorMessage = nil
                    fs.remotePath = "/"
                    fs.loadSFTPDir()  // uses CitadelSFTP internally
                case .ftp(let host, let port, let user, let pass):
                    fs.sftpClient = nil; fs.smbConnected = false; fs.isLocalMode = false
                    fs.ftpHost = host; fs.ftpPort = port; fs.ftpUser = user; fs.ftpPass = pass
                    fs.ftpConnected = true; selectedHost = nil
                    fs.errorMessage = nil
                    loadDirectory()
                case .smb(let mountPoint, let label):
                    fs.sftpClient = nil
                    fs.smbMountPoint = mountPoint
                    fs.smbLabel = label
                    fs.smbConnected = true
                    fs.remotePath = "/"
                    fs.errorMessage = nil
                    loadDirectory()
                }
            }
        }
    }

    // MARK: - State helpers

    /// Sentinel UUID for the "Local Filesystem" picker option
    private let localFilesystemTag: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var isReady: Bool {
        if fs.isLocalMode { return true }
        if fs.ftpConnected { return !fs.ftpHost.isEmpty }
        if fs.smbConnected { return fs.smbMountPoint != nil }
        if fs.sftpClient != nil { return true }
        // Citadel path: ready when we have entries and no error
        if !fs.entries.isEmpty { return true }
        return false
    }

    // MARK: - SFTP

    private func refreshHosts() {
        availableHosts = sessionManager.activeConnections
            .filter { $0.value.status == .authenticated }
            .map { (id, conn) in
                let host = conn.hostname ?? "unknown"
                return (id, "\(host) (\(id.uuidString.prefix(8)))")
            }
        if selectedHost == nil, let first = availableHosts.first {
            selectedHost = first.0
        }
    }

    private func setupSFTP() {
        guard !fs.smbConnected else { return }
        fs.sftpClient = nil
        fs.entries = []
        fs.selectedName = nil
        guard let hostId = selectedHost,
              let conn = sessionManager.activeConnections[hostId] else {
            fs.errorMessage = nil
            return
        }
        guard conn.status == .authenticated else {
            fs.errorMessage = "This session is not authenticated. Check the terminal connection."
            return
        }
        loadDirectory()
    }

    // MARK: - Local filesystem

    private func loadLocalDirectory() {
        fs.isLoading = true; fs.errorMessage = nil
        let dir = fs.remotePath
        let rp = fs.remotePath
        Task.detached {
            let fm = FileManager.default
            var result: [FileEntry] = []
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for name in contents.sorted() {
                    let full = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    result.append(FileEntry(
                        name: name, isDirectory: isDir.boolValue,
                        size: (attrs?[.size] as? Int64) ?? 0
                    ))
                }
            }
            await MainActor.run { fs.entries = result; fs.isLoading = false }
        }
    }

    // MARK: - FTP

    private func loadFTPDirectory() {
        fs.isLoading = true; fs.errorMessage = nil
        let path = fs.remotePath
        let host = fs.ftpHost; let port = fs.ftpPort; let user = fs.ftpUser; let pass = fs.ftpPass
        Task.detached {
            var result: [FileEntry] = []
            let ftpURL = "ftp://\(host):\(port)\(path)"
            let task = Process()
            task.launchPath = "/usr/bin/curl"
            var args = ["-s", "--list-only", ftpURL, "--connect-timeout", "15", "--max-time", "30"]
            if !user.isEmpty && user != "anonymous" {
                args.append(contentsOf: ["-u", "\(user):\(pass)"])
            }
            task.arguments = args
            let outPipe = Pipe(); let errPipe = Pipe()
            task.standardOutput = outPipe; task.standardError = errPipe
            task.launch(); task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let list = String(data: data, encoding: .utf8) {
                    for line in list.split(separator: "\n") {
                        let name = line.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, name != ".", name != ".." else { continue }
                        // curl --list-only just returns names, can't tell dir vs file
                        let isDir = !name.contains(".") // best guess
                        result.append(FileEntry(name: name, isDirectory: isDir, size: 0))
                    }
                }
                await MainActor.run { fs.entries = result; fs.isLoading = false }
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "FTP failed"
                await MainActor.run { fs.errorMessage = errMsg; fs.isLoading = false }
            }
        }
    }

    private func disconnectFTP() {
        fs.ftpConnected = false; fs.ftpHost = ""; fs.entries = []
    }

    // MARK: - SMB

    private func disconnectSMB() {
        guard let mp = fs.smbMountPoint else { return }
        let task = Process()
        task.launchPath = "/sbin/umount"
        task.arguments = [mp]
        task.launch()
        task.waitUntilExit()
        try? FileManager.default.removeItem(atPath: mp)
        fs.smbMountPoint = nil
        fs.smbConnected = false
        fs.entries = []
    }

    // MARK: - Directory listing

    private func loadDirectory() {
        fs.selectedName = nil
        if fs.isLocalMode {
            loadLocalDirectory()
        } else if fs.ftpConnected {
            loadFTPDirectory()
        } else if fs.smbConnected {
            loadSMBDirectory()
        } else {
            loadOrInitSFTP()
        }
    }

    /// Resolve credentials from the active SSH session's config.
    private func resolveHostCreds(conn: SSHConnection?) -> (String, Int, String, String)? {
        guard let cfg = conn?.lastConfig,
              case .password(let pwd) = cfg.authMethod,
              !cfg.hostname.isEmpty else { return nil }
        return (cfg.hostname, cfg.port, cfg.username, pwd)
    }

    /// Ensures an SFTP client exists (lazy-init), then lists the directory.
    /// Always creates a new independent connection — no shared session.
    private func loadOrInitSFTP() {
        guard !fs.smbConnected else { return }
        guard !fs.isLoading else { return }

        fs.sftpClient = nil

        guard let hostId = selectedHost,
              let conn = sessionManager.activeConnections[hostId],
              conn.status == .authenticated else {
            fs.sftpClient = nil
            fs.errorMessage = "SSH session disconnected. Select it again to reconnect."
            return
        }
        fs.isLoading = true; fs.errorMessage = nil
        let path = fs.remotePath
        guard let creds = resolveHostCreds(conn: conn) else {
            fs.errorMessage = "Session credentials unavailable. Use 'Connect by SFTP' from Hosts panel, or Quick Connect."
            fs.isLoading = false
            return
        }
        let (host, port, user, pwd) = creds

        Task.detached {
            do {
                let client = CitadelSFTP()
                try await client.connect(host: host, port: port, username: user, password: pwd)
                let raw = try await client.listDirectory(path)
                let mapped = raw.map { FileEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size) }
                await client.disconnect()
                await MainActor.run {
                    fs.entries = mapped
                    fs.isLoading = false
                }
            } catch {
                await MainActor.run {
                    fs.errorMessage = error.localizedDescription
                    fs.isLoading = false
                }
            }
        }
    }

    private func loadSMBDirectory() {
        guard let mp = fs.smbMountPoint else { return }
        fs.isLoading = true
        let dir = mp + fs.remotePath
        let rp = fs.remotePath
        Task.detached {
            let fm = FileManager.default
            var result: [FileEntry] = []
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for name in contents.sorted() {
                    let full = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    result.append(FileEntry(
                        name: name, isDirectory: isDir.boolValue,
                        size: (attrs?[.size] as? Int64) ?? 0
                    ))
                }
            }
            await MainActor.run { fs.entries = result; fs.isLoading = false }
        }
    }

    // MARK: - Upload / Download

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            fs.isLoading = true
            let path = fs.remotePath
            if fs.isLocalMode {
                do {
                    let dest = URL(fileURLWithPath: (path as NSString).appendingPathComponent(url.lastPathComponent))
                    try FileManager.default.copyItem(at: url, to: dest)
                    loadDirectory()
                } catch {
                    fs.errorMessage = error.localizedDescription; fs.isLoading = false
                }
            } else if fs.ftpConnected {
                let host = fs.ftpHost; let port = fs.ftpPort; let user = fs.ftpUser; let pass = fs.ftpPass
                let destPath = path.hasSuffix("/") ? path + url.lastPathComponent : path + "/" + url.lastPathComponent
                let ftpURL = "ftp://\(host):\(port)\(destPath)"
                Task.detached {
                    let task = Process()
                    task.launchPath = "/usr/bin/curl"
                    var args = ["-T", url.path, ftpURL, "--connect-timeout", "15", "--max-time", "60"]
                    if !user.isEmpty && user != "anonymous" {
                        args.append(contentsOf: ["-u", "\(user):\(pass)"])
                    }
                    task.arguments = args
                    let errPipe = Pipe(); task.standardError = errPipe
                    task.launch(); task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        await MainActor.run { loadDirectory() }
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Upload failed"
                        await MainActor.run { fs.errorMessage = errMsg; fs.isLoading = false }
                    }
                }
            } else if fs.smbConnected, let mp = fs.smbMountPoint {
                do {
                    let dest = URL(fileURLWithPath: mp + path + "/" + url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                    loadDirectory()
                } catch {
                    fs.errorMessage = error.localizedDescription; fs.isLoading = false
                }
            } else {
                let upPath = path; let upURL = url
                let conn = sessionManager.activeConnections[selectedHost ?? UUID()]
                guard let creds = resolveHostCreds(conn: conn) else {
                    fs.errorMessage = "Host not found in Hosts panel."
                    fs.isLoading = false; return
                }
                let (host, port, user, pwd) = creds
                Task.detached {
                    do {
                        let client = CitadelSFTP()
                        try await client.connect(host: host, port: port, username: user, password: pwd)
                        try await client.upload(localURL: upURL, to: upPath + "/" + upURL.lastPathComponent)
                        await client.disconnect()
                        await MainActor.run { fs.isLoading = false; loadDirectory() }
                    } catch {
                        await MainActor.run { fs.errorMessage = error.localizedDescription; fs.isLoading = false }
                    }
                }
            }
        }
    }

    private func downloadSelected() {
        guard let name = fs.selectedName, let entry = fs.entries.first(where: { $0.name == name }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            fs.isLoading = true
            let path = fs.remotePath; let fname = entry.name
            if fs.isLocalMode {
                do {
                    let src = URL(fileURLWithPath: (path as NSString).appendingPathComponent(fname))
                    try FileManager.default.copyItem(at: src, to: url)
                    fs.isLoading = false
                } catch {
                    fs.errorMessage = error.localizedDescription; fs.isLoading = false
                }
            } else if fs.ftpConnected {
                let host = fs.ftpHost; let port = fs.ftpPort; let user = fs.ftpUser; let pass = fs.ftpPass
                let srcPath = path.hasSuffix("/") ? path + fname : path + "/" + fname
                let ftpURL = "ftp://\(host):\(port)\(srcPath)"
                Task.detached {
                    let task = Process()
                    task.launchPath = "/usr/bin/curl"
                    var args = ["-o", url.path, ftpURL, "--connect-timeout", "15", "--max-time", "60"]
                    if !user.isEmpty && user != "anonymous" {
                        args.append(contentsOf: ["-u", "\(user):\(pass)"])
                    }
                    task.arguments = args
                    let errPipe = Pipe(); task.standardError = errPipe
                    task.launch(); task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        await MainActor.run { fs.isLoading = false }
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Download failed"
                        await MainActor.run { fs.errorMessage = errMsg; fs.isLoading = false }
                    }
                }
            } else if fs.smbConnected, let mp = fs.smbMountPoint {
                do {
                    let src = URL(fileURLWithPath: mp + path + "/" + fname)
                    try FileManager.default.copyItem(at: src, to: url)
                    fs.isLoading = false
                } catch {
                    fs.errorMessage = error.localizedDescription; fs.isLoading = false
                }
            } else {
                let dlPath = path; let dlName = fname; let dlURL = url
                let conn = sessionManager.activeConnections[selectedHost ?? UUID()]
                guard let creds = resolveHostCreds(conn: conn) else {
                    fs.errorMessage = "Host not found in Hosts panel."
                    fs.isLoading = false; return
                }
                let (host, port, user, pwd) = creds
                Task.detached {
                    do {
                        let client = CitadelSFTP()
                        try await client.connect(host: host, port: port, username: user, password: pwd)
                        try await client.download(dlPath + "/" + dlName, to: dlURL)
                        await client.disconnect()
                        await MainActor.run { fs.isLoading = false }
                    } catch {
                        await MainActor.run { fs.errorMessage = error.localizedDescription; fs.isLoading = false }
                    }
                }
            }
        }
    }
}

// MARK: - Quick Connect Sheet (SFTP / FTP / SMB)

enum QuickConnectResult {
    case sftp(CitadelSFTP)
    case ftp(host: String, port: String, user: String, pass: String)
    case smb(mountPoint: String, label: String)
}

struct FileTransferQuickConnect: View {
    let onConnect: (QuickConnectResult) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = NSUserName()
    @State private var password = ""
    @State private var anonymous = false
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var proto = "SFTP"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick Connect").font(.title2).fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding()

            Divider()

            Form {
                Picker("", selection: $proto) {
                    Text("SFTP (SSH)").tag("SFTP")
                    Text("FTP").tag("FTP")
                    Text("SMB").tag("SMB")
                }
                .pickerStyle(.segmented)
                .onChange(of: proto) { p in
                    connectError = nil
                }

                if proto == "SMB" {
                    TextField("smb://server/share", text: $hostname)
                } else {
                    TextField("Hostname:", text: $hostname)
                }

                HStack {
                    TextField("Port:", text: $port)
                    Text(defaultPortHint)
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                }

                if proto == "SMB" || proto == "FTP" {
                    Toggle("Anonymous", isOn: $anonymous)
                        .onChange(of: anonymous) { _ in
                            if anonymous { username = "anonymous"; password = "" }
                            else { username = NSUserName() }
                        }
                }

                if !anonymous {
                    TextField("Username:", text: $username)
                    if proto != "SMB" {
                        SecureField("Password:", text: $password)
                    } else {
                        TextField("Password:", text: $password)
                    }
                }
            }
            .formStyle(.grouped).padding()

            if let error = connectError {
                ScrollView {
                    Text(error).font(.caption).foregroundColor(.red)
                }.frame(maxHeight: 120).padding(.horizontal)
            }

            Divider()
            HStack {
                Spacer()
                Button("Connect") {
                    isConnecting = true; connectError = nil
                    switch proto {
                    case "FTP": connectFTP()
                    case "SMB": connectSMB()
                    default: connectSFTP()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(hostname.isEmpty || isConnecting)
            }.padding()
        }
    }

    private var defaultPortHint: String {
        switch proto {
        case "FTP": "(default 21)"
        case "SMB": "(default 445)"
        default:    "(default 22)"
        }
    }

    private func connectSFTP() {
        let u = username; let p = password; let h = hostname; let pt = Int(port) ?? 22
        Task.detached {
            do {
                let client = CitadelSFTP()
                try await client.connect(host: h, port: pt, username: u, password: p)
                await MainActor.run { onConnect(.sftp(client)) }
            } catch {
                await MainActor.run { connectError = error.localizedDescription; isConnecting = false }
            }
        }
    }

    private func connectFTP() {
        isConnecting = true; connectError = nil
        let u = username; let p = password; let h = hostname; let pt = port
        let ftpURL = "ftp://\(h):\(pt)"
        Task.detached {
            let task = Process()
            task.launchPath = "/usr/bin/curl"
            var args = ["-v", "--list-only", ftpURL, "--connect-timeout", "10", "--max-time", "15"]
            if !u.isEmpty { args.append(contentsOf: ["-u", "\(u):\(p)"]) }
            task.arguments = args
            let errPipe = Pipe()
            task.standardError = errPipe
            task.launch(); task.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "FTP failed (no output)"

            if task.terminationStatus == 0 {
                await MainActor.run { isConnecting = false; onConnect(.ftp(host: h, port: pt, user: u, pass: p)) }
            } else {
                await MainActor.run { connectError = errMsg; isConnecting = false }
            }
        }
    }

    private func connectSMB() {
        isConnecting = true; connectError = nil
        // Build SMB URL with port if non-standard
        var shareURL = hostname
        if let pt = Int(port), pt != 445 {
            // Insert port into URL: smb://server/share → smb://server:port/share
            if shareURL.hasPrefix("smb://") {
                let rest = String(shareURL.dropFirst(6)) // after smb://
                if let slashIdx = rest.firstIndex(of: "/") {
                    let server = rest[..<slashIdx]
                    let share = rest[slashIdx...]
                    shareURL = "smb://\(server):\(pt)\(share)"
                } else {
                    shareURL = "smb://\(rest):\(pt)"
                }
            }
        }
        let anon = anonymous
        let u = username; let p = password
        let tmpDir = "/tmp/terminal_smb_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        Task.detached {
            var ok = mountSMBSync(url: shareURL, user: nil, pass: nil, to: tmpDir)
            if !ok && !anon {
                ok = mountSMBSync(url: shareURL, user: u, pass: p, to: tmpDir)
            }

            if ok {
                let label = shareURL.replacingOccurrences(of: "smb://", with: "")
                await MainActor.run {
                    isConnecting = false
                    onConnect(.smb(mountPoint: tmpDir, label: label))
                }
            } else {
                try? FileManager.default.removeItem(atPath: tmpDir)
                await MainActor.run {
                    connectError = "SMB mount failed. Check the share URL and credentials."
                    isConnecting = false
                }
            }
        }
    }
}

private func mountSMBSync(url: String, user: String?, pass: String?, to dir: String) -> Bool {
    let task = Process()
    task.launchPath = "/sbin/mount_smbfs"

    if let u = user, !u.isEmpty {
        let urlStr = url.replacingOccurrences(of: "smb://", with: "")
        task.arguments = ["//\(u):\(pass ?? "")@\(urlStr)", dir]
    } else {
        task.arguments = ["-N", url, dir]
    }

    let errPipe = Pipe()
    task.standardError = errPipe
    task.launch()
    task.waitUntilExit()

    if task.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8) ?? ""
        if msg.contains("authentication") || msg.contains("Password") {
            return false
        }
    }
    return task.terminationStatus == 0
}


