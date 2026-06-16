import Foundation
import Security

/// Updates the Claude Code credential item in place. Reads the raw JSON, patches only the
/// token fields, and writes it back with `SecItemUpdate`.
struct KeychainWriter: KeychainWriting {
    let service: String
    let account: String

    init(service: String = KeychainItem.defaultService, account: String = KeychainItem.defaultAccount) {
        self.service = service
        self.account = account
    }

    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) throws {
        let raw = try KeychainItem.readData(service: service, account: account)
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
}
