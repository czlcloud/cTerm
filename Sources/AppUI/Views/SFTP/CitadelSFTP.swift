import Foundation
import Citadel
import NIOCore

// MARK: - Citadel-based SFTP Client

final class CitadelSFTP: @unchecked Sendable {
    private var client: SSHClient?
    private var sftp: SFTPClient?

    var isConnected: Bool { sftp != nil }

    /// Verify the connection is truly alive by stat-ing the root path.
    func checkHealth() async -> Bool {
        guard let sftp else {
            SFTPLogger.log("client", "checkHealth → false (sftp=nil)")
            return false
        }
        do {
            _ = try await sftp.listDirectory(atPath: "/")
            SFTPLogger.log("client", "checkHealth → true")
            return true
        } catch {
            SFTPLogger.log("client", "checkHealth → false (error: \(error.localizedDescription))")
            return false
        }
    }

    deinit {}

    func connect(host: String, port: Int, username: String, password: String) async throws {
        SFTPLogger.log("client", "connect \(host):\(port) user=\(username)...")
        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            hostKeyValidator: .acceptAnything()
        )
        client = try await SSHClient.connect(to: settings)
        sftp = try await client!.openSFTP()
        SFTPLogger.log("client", "connect \(host):\(port) ✓")
    }

    func listDirectory(_ path: String) async throws -> [CitadelFileEntry] {
        guard let sftp = sftp else { throw CitadelSFTPError.notConnected }
        let names = try await sftp.listDirectory(atPath: path)
        var result: [CitadelFileEntry] = []
        for name in names {
            for comp in name.components {
                let n = comp.filename
                guard n != "." && n != ".." else { continue }
                let isDir = (comp.attributes.permissions ?? 0) & 0o040000 != 0
                result.append(CitadelFileEntry(
                    name: n,
                    path: path.hasSuffix("/") ? path + n : path + "/" + n,
                    isDirectory: isDir,
                    size: Int64(comp.attributes.size ?? 0)
                ))
            }
        }
        return result
    }

    func download(_ remotePath: String, to localURL: URL) async throws {
        guard let sftp = sftp else { throw CitadelSFTPError.notConnected }
        let data = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }
        try Data(data.readableBytesView).write(to: localURL)
    }

    func upload(localURL: URL, to remotePath: String) async throws {
        guard let sftp = sftp else { throw CitadelSFTPError.notConnected }
        let fileData = try Data(contentsOf: localURL)
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            try await file.write(ByteBuffer(data: fileData))
        }
    }

    func remove(_ remotePath: String) async throws {
        guard let sftp = sftp else { throw CitadelSFTPError.notConnected }
        try await sftp.remove(at: remotePath)
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        guard let sftp = sftp else { throw CitadelSFTPError.notConnected }
        try await sftp.rename(at: oldPath, to: newPath)
    }

    func disconnect() async {
        SFTPLogger.log("client", "disconnect")
        try? await sftp?.close()
        sftp = nil
        try? await client?.close()
        client = nil
    }
}

// MARK: - File Entry

struct CitadelFileEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
}

enum CitadelSFTPError: LocalizedError {
    case notConnected
    var errorDescription: String? {
        switch self {
        case .notConnected: return "SFTP not connected"
        }
    }
}
