import Foundation
import Security

// MARK: - KeychainError

public enum KeychainError: Error, LocalizedError, CustomNSError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)."
        case .readFailed(let status):
            return "Keychain read failed with status \(status)."
        case .deleteFailed(let status):
            return "Keychain delete failed with status \(status)."
        case .invalidData:
            return "Keychain returned invalid or unexpected data."
        }
    }

    public var errorCode: Int {
        switch self {
        case .saveFailed: return -1
        case .readFailed: return -2
        case .deleteFailed: return -3
        case .invalidData: return -4
        }
    }

    public static var errorDomain: String { "KeychainStore" }
}

// MARK: - KeychainStore

public final class KeychainStore {

    // MARK: Singleton

    nonisolated(unsafe) public static let shared = KeychainStore()

    // MARK: Properties

    private let serviceName: String = {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return "com.terminalapp.keychain"
        }
        return bundleID + ".keychain"
    }()

    private let accessGroup: String? = nil

    // MARK: Init

    private init() {}

    // MARK: Public API

    /// Saves raw `Data` for the given key.
  public func save(key: String, data: Data) throws {
        // Delete any existing item first to avoid duplicate entries.
        delete(key: key)

        var query: [String: Any] = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Saves a `String` value for the given key (UTF-8 encoded).
  public func saveString(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try save(key: key, data: data)
    }

    /// Reads a UTF-8 string for the given key.  Throws if the key does not exist
    /// or the stored data is not valid UTF-8.
  public func read(key: String) throws -> String {
        var query: [String: Any] = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data, !data.isEmpty else {
            throw KeychainError.invalidData
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    /// Deletes the keychain item for the given key.  Does **not** throw if the
    /// item does not exist.
  public func delete(key: String) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Helpers

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
