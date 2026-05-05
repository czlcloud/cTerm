import Foundation
import HostStoreModule

@MainActor
public enum CredentialResolver {
    public static func password(for ref: String, preference: CredentialStorePreference = .both) -> String {
        switch preference {
        case .credentialStore:
            return (try? CredentialStore.shared.read(key: ref)) ?? ""
        case .keychain:
            return (try? KeychainStore.shared.read(key: ref)) ?? ""
        case .both:
            return (try? CredentialStore.shared.read(key: ref))
                ?? (try? KeychainStore.shared.read(key: ref)) ?? ""
        }
    }

    public static func save(password: String, for ref: String, preference: CredentialStorePreference) {
        switch preference {
        case .credentialStore:
            try? CredentialStore.shared.saveString(key: ref, value: password)
        case .keychain:
            try? KeychainStore.shared.saveString(key: ref, value: password)
        case .both:
            try? CredentialStore.shared.saveString(key: ref, value: password)
            try? KeychainStore.shared.saveString(key: ref, value: password)
        }
    }
}
