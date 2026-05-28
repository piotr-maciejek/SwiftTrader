import Foundation
import Security

/// Per-account secret storage (the password SHA-1 hash). Abstracted so tests can
/// substitute an in-memory implementation instead of touching the real Keychain.
protocol SecretStore: Sendable {
    func setSecret(_ secret: String, for key: String) throws
    func secret(for key: String) -> String?
    func removeSecret(for key: String) throws
}

enum KeychainError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    var description: String {
        switch self {
        case .unexpectedStatus(let s): "keychain operation failed (OSStatus \(s))"
        }
    }
}

/// macOS Keychain-backed `SecretStore` using a generic-password item per key.
struct KeychainStore: SecretStore {
    let service: String

    init(service: String = "com.swifttrader.dukascopy.accounts") {
        self.service = service
    }

    func setSecret(_ secret: String, for key: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)  // overwrite any existing value
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func secret(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeSecret(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
