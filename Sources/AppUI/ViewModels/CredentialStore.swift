import Foundation
import CryptoKit

enum CredentialError: Error { case notFound }

/// Simple encrypted credential store — avoids Keychain prompts for unsigned apps
@MainActor
public final class CredentialStore {
    public static let shared = CredentialStore()

    private let key: SymmetricKey
    private let url: URL

    private struct CredentialEntry: Codable {
        var key: String
        var value: String
    }
    @Published private var entries: [String: String] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalApp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("credentials.enc")

        // Derive encryption key — use fixed seed for stability across launches
        let seed = "terminalapp-credential-store-v2"
        key = SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))

        load()
    }

    public func saveString(key k: String, value: String) throws {
        entries[k] = value
        persist()
    }

    public func read(key k: String) throws -> String {
        guard let v = entries[k] else { throw CredentialError.notFound }
        return v
    }

    public func delete(key k: String) {
        entries.removeValue(forKey: k)
        persist()
    }

    private func logToFile(_ msg: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/credstore.log")
        let line = msg + "\n"
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else { try? data.write(to: url) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            logToFile("Load: no file at \(url.path)")
            return
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealed, using: key)
            let decoded = try JSONDecoder().decode([CredentialEntry].self, from: decrypted)
            entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.key, $0.value) })
            logToFile("Load: \(entries.count) entries, keys=\(entries.keys.joined(separator: ", "))")
        } catch {
            logToFile("Load FAIL: \(error)")
            entries = [:]
        }
    }

    private func persist() {
        do {
            let encoded = try JSONEncoder().encode(entries.map { CredentialEntry(key: $0.key, value: $0.value) })
            let sealed = try AES.GCM.seal(encoded, using: key)
            try sealed.combined?.write(to: url)
            logToFile("Save: \(entries.count) entries OK")
        } catch {
            logToFile("Save FAIL: \(error)")
        }
    }

    }
