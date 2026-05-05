import Foundation

// MARK: - HostSource

public enum HostSource: String, Codable, CaseIterable {
    case sshConfig
    case local
    case iCloud
}

// MARK: - AuthMode

public enum AuthMode: Codable, Hashable {
    case password(keychainRef: String)
    case keyFile(path: String, passphraseKeychainRef: String?)
    case sshAgent
    case certificate(data: Data)

    public var isPasswordAuth: Bool {
        if case .password = self { return true }
        return false
    }

    public var keychainRefIfPassword: String? {
        if case .password(let ref) = self { return ref }
        return nil
    }

    // MARK: Codable

    private enum CodingKeyType: String, Codable {
        case password
        case keyFile
        case sshAgent
        case certificate
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case keychainRef
        case path
        case passphraseKeychainRef
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password(let ref):
            try container.encode(CodingKeyType.password, forKey: .type)
            try container.encode(ref, forKey: .keychainRef)
        case .keyFile(let path, let passphraseRef):
            try container.encode(CodingKeyType.keyFile, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(passphraseRef, forKey: .passphraseKeychainRef)
        case .sshAgent:
            try container.encode(CodingKeyType.sshAgent, forKey: .type)
        case .certificate(let data):
            try container.encode(CodingKeyType.certificate, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }

public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CodingKeyType.self, forKey: .type)

        switch type {
        case .password:
            let ref = try container.decode(String.self, forKey: .keychainRef)
            self = .password(keychainRef: ref)
        case .keyFile:
            let path = try container.decode(String.self, forKey: .path)
            let passphraseRef = try container.decodeIfPresent(String.self, forKey: .passphraseKeychainRef)
            self = .keyFile(path: path, passphraseKeychainRef: passphraseRef)
        case .sshAgent:
            self = .sshAgent
        case .certificate:
            let data = try container.decode(Data.self, forKey: .data)
            self = .certificate(data: data)
        }
    }
}

// MARK: - HostDefinition

public struct HostDefinition: Codable, Identifiable, Hashable {
    public let id: UUID
  public var source: HostSource
  public var label: String
  public var hostname: String
  public var port: UInt16
  public var username: String
  public var authMode: AuthMode
  public var keepAliveInterval: Int
  public var group: String?
  public var tags: [String]
  public var colorMark: String?
  public var notes: String?
  public var jumpHost: UUID?
	  public var lastUpdateTime: Date?
	  public var workspaceId: UUID?

    // MARK: Init

public init(
        id: UUID = UUID(),
        source: HostSource = .local,
        label: String,
        hostname: String,
        port: UInt16 = 22,
        username: String = NSUserName(),
        authMode: AuthMode = .sshAgent,
        keepAliveInterval: Int = 0,
        group: String? = nil,
        tags: [String] = [],
        colorMark: String? = nil,
        notes: String? = nil,
        jumpHost: UUID? = nil,
        lastUpdateTime: Date? = nil,
        workspaceId: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMode = authMode
        self.keepAliveInterval = keepAliveInterval
        self.group = group
        self.tags = tags
        self.colorMark = colorMark
        self.notes = notes
        self.jumpHost = jumpHost
        self.lastUpdateTime = lastUpdateTime
        self.workspaceId = workspaceId
    }


    // MARK: Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: HostDefinition, rhs: HostDefinition) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: Codable

public enum CodingKeys: String, CodingKey {
        case id, source, label, hostname, port, username, authMode
        case keepAliveInterval, group, tags, colorMark, notes, jumpHost
    }
}
