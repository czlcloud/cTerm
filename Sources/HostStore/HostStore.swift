import Foundation
import Combine

// MARK: - HostStore

/// The central model object that manages all SSH hosts.
///
/// `HostStore` merges hosts from two sources:
///  1. **SSH config** – read from `~/.ssh/config` (read-only, reloaded each
///     time `loadAll()` is called).
///  2. **Local store** – a JSON file at
///     `~/Library/Application Support/TerminalApp/hosts.json`
///     (user-created hosts, full CRUD).
///
/// Passwords and other secrets are stored separately via the system Keychain.
@MainActor
public final class HostStore: ObservableObject {

    // MARK: Published State

    /// Every known host (SSH config + local combined).
    @Published public var hosts: [HostDefinition] = []

    /// The unique, sorted list of group names extracted from `hosts`.
    @Published public var groups: [String] = []

    // MARK: Dependencies

    private let parser = SSHConfigParser()
    private let keychain = KeychainStore.shared

    // MARK: Init

    public init() {}

    // MARK: - Loading

    /// Loads (or reloads) all hosts from the SSH config file **and** the local
    /// JSON store.  SSH config hosts always appear first, followed by local
    /// hosts.  The `groups` array is recomputed automatically.
  public func loadAll() {
        var result: [HostDefinition] = []

        // 1. SSH config hosts
        let sshHosts = parser.parse()
        result.append(contentsOf: sshHosts)

        // 2. Local persisted hosts
        if let localHosts = decodeLocalHosts() {
            result.append(contentsOf: localHosts)
        }

        hosts = result
        recomputeGroups()
    }

    // MARK: - CRUD (Local Hosts)

    /// Adds a new host to the local store.
    /// The host's `source` is forced to `.local` and it is persisted
    /// immediately.
  public func addLocalHost(_ host: HostDefinition) {
        var h = host
        h.source = .local
        hosts.append(h)
        persistLocalHosts()
        recomputeGroups()
    }

    /// Replaces an existing host **in memory**.
    ///
    /// If the host has `source == .local` the change is persisted to the JSON
    /// store immediately.  SSH-config hosts are updated in memory only (the
    /// SSH config file itself is never modified).
  public func updateHost(_ host: HostDefinition) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host

        if host.source == .local {
            persistLocalHosts()
        }
        recomputeGroups()
    }

    /// Removes a host from the array.
    ///
    /// If it was a local host the JSON store is updated.  Any keychain
    /// credential stored under the host's identifier is also cleaned up.
  public func deleteHost(_ host: HostDefinition) {
        hosts.removeAll { $0.id == host.id }

        if host.source == .local {
            persistLocalHosts()
        }

        // Clean up potential keychain credential.
        keychain.delete(key: credentialKey(for: host.id))
        recomputeGroups()
    }

    // MARK: - Credential Helpers

    /// Saves a password for the given host into the Keychain.
  public func saveCredential(for hostID: UUID, password: String) throws {
        try keychain.saveString(key: credentialKey(for: hostID), value: password)
    }

    /// Reads a password for the given host from the Keychain.
  public func getCredential(for hostID: UUID) throws -> String {
        try keychain.read(key: credentialKey(for: hostID))
    }

    // MARK: - Filtering

    /// Returns all hosts belonging to `group`.
  public func hosts(inGroup group: String) -> [HostDefinition] {
        hosts.filter { $0.group == group }
    }

    /// Returns all hosts tagged with `tag`.
  public func hosts(withTag tag: String) -> [HostDefinition] {
        hosts.filter { $0.tags.contains(tag) }
    }

    // MARK: - Private Helpers

    private func credentialKey(for hostID: UUID) -> String {
        "password_\(hostID.uuidString)"
    }

    // MARK: Persistence

    /// URL of the local JSON host store.
    private var localStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TerminalApp", isDirectory: true)
        // Ensure the directory exists (idempotent).
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("hosts.json")
    }

    /// Decodes and returns local hosts from the JSON file, or `nil` if the
    /// file does not exist or is corrupt.
    private func decodeLocalHosts() -> [HostDefinition]? {
        guard let data = try? Data(contentsOf: localStoreURL) else { return nil }
        return try? JSONDecoder().decode([HostDefinition].self, from: data)
    }

    /// Encodes all `.local` hosts to the JSON file.
    ///
    /// Only hosts with `source == .local` are persisted – SSH config hosts
    /// are always re-read from the config file on the next `loadAll()`.
    private func persistLocalHosts() {
        let local = hosts.filter { $0.source == .local }
        guard let data = try? JSONEncoder().encode(local) else { return }
        try? data.write(to: localStoreURL, options: .atomic)
    }

    /// Rebuilds the `groups` array from the current `hosts` list.
    private func recomputeGroups() {
        let allGroups = hosts.compactMap(\.group)
        groups = Array(Set(allGroups)).sorted()
    }
}
