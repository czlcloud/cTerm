import Foundation
import AppKit
import Combine
import TerminalCore
import SSHClient

// MARK: - SessionError

/// Errors thrown by `SessionManager` operations.
public enum SessionError: Error, LocalizedError {
    /// No session with the given UUID exists.
    case sessionNotFound
    /// The SSH connection could not be established.
    case connectionFailed
    /// The SSH channel could not be opened.
    case channelFailed
    /// A session with the same UUID already exists.
    case duplicateSession

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:     return "Session not found"
        case .connectionFailed:    return "SSH connection failed"
        case .channelFailed:       return "Failed to open SSH channel"
        case .duplicateSession:    return "A session with this ID already exists"
        }
    }
}

// MARK: - SessionManager

/// The central coordinator for terminal sessions.
///
/// `SessionManager` owns the workspace state tree (`SplitNode`), manages the
/// lifecycle of every session's `TerminalEmulator`, `SSHConnection`, and
/// `SSHChannel`, and provides split-layout operations.  All of its properties
/// are `@Published` so SwiftUI views can observe changes.
///
/// All methods must be called from the main actor.
@MainActor
public final class SessionManager: ObservableObject {

    // MARK: Published Properties

    /// The full workspace layout and session metadata.
    @Published public var workspaceState: WorkspaceState

    /// Every active terminal emulator, keyed by session (leaf) UUID.
    @Published public var activeSessions: [UUID: TerminalEmulator] = [:]

    /// Every SSH connection, keyed by session UUID.  Connections are created
    /// eagerly but remain disconnected until `connectSession` is called.
    @Published public var activeConnections: [UUID: SSHConnection] = [:]

    /// Every open SSH channel (one per connected session).
    @Published public var activeChannels: [UUID: SSHChannel] = [:]

    /// Every active local shell (one per connected local session).
    @Published public var activeLocalShells: [UUID: LocalShell] = [:]


    /// Connection errors per session — cleared on success
    @Published public var sessionErrors: [UUID: String] = [:]
    @Published public var disconnectedSessions: Set<UUID> = []

    // MARK: Private Properties

    private let persistenceEngine: PersistenceEngine

    // Keys for task storage so we can cancel output-forwarding tasks on close.
    private var outputForwardingTasks: [UUID: Task<Void, Never>] = [:]
    private var firstFeed: [UUID: Bool] = [:]

    // MARK: Initialization

    /// Creates a session manager backed by the given persistence engine.
    ///
    /// - Parameter persistenceEngine: The persistence engine to use.  If `nil`,
    ///   a default `PersistenceEngine` is created.
public init(persistenceEngine: PersistenceEngine? = nil) {
        self.persistenceEngine = persistenceEngine ?? PersistenceEngine()
        self.workspaceState = WorkspaceState(
            windows: [],
            activeWindowId: UUID(),
            updatedAt: Date()
        )
    }

    // MARK: - Session Lifecycle

    /// Creates a new leaf session and its backing `TerminalEmulator` +
    /// `SSHConnection`, inserts it into the active window, and returns the new
    /// session's UUID.
    ///
    /// - Parameters:
    ///   - hostId: The `HostDefinition.id` this session is tied to.
    ///   - title:  The initial tab title.
    /// - Returns: The UUID of the newly created `LeafSession`.
  public func createSession(hostId: UUID, title: String,
                               foregroundColor: NSColor = .white,
                               backgroundColor: NSColor = .black) -> UUID {
        let defaultSize = TerminalSize(rows: 24, cols: 80)
        let tab = TabState(
            id: UUID(),
            title: title,
            cursorPosition: CursorState(row: 0, col: 0),
            terminalSize: defaultSize
        )

        let leaf = LeafSession(
            id: UUID(),
            hostId: hostId,
            tabs: [tab],
            activeTabIndex: 0,
            proportion: 1.0
        )

        // Create backing resources.
        let emulator = TerminalEmulator(size: defaultSize,
                                         foregroundColor: foregroundColor,
                                         backgroundColor: backgroundColor)
        activeSessions[leaf.id] = emulator

        let connection = SSHConnection()
        activeConnections[leaf.id] = connection

        // Insert into the workspace tree.
        insertLeafIntoActiveWindow(leaf)

        persist()
        return leaf.id
    }

    /// Connects an existing session to a remote host.
    ///
    /// The connection is established, authentication is performed, an SSH shell
    /// channel is opened, and the channel's `AsyncStream<Data>` output is
    /// forwarded to the terminal emulator.
    ///
    /// - Parameters:
    ///   - sessionId: The session to connect.
    ///   - config:    The SSH configuration (hostname, port, credentials, etc.).
    /// - Throws: `SessionError.sessionNotFound` if the session does not exist,
    ///   or any error from the SSH layer.
  public func connectSession(_ sessionId: UUID, config: SSHConfig) async throws {
        guard let connection = activeConnections[sessionId] else {
            throw SessionError.sessionNotFound
        }

        // Idempotent: skip if a channel is already open.
        guard activeChannels[sessionId] == nil else { return }
        disconnectedSessions.remove(sessionId); objectWillChange.send()

        // Offload blocking SSH handshake to background thread
        try await Task.detached {
            try connection.connect(config: config)
            try connection.authenticate(username: config.username, method: config.authMethod)
        }.value

        let channel = try SSHChannel(connection: connection)
        try channel.openShell(rows: 24, cols: 80)
        activeChannels[sessionId] = channel

        // Keep-alive for long-lived SSH connections
        if config.keepAliveInterval > 0 {
            connection.startKeepAlive(interval: config.keepAliveInterval)
        }

        // Forward channel output to the terminal emulator.
        let emulator = activeSessions[sessionId]
        let forwardingTask = Task { [weak self, weak emulator] in
            for await data in channel.outputStream {
                await MainActor.run {
                    emulator?.write(String(data: data, encoding: .utf8) ?? "")
                    if let sid = self?.activeSessions.first(where: { $0.value === emulator })?.key {
                        self?.appendScrollback(sessionId: sid, data: data)
                    }
                }
            }
            // Channel closed — mark as disconnected
            await MainActor.run {
                self?.disconnectedSessions.insert(sessionId); self?.objectWillChange.send()
            }
        }
        outputForwardingTasks[sessionId] = forwardingTask
    }

    /// Starts a local PTY shell for a session (no SSH).
    public func connectLocalSession(_ sessionId: UUID, shellPath: String = "/bin/zsh",
                                    workingDirectory: String? = nil,
                                    environment: [String: String] = [:]) throws {
        let shell = LocalShell()
        try shell.start(shell: shellPath, rows: 24, cols: 80, cwd: workingDirectory, environment: environment)
        activeLocalShells[sessionId] = shell
        disconnectedSessions.remove(sessionId); objectWillChange.send()

        let emulator = activeSessions[sessionId]
        emulator?.onSend = { [weak shell] response in
            shell?.write(response)
        }

        let forwardingTask = makeForwardingTask(sessionId: sessionId, shell: shell, emulator: emulator)
        outputForwardingTasks[sessionId] = forwardingTask
    }

    /// Non-blocking variant: runs `forkpty` off the main actor, then sets up
    /// forwarding on the main actor.
    public func connectLocalSessionAsync(_ sessionId: UUID, shellPath: String = "/bin/zsh",
                                         workingDirectory: String? = nil,
                                         environment: [String: String] = [:]) async throws {
        let shell = LocalShell()
        try await Task.detached {
            try shell.start(shell: shellPath, rows: 24, cols: 80, cwd: workingDirectory, environment: environment)
        }.value

        activeLocalShells[sessionId] = shell
        disconnectedSessions.remove(sessionId)
        sessionErrors.removeValue(forKey: sessionId)
        objectWillChange.send()

        let emulator = activeSessions[sessionId]
        emulator?.onSend = { [weak shell] response in
            shell?.write(response)
        }

        let forwardingTask = makeForwardingTask(sessionId: sessionId, shell: shell, emulator: emulator)
        outputForwardingTasks[sessionId] = forwardingTask
    }

    private func makeForwardingTask(sessionId: UUID, shell: LocalShell, emulator: TerminalEmulator?) -> Task<Void, Never> {
        let sid = sessionId
        dlog("PTY", "forwarding task started for \(sid)")
        return Task { [weak self, weak emulator, weak shell] in
            guard let shell else { dlog("PTY", "shell DEAD \(sid)"); return }
            for await data in shell.outputStream {
                await MainActor.run {
                    if let text = String(data: data, encoding: .utf8) {
                        emulator?.write(text)
                    }
                    self?.appendScrollback(sessionId: sid, data: data)
                }
            }
            dlog("PTY", "output stream ended for \(sid)")
        }
    }

        /// Resize the PTY for a local session.
    public func resizeLocalSession(_ sessionId: UUID, rows: Int32, cols: Int32) {
        guard rows > 0, cols > 0 else { return }
        if let shell = activeLocalShells[sessionId], shell.isRunning {
            shell.resize(rows: rows, cols: cols)
        }
    }

    /// Nonisolated helper for callers not on the main actor.
    public nonisolated func resizeLocalSessionNonIsolated(_ sessionId: UUID, rows: Int32, cols: Int32) {
        Task { @MainActor in
            resizeLocalSession(sessionId, rows: rows, cols: cols)
        }
    }

    /// Writes raw data to a session's channel (SSH or local).
    ///
    /// - Parameters:
    ///   - sessionId: The target session.
    ///   - data:      The raw bytes to send.
  public func writeToSession(_ sessionId: UUID, data: Data) {
        if let channel = activeChannels[sessionId] {
            Task { try? await channel.write(data) }
        } else if let shell = activeLocalShells[sessionId] {
            if let str = String(data: data, encoding: .utf8) { shell.write(str) }
        }
    }

    // MARK: - Split Layout Operations

    /// Splits the leaf containing the given session horizontally (side-by-side),
    /// creating a new leaf with the specified `hostId`.
    ///
    /// - Parameters:
    ///   - sessionId: The existing session to split at.
    ///   - newHostId: The `HostDefinition.id` for the newly created session.
  public func splitHorizontally(sessionId: UUID, newHostId: UUID) {
        splitSession(sessionId: sessionId, newHostId: newHostId, isHorizontal: true)
    }

    /// Splits the leaf containing the given session vertically (top-to-bottom),
    /// creating a new leaf with the specified `hostId`.
    ///
    /// - Parameters:
    ///   - sessionId: The existing session to split at.
    ///   - newHostId: The `HostDefinition.id` for the newly created session.
  public func splitVertically(sessionId: UUID, newHostId: UUID) {
        splitSession(sessionId: sessionId, newHostId: newHostId, isHorizontal: false)
    }

    /// Shared implementation for both split orientations.
    private func splitSession(sessionId: UUID, newHostId: UUID, isHorizontal: Bool) {
        guard
            let windowIndex = workspaceState.windows.firstIndex(
                where: { $0.id == workspaceState.activeWindowId }
            )
        else { return }

        let allLeaves = workspaceState.windows[windowIndex].rootNode.allLeaves
        guard let leafIndex = allLeaves.firstIndex(where: { $0.id == sessionId }) else { return }

        let originalLeaf = allLeaves[leafIndex]
        let defaultSize = originalLeaf.activeTab?.terminalSize ?? TerminalSize(rows: 24, cols: 80)

        // Create the new leaf.
        let newTab = TabState(
            id: UUID(),
            title: "Session",
            cursorPosition: CursorState(row: 0, col: 0),
            terminalSize: defaultSize
        )
        let newLeaf = LeafSession(
            id: UUID(),
            hostId: newHostId,
            tabs: [newTab],
            activeTabIndex: 0,
            proportion: 0.5
        )

        // Give each child half the available space.
        var updatedOriginal = originalLeaf
        updatedOriginal.proportion = 0.5

        let splitNode: SplitNode = isHorizontal
            ? .horizontal([.leaf(updatedOriginal), .leaf(newLeaf)])
            : .vertical([.leaf(updatedOriginal), .leaf(newLeaf)])

        // Replace the original leaf with the split container.
        var rootNode = workspaceState.windows[windowIndex].rootNode
        replaceInTree(node: &rootNode, leafId: sessionId, with: splitNode)
        workspaceState.windows[windowIndex].rootNode = rootNode
        objectWillChange.send()

        // Create backing resources for the brand‑new leaf.
        let emulator = TerminalEmulator(size: defaultSize)
        activeSessions[newLeaf.id] = emulator
        activeConnections[newLeaf.id] = SSHConnection()

        persist()
    }

    // MARK: - Close Session

    /// Closes a session and cleans up all associated resources.
    ///
    /// The SSH channel is closed, the connection is disconnected, the terminal
    /// emulator is removed, and the leaf is pruned from the split tree.
    ///
    /// - Parameter sessionId: The session to close.
  public func closeSession(_ sessionId: UUID) {
        // Stop output forwarding.
        outputForwardingTasks[sessionId]?.cancel()
        outputForwardingTasks.removeValue(forKey: sessionId)

        // Close the SSH channel.
        activeChannels[sessionId]?.close()
        activeChannels.removeValue(forKey: sessionId)

        // Terminate local shell.
        activeLocalShells[sessionId]?.terminate()
        activeLocalShells.removeValue(forKey: sessionId)

        // Disconnect the SSH connection.
        activeConnections[sessionId]?.stopKeepAlive()
        activeConnections[sessionId]?.disconnect()
        activeConnections.removeValue(forKey: sessionId)

        // Remove the terminal emulator.
        activeSessions.removeValue(forKey: sessionId)

        // Prune the leaf from the workspace tree.
        guard
            let windowIndex = workspaceState.windows.firstIndex(
                where: { $0.id == workspaceState.activeWindowId }
            )
        else {
            persist()
            return
        }

        workspaceState.windows[windowIndex].rootNode.removeLeaf(by: sessionId)
        objectWillChange.send()
        persist()
    }

    // MARK: - Persistence

    /// Persists the current workspace state to disk (internally debounced).
    ///
    /// This method is intentionally `internal` so it can be triggered by external
    /// code (e.g. window‑management callbacks) without exposing the full
    /// persistence implementation.
    internal func persist() {
        workspaceState.updatedAt = Date()
        persistenceEngine.saveWorkspaceState(workspaceState)
    }

    /// Restores sessions from the last persisted workspace state.
    ///
    /// For every leaf in the restored tree a new `TerminalEmulator` and
    /// `SSHConnection` are created.  Scrollback data is loaded from disk and
    /// fed into the emulator.  SSH channels are **not** re‑opened; the caller
    /// must explicitly reconnect each session.
    ///
    /// If no saved state exists, a default workspace with one empty window is
    /// initialized.
  public func restoreSession() {
        guard let savedState = persistenceEngine.loadWorkspaceState() else {
            // First launch — set up a default workspace.
            if workspaceState.windows.isEmpty {
                let window = WindowState(
                    id: UUID(),
                    rootNode: .leaf(
                        LeafSession(
                            id: UUID(),
                            hostId: UUID(),
                            tabs: [],
                            activeTabIndex: 0,
                            proportion: 1.0
                        )
                    ),
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                )
                workspaceState.windows = [window]
                workspaceState.activeWindowId = window.id
            }
            return
        }

        workspaceState = savedState

        // Recreate terminal emulators and load scrollback for each leaf.
        for leaf in workspaceState.windows.flatMap({ $0.rootNode.allLeaves }) {
            guard activeSessions[leaf.id] == nil else { continue }

            let terminalSize = leaf.activeTab?.terminalSize ?? TerminalSize(rows: 24, cols: 80)
            let emulator = TerminalEmulator(size: terminalSize)

            // Feed persisted scrollback into the emulator.
            let scrollbackData = persistenceEngine.loadScrollback(sessionId: leaf.id)
            if !scrollbackData.isEmpty {
                emulator.write(String(data: scrollbackData, encoding: .utf8) ?? "")
            }

            activeSessions[leaf.id] = emulator
            activeConnections[leaf.id] = SSHConnection()
        }
    }

    // MARK: - Private Helpers

    /// Inserts a leaf into the active window's split tree.  If the window does
    /// not exist a new window is created.
    private func insertLeafIntoActiveWindow(_ leaf: LeafSession) {
        if let windowIndex = workspaceState.windows.firstIndex(
            where: { $0.id == workspaceState.activeWindowId }
        ) {
            let rootLeaves = workspaceState.windows[windowIndex].rootNode.allLeaves

            if rootLeaves.isEmpty {
                workspaceState.windows[windowIndex].rootNode = .leaf(leaf)
            } else {
                // Split the first existing leaf to make room.
                let firstLeaf = rootLeaves[0]
                var updatedFirst = firstLeaf
                var updatedNew = leaf
                updatedFirst.proportion = 0.5
                updatedNew.proportion = 0.5
                workspaceState.windows[windowIndex].rootNode = .vertical([
                    .leaf(updatedFirst),
                    .leaf(updatedNew)
                ])
            }
            objectWillChange.send()
        } else {
            // No active window — create one.
            let window = WindowState(
                id: UUID(),
                rootNode: .leaf(leaf),
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
            workspaceState.windows.append(window)
            workspaceState.activeWindowId = window.id
            objectWillChange.send()
        }
    }

    /// Recursively walks the tree and replaces the leaf identified by `leafId`
    /// with `newNode`.
    private func replaceInTree(
        node: inout SplitNode,
        leafId: UUID,
        with newNode: SplitNode
    ) {
        switch node {
        case .leaf(let leaf):
            if leaf.id == leafId {
                node = newNode
            }
        case .horizontal(var children):
            for index in children.indices {
                replaceInTree(node: &children[index], leafId: leafId, with: newNode)
            }
            node = .horizontal(children)
        case .vertical(var children):
            for index in children.indices {
                replaceInTree(node: &children[index], leafId: leafId, with: newNode)
            }
            node = .vertical(children)
        }
    }

    /// Appends terminal output to the session's disk-backed scrollback buffer.
    private func appendScrollback(sessionId: UUID, data: Data) {
        Task.detached { [weak self] in
            await self?.persistenceEngine.appendScrollback(sessionId: sessionId, data: data)
        }
    }
}
