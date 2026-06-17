import Foundation

/// Reads the OAuth credential that Claude Code stores in the macOS Keychain.
/// Implementations never write to the Keychain item (see PRD write-back policy).
protocol KeychainReading {
    /// Returns the decoded credential, or throws a `KeychainError`.
    ///
    /// Pass `allowInteraction: false` on the automatic poll path so a missing ACL grant fails fast
    /// with `interactionRequired` instead of popping a modal prompt every cycle. Pass `true` only
    /// from an explicit, user-initiated grant.
    func readCredential(allowInteraction: Bool) throws -> KeychainCredential
}

extension KeychainReading {
    /// Background-safe convenience: reads without ever presenting a prompt.
    func readCredential() throws -> KeychainCredential {
        try readCredential(allowInteraction: false)
    }
}

/// Errors surfaced by a `KeychainReading` implementation.
enum KeychainError: Error, Equatable {
    /// The Keychain item does not exist (Claude Code has not signed in).
    case itemNotFound
    /// macOS denied access to the item (the user clicked Deny, or authentication failed).
    case accessDenied
    /// Access needs an interactive prompt, but interaction was suppressed on a background read.
    /// The app routes this to the keychain-denied state without firing a modal; the user then
    /// grants access explicitly, so the poll loop never causes a prompt storm.
    case interactionRequired
    /// The item exists but its data is not the expected credential JSON.
    case invalidData
    /// Any other `OSStatus` returned by the Keychain.
    case unexpectedStatus(OSStatus)
}
