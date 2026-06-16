import Foundation
import Security

/// Reads Claude Code's OAuth credential from the macOS Keychain. Read-only: it issues
/// only `SecItemCopyMatching` and never writes the item, so it cannot disturb Claude
/// Code's session (see PRD write-back policy).
struct KeychainReader: KeychainReading {
    let service: String
    let account: String

    init(service: String = "Claude Code-credentials", account: String = NSUserName()) {
        self.service = service
        self.account = account
    }

    func readCredential() throws -> KeychainCredential {
        try KeychainCredentialParser.parse(readData())
    }

    private func readData() throws -> Data {
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
