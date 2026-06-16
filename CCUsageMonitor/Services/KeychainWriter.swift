import Foundation
import Security

/// Patches the token fields inside the stored Keychain JSON, preserving every other field.
/// Pure and unit-testable, separate from the Keychain I/O.
enum KeychainCredentialPatcher {
    static func patch(_ data: Data, accessToken: String, refreshToken: String,
                      expiresAt: TimeInterval) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainError.invalidData
        }
        // expiresAt is stored as an integer millisecond value in the original item.
        let expiresAtInt = Int(expiresAt.rounded())

        if var oauth = root["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = expiresAtInt
            root["claudeAiOauth"] = oauth
        } else {
            root["accessToken"] = accessToken
            root["refreshToken"] = refreshToken
            root["expiresAt"] = expiresAtInt
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

/// Updates the Claude Code credential item in place. Reads the raw JSON, patches only the
/// token fields, and writes it back with `SecItemUpdate`.
struct KeychainWriter: KeychainWriting {
    let service: String
    let account: String

    init(service: String = "Claude Code-credentials", account: String = NSUserName()) {
        self.service = service
        self.account = account
    }

    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) throws {
        let raw = try readRaw()
        let patched = try KeychainCredentialPatcher.patch(
            raw, accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: patched] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func readRaw() throws -> Data {
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
