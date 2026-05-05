import Foundation

// MARK: - Error type
public enum SSHError: Error, LocalizedError, Equatable {
    case connectionTimeout
    case hostKeyMismatch
    case authenticationFailed
    case channelError(String)
    case disconnected
    case notConnected
    case sftpError(String)
    case portForwardError(String)

    public var errorDescription: String? {
        switch self {
        case .connectionTimeout: return "Connection timed out"
        case .hostKeyMismatch: return "Host key mismatch"
        case .authenticationFailed: return "Authentication failed"
        case .channelError(let msg): return "Channel error: \(msg)"
        case .disconnected: return "Disconnected"
        case .notConnected: return "Not connected"
        case .sftpError(let msg): return "SFTP error: \(msg)"
        case .portForwardError(let msg): return "Port forward error: \(msg)"
        }
    }
}

// MARK: - Connection status
public enum SSHConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case authenticating
    case authenticated
    case failed(SSHError)
}

// MARK: - Authentication method
public enum AuthMethod: Equatable, Sendable {
    case password(String)
    case pkeyFile(privateKey: String, publicKey: String? = nil, passphrase: String? = nil)
    case sshAgent
    case certificate(String)
}

// MARK: - Configuration
public struct SSHConfig: Equatable, Sendable {
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var keepAliveInterval: Int
    public var connectionTimeout: TimeInterval

    public init(
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod,
        keepAliveInterval: Int = 30,
        connectionTimeout: TimeInterval = 15
    ) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keepAliveInterval = keepAliveInterval
        self.connectionTimeout = connectionTimeout
    }
}

// MARK: - Port forwarding types
public enum PortForwardType: Equatable {
    case local
    case remote
    case dynamic
}

public enum PortForwardStatus: String, Equatable, Codable {
    case active
    case inactive
    case error
}

public struct PortForward: Identifiable, Equatable {
    public let id: UUID
    public let type: PortForwardType
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int
    public let status: PortForwardStatus

    public var label: String {
        let prefix = type == .local ? "L" : type == .remote ? "R" : "D"
        return "\(prefix) \(localPort)→\(remoteHost):\(remotePort)"
    }

    public init(
        id: UUID = UUID(),
        type: PortForwardType,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        status: PortForwardStatus
    ) {
        self.id = id
        self.type = type
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.status = status
    }
}

// MARK: - Internal libssh2 error constant
/// LIBSSH2_ERROR_EAGAIN value. libssh2 returns this from non-blocking calls when the
/// operation would block on the underlying socket.
internal let LIBSSH2_ERROR_EAGAIN_VALUE: Int = -37
