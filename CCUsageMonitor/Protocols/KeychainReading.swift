import Foundation

/// Reads the OAuth credential that Claude Code stores in the macOS Keychain.
/// Implementations never write to the Keychain item (see PRD write-back policy).
protocol KeychainReading {
    /// Returns the decoded credential, or throws a `KeychainError` if the item is
    /// missing, access is denied, or the stored JSON cannot be decoded.
    func readCredential() throws -> KeychainCredential
}

/// Errors surfaced by a `KeychainReading` implementation.
enum KeychainError: Error, Equatable {
    /// The Keychain item does not exist (Claude Code has not signed in).
    case itemNotFound
    /// macOS denied access to the item (the user declined the prompt or the ACL blocks it).
    case accessDenied
    /// The item exists but its data is not the expected credential JSON.
    case invalidData
    /// Any other `OSStatus` returned by the Keychain.
    case unexpectedStatus(OSStatus)
}
