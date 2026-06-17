import Foundation

/// Writes refreshed tokens back into the Keychain item so Claude Code stays in sync.
/// Implementations patch the stored JSON in place, updating only the token fields and
/// preserving everything else Claude Code stores (see `14-spike-findings.md`).
protocol KeychainWriting {
    /// Updates the token fields. Pass `allowInteraction: false` on the automatic write-back so a
    /// missing ACL grant fails fast with `interactionRequired` instead of prompting; pass `true`
    /// only from an explicit, user-initiated grant.
    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval,
                      allowInteraction: Bool) throws
}

extension KeychainWriting {
    /// Background-safe convenience: writes without ever presenting a prompt.
    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) throws {
        try updateTokens(accessToken: accessToken, refreshToken: refreshToken,
                         expiresAt: expiresAt, allowInteraction: false)
    }
}
