import Foundation

/// Reads the OAuth credential that Claude Code stores in the macOS Keychain.
/// Implementations never write to the Keychain item (see PRD write-back policy).
protocol KeychainReading {
    /// Returns the decoded credential, or throws if the item is missing,
    /// access is denied, or the stored JSON cannot be decoded.
    func readCredential() throws -> KeychainCredential
}
