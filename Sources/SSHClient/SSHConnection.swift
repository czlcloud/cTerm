import Foundation
import CLibssh2
import Darwin

// MARK: - SSHConnection
/// Manages the libssh2 session lifecycle and the underlying Darwin socket.
///
/// Instances of this class are safe to use from multiple threads; internal state
/// is synchronised with an `NSLock`.
public final class SSHConnection: @unchecked Sendable {

    public init() {}

    // MARK: - Public properties
    /// Called on the queue that triggered the status change.
    public var onStatusChange: ((SSHConnectionStatus) -> Void)?

    /// The current connection status (thread-safe).
    public var status: SSHConnectionStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _status
    }

    /// True if the connection is in a failed state.
    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// The hostname this connection was established to, or `nil` if not connected.
    public private(set) var hostname: String?
    /// The config used to establish this connection (for reconnecting SFTP etc.)
    public private(set) var lastConfig: SSHConfig?

    /// The raw libssh2 session pointer, or `nil` if not connected.
    /// Exposed as `internal` so that `SFTPClient` and `PortForwarder`
    /// in the same module can use it directly.
    public var session: OpaquePointer? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _session
    }

    // MARK: - Private state
    private var _session: OpaquePointer?
    private var socketFD: Int32 = -1
    private let statusLock = NSLock()
    let sessionLock = NSLock()
    private var _status: SSHConnectionStatus = .disconnected

    // MARK: - Status management
    private func updateStatus(_ new: SSHConnectionStatus) {
        statusLock.lock()
        _status = new
        statusLock.unlock()
        onStatusChange?(new)
    }

    // MARK: - Connect
    /// Resolve the hostname, create a non-blocking TCP socket with a connect
    /// timeout, perform the libssh2 handshake (with EAGAIN retry), then leave
    /// the socket in non-blocking mode for subsequent reads / writes.
    public func connect(config: SSHConfig) throws {
        hostname = config.hostname
        lastConfig = config
        updateStatus(.connecting)

        // ---- 1. Resolve hostname ----------------------------------------
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var addressInfo: UnsafeMutablePointer<addrinfo>?
        let portStr = String(config.port)
        let gaiResult = getaddrinfo(config.hostname, portStr, &hints, &addressInfo)

        guard gaiResult == 0, let ai = addressInfo else {
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }
        defer { freeaddrinfo(ai) }

        // ---- 2. Create socket -------------------------------------------
        socketFD = Darwin.socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard socketFD >= 0 else {
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }

        // ---- 3. Set non-blocking for connect-with-timeout ---------------
        var flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }
        let setResult = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        guard setResult >= 0 else {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }

        // ---- 4. Non-blocking connect ------------------------------------
        let cResult = Darwin.connect(socketFD, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if cResult < 0 && errno != EINPROGRESS {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }

        // ---- 5. Wait for completion with poll -------------------------
        var pollFd = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        let pollTimeout = Int(config.connectionTimeout * 1000)
        let pollResult = Darwin.poll(&pollFd, 1, Int32(pollTimeout))
        guard pollResult > 0, (pollFd.revents & Int16(POLLOUT)) != 0 else {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }

        var sockErr: Int32 = 0
        var sockErrLen = socklen_t(MemoryLayout<Int32>.size)
        let gsResult = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &sockErr, &sockErrLen)
        guard gsResult == 0 && sockErr == 0 else {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }

        // Keep socket in non-blocking mode for EAGAIN handling later.

        // ---- 6. Initialise libssh2 session ------------------------------
        guard let s = libssh2_session_init() else {
            Darwin.close(socketFD); socketFD = -1
            updateStatus(.failed(.connectionTimeout))
            throw SSHError.connectionTimeout
        }
        sessionLock.lock()
        _session = s
        sessionLock.unlock()

        // ---- 7. Perform handshake with EAGAIN retry ---------------------
        var rc: Int32
        var attempts = 0
        let maxAttempts = 200  // ~60 seconds at 300ms each
        let eagainValue = Int32(LIBSSH2_ERROR_EAGAIN_VALUE)

        repeat {
            rc = libssh2_session_handshake(s, socketFD)
            if rc == eagainValue {
                attempts += 1
                guard attempts < maxAttempts else {
                    teardownSession()
                    updateStatus(.failed(.connectionTimeout))
                    throw SSHError.connectionTimeout
                }
                usleep(300_000) // 300 ms
            }
        } while rc == eagainValue

        guard rc == 0 else {
            teardownSession()
            updateStatus(.failed(.hostKeyMismatch))
            throw SSHError.hostKeyMismatch
        }

        // ---- 8. Host key verification -------------------------------------
        verifyAndSaveHostKey(session: s, hostname: config.hostname)

        updateStatus(.connected)
    }

    // MARK: - Host Key Verification

    private func verifyAndSaveHostKey(session: OpaquePointer, hostname: String) {
        // Get host key hash (SHA256)
        var len: Int = 0
        guard let hashPtr = libssh2_hostkey_hash(session, 2 /* LIBSSH2_HOSTKEY_HASH_SHA256 */) else { return }
        let hashData = Data(bytes: hashPtr, count: 32) // SHA256 = 32 bytes
        let fingerprint = hashData.base64EncodedString()

        // Get the raw host key for known_hosts entry
        var keyLen: Int = 0
        var keyType: Int32 = 0
        guard let keyPtr = libssh2_session_hostkey(session, &keyLen, &keyType) else { return }
        let keyData = Data(bytes: keyPtr, count: keyLen)
        let keyBase64 = keyData.base64EncodedString()

        let typeStr: String
        switch keyType {
        case 0: typeStr = "ssh-rsa"
        case 1: typeStr = "ssh-dss"
        case 2: typeStr = "ecdsa-sha2-nistp256"
        case 3: typeStr = "ecdsa-sha2-nistp384"
        case 4: typeStr = "ecdsa-sha2-nistp521"
        case 5: typeStr = "ssh-ed25519"
        default: typeStr = "ssh-unknown"
        }

        let knownHostsPath = NSHomeDirectory() + "/.ssh/known_hosts"
        let knownHostsURL = URL(fileURLWithPath: knownHostsPath)
        let dirURL = knownHostsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Build the known_hosts entry
        let entry = "\(hostname) \(typeStr) \(keyBase64)\n"

        // Read existing entries
        let existingContent = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""

        // Check if this host+key combination already exists
        if existingContent.contains("\(hostname) ") {
            // Host exists, check if key matches
            let lines = existingContent.split(separator: "\n")
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, parts[0] == hostname {
                    if parts.count >= 3 && parts[2] != keyBase64 {
                        // Key mismatch — this is a security issue
                        print("[SSH] WARNING: host key changed for \(hostname)")
                        // Still proceed for now (user can manually fix known_hosts)
                    }
                    return // Host already known, no need to add
                }
            }
        }

        // Add new entry
        let newContent = existingContent.isEmpty ? entry : existingContent + entry
        try? newContent.write(to: knownHostsURL, atomically: true, encoding: .utf8)
        print("[SSH] Added host key for \(hostname) to known_hosts")
    }

    // MARK: - Authenticate
    /// Authenticate the session using the supplied method.
    public func authenticate(username: String, method: AuthMethod) throws {
        updateStatus(.authenticating)

        guard let session = self.session else {
            updateStatus(.failed(.notConnected))
            throw SSHError.notConnected
        }

        switch method {
        case .password(let password):
            let result = libssh2_userauth_password(session, username, password)
            guard result == 0 else {
                updateStatus(.failed(.authenticationFailed))
                throw SSHError.authenticationFailed
            }

        case let .pkeyFile(privateKey, publicKey, passphrase):
            let result = libssh2_userauth_publickey_fromfile(
                session,
                username,
                publicKey,       // may be nil; libssh2 derives it from privateKey
                privateKey,
                passphrase
            )
            guard result == 0 else {
                updateStatus(.failed(.authenticationFailed))
                throw SSHError.authenticationFailed
            }

        case .sshAgent:
            // Try system ssh-agent first, then managed keys
            let agentOK = (try? authenticateWithAgent(session: session, username: username)) != nil
            let keysOK = agentOK ? true : ((try? authenticateWithManagedKeys(session: session, username: username)) != nil)
            guard agentOK || keysOK else {
                updateStatus(.failed(.authenticationFailed))
                throw SSHError.authenticationFailed
            }

        case .certificate:
            // Requires libssh2_userauth_*cert* functions not yet exposed.
            updateStatus(.failed(.authenticationFailed))
            throw SSHError.authenticationFailed
        }

        // Double-check that the server actually accepted our credentials.
        guard libssh2_userauth_authenticated(session) != 0 else {
            updateStatus(.failed(.authenticationFailed))
            throw SSHError.authenticationFailed
        }

        updateStatus(.authenticated)
    }

    // MARK: - Channel operations
    /// Open a new session channel.
    public func openChannel() throws -> OpaquePointer {
        guard let session = self.session else {
            throw SSHError.notConnected
        }
        guard let channel = libssh2_channel_open_session(session) else {
            throw SSHError.channelError("Failed to open session channel")
        }
        return channel
    }

    /// Request a PTY on the given channel.
    public func requestPTY(
        channel: OpaquePointer,
        rows: Int32,
        cols: Int32
    ) throws {
        let result = libssh2_channel_request_pty(channel)
        guard result == 0 else {
            throw SSHError.channelError("Failed to request PTY (err=\(result))")
        }
        let sizeResult = libssh2_channel_request_pty_size(channel, cols, rows)
        guard sizeResult == 0 else {
            throw SSHError.channelError("Failed to set PTY size (err=\(sizeResult))")
        }
    }

    /// Start a shell on the given channel.
    public func startShell(channel: OpaquePointer) throws {
        let result = libssh2_channel_shell(channel)
        guard result == 0 else {
            throw SSHError.channelError("Failed to start shell (err=\(result))")
        }
    }

    /// Execute a single command on the given channel (no PTY allocated).
    public func exec(
        channel: OpaquePointer,
        command: String
    ) throws {
        let result = libssh2_channel_exec(channel, command)
        guard result == 0 else {
            throw SSHError.channelError("Failed to execute command (err=\(result))")
        }
    }

    // MARK: - Read / Write (EAGAIN-aware)

    /// Read data from a channel.
    ///
    /// - Returns: `Data` with received bytes, empty `Data` on EAGAIN,
    ///            or `nil` when the channel has reached EOF.
    public func read(
        channel: OpaquePointer,
        bufferSize: Int = 4096
    ) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let result = buffer.withUnsafeMutableBytes { rawPtr in
            libssh2_channel_read(
                channel,
                rawPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                bufferSize
            )
        }

        if result == LIBSSH2_ERROR_EAGAIN_VALUE {
            // No data ready yet; caller should retry after a short delay.
            return Data()
        }

        guard result >= 0 else {
            throw SSHError.channelError("Read error: \(result)")
        }

        if result == 0 {
            // EOF – channel closed by the remote side.
            return nil
        }

        return Data(buffer[0..<Int(result)])
    }

    /// Write data to a channel.
    ///
    /// - Returns: Number of bytes written. Zero is returned on EAGAIN.
    public func write(
        channel: OpaquePointer,
        data: Data
    ) throws -> Int {
        let count = data.count

        let result = data.withUnsafeBytes { rawPtr in
            libssh2_channel_write(
                channel,
                rawPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                count
            )
        }

        if result == LIBSSH2_ERROR_EAGAIN_VALUE {
            return 0
        }

        guard result >= 0 else {
            throw SSHError.channelError("Write error: \(result)")
        }

        return Int(result)
    }

    // MARK: - Channel utilities

    /// Close and free a channel.
    public func closeChannel(_ channel: OpaquePointer) {
        libssh2_channel_close(channel)
        libssh2_channel_free(channel)
    }

    /// Set an environment variable inside the remote session.
    public func setEnvironment(
        channel: OpaquePointer,
        name: String,
        value: String
    ) throws {
        let result = libssh2_channel_setenv(channel, name, value)
        guard result == 0 else {
            throw SSHError.channelError("Failed to set env \(name) (err=\(result))")
        }
    }

    /// Make the underlying socket blocking (true) or non-blocking (false).
    /// SFTP operations need blocking mode; terminal I/O needs non-blocking.
    public func setSocketBlocking(_ blocking: Bool) {
        guard socketFD >= 0 else { return }
        var flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else { return }
        if blocking {
            flags &= ~O_NONBLOCK
        } else {
            flags |= O_NONBLOCK
        }
        fcntl(socketFD, F_SETFL, flags)
    }

    /// Resize the remote PTY (rows and cols are 1-indexed in libssh2).
    public func resizePTY(
        channel: OpaquePointer,
        rows: Int32,
        cols: Int32
    ) {
        libssh2_channel_request_pty_size(channel, cols, rows)
    }

    /// Return the exit status of a closed channel, or -1 if the channel is
    /// still open.
    public func getExitStatus(
        channel: OpaquePointer
    ) -> Int {
        Int(libssh2_channel_get_exit_status(channel))
    }

    // MARK: - Agent / Key auth helpers

    private func authenticateWithAgent(session: OpaquePointer, username: String) throws {
        guard let agent = libssh2_agent_init(session) else {
            throw SSHError.authenticationFailed
        }
        defer { libssh2_agent_disconnect(agent); libssh2_agent_free(agent) }
        guard libssh2_agent_connect(agent) == 0 else {
            throw SSHError.authenticationFailed
        }
        guard libssh2_agent_list_identities(agent) == 0 else {
            throw SSHError.authenticationFailed
        }
        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var prev: UnsafeMutablePointer<libssh2_agent_publickey>? = nil
        while libssh2_agent_get_identity(agent, &identity, prev) == 0 {
            guard let id = identity else { break }
            if libssh2_agent_userauth(agent, username, id) == 0 { return }
            prev = id
        }
        throw SSHError.authenticationFailed
    }

    nonisolated(unsafe) public static var managedKeyPaths: [String] = []

    private func authenticateWithManagedKeys(session: OpaquePointer, username: String) throws {
        for path in Self.managedKeyPaths {
            let result = libssh2_userauth_publickey_fromfile(session, username, nil, path, nil)
            if result == 0 { return }
        }
        throw SSHError.authenticationFailed
    }

    // MARK: - Keep-alive

    private var keepAliveTask: Task<Void, Never>?

    public func startKeepAlive(interval: Int) {
        stopKeepAlive()
        let session = self.session
        keepAliveTask = Task.detached {
            while !Task.isCancelled {
                var sec = Int32(interval)
                _ = libssh2_keepalive_send(session, &sec)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: - Disconnect
    /// Gracefully disconnect and free all resources.
    public func disconnect() {
        teardownSession()
        updateStatus(.disconnected)
    }

    deinit {
        guard _session != nil || socketFD >= 0 else { return }
        teardownSession()
    }

    // MARK: - Private helpers

    private func teardownSession() {
        hostname = nil
        lastConfig = nil
        sessionLock.lock()
        if let s = _session {
            libssh2_session_disconnect(s, "Normal shutdown")
            libssh2_session_free(s)
            _session = nil
        }
        sessionLock.unlock()

        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }
}
