import Foundation
import Security

/// Reads Claude Code's OAuth credential from the macOS Keychain. Read-only: it issues
/// only `SecItemCopyMatching` and never writes the item, so it cannot disturb Claude
/// Code's session (see PRD write-back policy).
struct KeychainReader: KeychainReading {
    let service: String
    let account: String

    init(service: String = KeychainItem.defaultService, account: String = KeychainItem.defaultAccount) {
        self.service = service
        self.account = account
    }

    func readCredential() throws -> KeychainCredential {
        try KeychainCredentialParser.parse(KeychainItem.readData(service: service, account: account))
    }
}
