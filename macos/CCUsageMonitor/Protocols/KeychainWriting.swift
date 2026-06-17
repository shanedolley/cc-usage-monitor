import Foundation

/// Writes refreshed tokens back into the Keychain item so Claude Code stays in sync.
/// Implementations patch the stored JSON in place, updating only the token fields and
/// preserving everything else Claude Code stores (see `14-spike-findings.md`).
protocol KeychainWriting {
    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) throws
}
