import Foundation
import Security

/// Shared raw access to Claude Code's credential item. One place for the query shape, the
/// status-to-error mapping, and the default service and account, so the reader and the writer
/// cannot drift apart if the item's identity ever changes.
enum KeychainItem {
    static let defaultService = "Claude Code-credentials"
    static var defaultAccount: String { NSUserName() }

    /// Reads the item's raw data via `SecItemCopyMatching`, mapping the common failure
    /// statuses to `KeychainError`.
    static func readData(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.invalidData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
