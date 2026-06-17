import Foundation
import Security

/// Shared raw access to Claude Code's credential item. One place for the query shape, the
/// status-to-error mapping, and the default service and account, so the reader and the writer
/// cannot drift apart if the item's identity ever changes.
enum KeychainItem {
    static let defaultService = "Claude Code-credentials"
    static var defaultAccount: String { NSUserName() }

    /// Reads the item's raw data, suppressing the interactive prompt unless
    /// `allowInteraction` is true. A background poll passes `false`, so a missing ACL grant
    /// returns `interactionRequired` rather than popping a modal dialog every cycle; only an
    /// explicit user grant passes `true`.
    static func readData(service: String, account: String, allowInteraction: Bool = false) throws -> Data {
        try withUserInteraction(allowInteraction) {
            try copyData(service: service, account: account)
        }
    }

    /// Copies the item's data via `SecItemCopyMatching`, mapping the common failure statuses to
    /// `KeychainError`. Does not manage user interaction; a caller that spans several operations
    /// (such as the writer's read-patch-update) sets it once via `withUserInteraction`.
    static func copyData(service: String, account: String) throws -> Data {
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
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionRequired
        case errSecAuthFailed, errSecUserCanceled:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Maps a non-success `SecItemUpdate`/`SecItemAdd` status to a `KeychainError`, sharing the
    /// interaction-vs-denied distinction with `copyData`.
    static func mapWriteStatus(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed: return .interactionRequired
        case errSecAuthFailed, errSecUserCanceled: return .accessDenied
        default: return .unexpectedStatus(status)
        }
    }

    /// Runs `body` with the process-wide Keychain user-interaction flag set, restoring it to the
    /// default (allowed) afterward. `SecKeychainSetUserInteractionAllowed` is deprecated but remains
    /// the control for the legacy login-keychain item this app reads; there is no replacement for it.
    static func withUserInteraction<T>(_ allowed: Bool, _ body: () throws -> T) rethrows -> T {
        SecKeychainSetUserInteractionAllowed(allowed)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return try body()
    }
}
