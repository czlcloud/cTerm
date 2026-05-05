import Foundation
import SSHClient

/// In-app SSH key manager — stores key paths, tries them all on connect
@MainActor
public final class KeyManager: ObservableObject {
    public static let shared = KeyManager()

    @Published public var keyPaths: [String] = []

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalApp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("managed_keys.json")
        if let data = try? Data(contentsOf: url),
           let keys = try? JSONDecoder().decode([String].self, from: data) {
            keyPaths = keys
            SSHConnection.managedKeyPaths = keys
        }
    }

    public func addKey(_ path: String) {
        guard !keyPaths.contains(path) else { return }
        keyPaths.append(path)
        save()
    }

    public func removeKey(_ path: String) {
        keyPaths.removeAll { $0 == path }
        save()
    }

    public var hasKeys: Bool { !keyPaths.isEmpty }

    private func save() {
        if let data = try? JSONEncoder().encode(keyPaths) {
            try? data.write(to: url)
        }
        // Sync to SSH client for agent auth fallback
        SSHConnection.managedKeyPaths = keyPaths
    }
}
