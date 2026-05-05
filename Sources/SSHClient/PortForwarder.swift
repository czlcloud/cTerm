import Foundation
import CLibssh2
import Darwin

public final class PortForwarder: @unchecked Sendable {

    private let connection: SSHConnection
    private let lock = NSLock()
    private var forwards: [UUID: PortForward] = [:]
    private var acceptTasks: [UUID: Task<Void, Never>] = [:]
    private var listenerSockets: [UUID: Int32] = [:]
    private var isDisconnected = false

    public init(connection: SSHConnection) {
        self.connection = connection
    }
    deinit { disconnect() }

    // MARK: - Local Forward (-L: local → remote)

    /// Listen on local `listenPort` and forward connections through SSH to `targetHost:targetPort`.
    public func startLocalForward(listenPort: inout Int, targetHost: String, targetPort: Int) throws -> PortForward {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(listenPort).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let listenSock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenSock >= 0 else { throw SSHError.portForwardError("Failed to create local listen socket") }

        var reuse: Int32 = 1
        setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var bound = false
        for _ in 0..<5 {
            let sz = MemoryLayout<sockaddr_in>.size
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenSock, $0, socklen_t(sz))
                }
            }
            if result == 0 { bound = true; break }
            if listenPort == 0 { break }
            listenPort += 1
            addr.sin_port = UInt16(listenPort).bigEndian
        }
        guard bound else {
            Darwin.close(listenSock)
            throw SSHError.portForwardError("Failed to bind local port")
        }

        // Get actual bound port
        var actualAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenSock, $0, &addrLen)
            }
        }
        listenPort = Int(UInt16(bigEndian: actualAddr.sin_port))

        guard Darwin.listen(listenSock, 16) == 0 else {
            Darwin.close(listenSock)
            throw SSHError.portForwardError("Failed to listen on local port")
        }

        // Set non-blocking for accept
        var flags = fcntl(listenSock, F_GETFL, 0)
        if flags >= 0 { fcntl(listenSock, F_SETFL, flags | O_NONBLOCK) }

        let fwID = UUID()
        let forward = PortForward(id: fwID, type: .local, localPort: listenPort,
                                   remoteHost: targetHost, remotePort: targetPort, status: .active)

        lock.lock()
        forwards[fwID] = forward
        listenerSockets[fwID] = listenSock
        lock.unlock()

        startLocalAcceptLoop(fwID: fwID, listenSock: listenSock, targetHost: targetHost, targetPort: targetPort)
        return forward
    }

    // MARK: - Remote Forward (-R: remote → local)

    /// Ask the remote SSH server to listen on `listenPort` and forward back to `targetHost:targetPort`.
    public func startRemoteForward(listenPort: inout Int, targetHost: String, targetPort: Int) throws -> PortForward {
        guard let session = connection.session else { throw SSHError.notConnected }

        var boundPort = Int32(listenPort)
        guard libssh2_channel_forward_listen_ex(session, "0.0.0.0", boundPort, &boundPort, 16) != nil else {
            throw SSHError.portForwardError("Remote listen failed")
        }
        listenPort = Int(boundPort)

        let fwID = UUID()
        let forward = PortForward(id: fwID, type: .remote, localPort: listenPort,
                                   remoteHost: targetHost, remotePort: targetPort, status: .active)
        lock.lock()
        forwards[fwID] = forward
        lock.unlock()

        startRemoteAcceptLoop(fwID: fwID, targetHost: targetHost, targetPort: targetPort)
        return forward
    }

    // MARK: - Dynamic Forward (-D: SOCKS proxy)

    /// Listen on local `listenPort` as a SOCKS5 proxy through the SSH connection.
    public func startDynamicForward(listenPort: inout Int) throws -> PortForward {
        var port = listenPort
        let fw = try startLocalForward(listenPort: &port, targetHost: "", targetPort: 0)
        // Override type to dynamic
        let dynFw = PortForward(id: fw.id, type: .dynamic, localPort: fw.localPort,
                                 remoteHost: "SOCKS5", remotePort: 0, status: .active)
        lock.lock()
        forwards[fw.id] = dynFw
        lock.unlock()
        return dynFw
    }

    // MARK: - Stop

    public func stopForward(_ id: UUID) {
        lock.lock()
        forwards[id] = nil
        let task = acceptTasks.removeValue(forKey: id)
        let sock = listenerSockets.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
        if let s = sock, s >= 0 { Darwin.close(s) }
    }

    public func disconnect() {
        lock.lock()
        let allTasks = acceptTasks
        let allSockets = listenerSockets
        acceptTasks.removeAll()
        listenerSockets.removeAll()
        forwards.removeAll()
        isDisconnected = true
        lock.unlock()
        for t in allTasks.values { t.cancel() }
        for s in allSockets.values where s >= 0 { Darwin.close(s) }
    }

    // MARK: - Local accept loop

    private func startLocalAcceptLoop(fwID: UUID, listenSock: Int32, targetHost: String, targetPort: Int) {
        let task = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let stillActive = self.lock.withLock { self.forwards[fwID] != nil }
                guard stillActive else { break }

                let clientSock = Darwin.accept(listenSock, nil, nil)
                if clientSock < 0 {
                    if errno == EAGAIN || errno == EINTR { try? await Task.sleep(nanoseconds: 50_000_000); continue }
                    break
                }

                // Handle in background
                let sock = clientSock; let host = targetHost; let port = targetPort
                DispatchQueue.global().async { [weak self] in
                    self?.relayLocalToRemote(clientSock: sock, targetHost: host, targetPort: port)
                }
            }
        }
        lock.lock()
        acceptTasks[fwID] = task
        lock.unlock()
    }

    // MARK: - Remote accept loop

    private func startRemoteAcceptLoop(fwID: UUID, targetHost: String, targetPort: Int) {
        let task = Task { [weak self] in
            guard let self = self, let session = self.connection.session else { return }
            while !Task.isCancelled {
                let stillActive = self.lock.withLock { self.forwards[fwID] != nil }
                guard stillActive else { break }
                guard let channel = libssh2_channel_forward_accept(session) else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                let ch = channel; let host = targetHost; let port = targetPort
                DispatchQueue.global().async { [weak self] in
                    self?.relayRemoteToLocal(channel: ch, targetHost: host, targetPort: port)
                }
            }
        }
        lock.lock()
        acceptTasks[fwID] = task
        lock.unlock()
    }

    // MARK: - Data relay

    private func relayLocalToRemote(clientSock: Int32, targetHost: String, targetPort: Int) {
        defer { Darwin.close(clientSock) }

        guard let session = connection.session else { return }
        let directChannel = targetHost.isEmpty ? nil :
            libssh2_channel_direct_tcpip_ex(session, targetHost, Int32(targetPort), "127.0.0.1", 0)
        guard let channel = directChannel else { return }
        defer { libssh2_channel_close(channel); libssh2_channel_free(channel) }

        bidirectionalRelay(clientSock: clientSock, channel: channel)
    }

    private func relayRemoteToLocal(channel: OpaquePointer, targetHost: String, targetPort: Int) {
        defer { libssh2_channel_close(channel); libssh2_channel_free(channel) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(targetPort).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        if targetHost != "localhost" && targetHost != "127.0.0.1" {
            addr.sin_addr.s_addr = inet_addr(targetHost)
        }

        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return }

        bidirectionalRelay(clientSock: sock, channel: channel)
    }

    private func bidirectionalRelay(clientSock: Int32, channel: OpaquePointer) {
        let eagain = Int32(LIBSSH2_ERROR_EAGAIN_VALUE)
        var done = false

        // Set non-blocking on client socket
        var flags = fcntl(clientSock, F_GETFL, 0)
        if flags >= 0 { fcntl(clientSock, F_SETFL, flags | O_NONBLOCK) }

        var buf = [UInt8](repeating: 0, count: 16384)
        var idleCount = 0

        while !done && idleCount < 600 { // ~30 second idle timeout
            var activity = false

            // Client → Channel
            let n = Darwin.read(clientSock, &buf, buf.count)
            if n > 0 {
                activity = true
                let data = Data(buf[0..<n])
                var offset = 0
                while offset < data.count {
                    let written = data.dropFirst(offset).withUnsafeBytes { raw in
                        libssh2_channel_write(channel, raw.baseAddress!.assumingMemoryBound(to: Int8.self), data.count - offset)
                    }
                    if written == eagain { usleep(10_000); continue }
                    if written <= 0 { done = true; break }
                    offset += written
                }
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                done = true
            }

            // Channel → Client
            let r = libssh2_channel_read(channel, &buf, buf.count)
            if r > 0 {
                activity = true
                var offset = 0
                while offset < r {
                    let sent = buf.withUnsafeBufferPointer { ptr in
                        Darwin.write(clientSock, ptr.baseAddress!.advanced(by: offset), r - offset)
                    }
                    if sent < 0 && errno != EAGAIN && errno != EINTR { done = true; break }
                    if sent <= 0 { break }
                    offset += sent
                }
            } else if r < 0 && r != eagain {
                done = true
            }

            idleCount = activity ? 0 : idleCount + 1
            if !activity { usleep(50_000) } // 50ms idle sleep
        }
    }
}
