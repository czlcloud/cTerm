import Foundation

/// Resolves an actual API key string from a provider's `apiKeyRef`.
///
/// The default resolution order is:
/// 1. An in-memory override set via ``setKey(_:for:)``.
/// 2. An environment variable whose name matches `reference`.
///
/// A more sophisticated implementation (e.g. Keychain-backed) can replace
/// the shared instance or subclass this type.
public final class APIKeyStore: @unchecked Sendable {
    public static let shared = APIKeyStore()

    private let lock = NSLock()
    private var overrides: [String: String] = [:]

    public init() {}

    /// Register a direct key value for the given reference identifier.
    /// - Parameters:
    ///   - key: The actual API key string.
    ///   - reference: The `apiKeyRef` value this key should be returned for.
    public func setKey(_ key: String, for reference: String) {
        lock.withLock { overrides[reference] = key }
    }

    /// Resolve the API key for a `apiKeyRef` string.
    /// - Parameter reference: The opaque reference stored in ``AIProviderConfig/apiKeyRef``.
    /// - Returns: The resolved key, or `nil` if no source could provide one.
    public func resolve(_ reference: String) -> String? {
        lock.withLock { overrides[reference] }
            ?? ProcessInfo.processInfo.environment[reference]
    }
}
