import Foundation

/// A `TokenRefreshing` that never refreshes. The monitor reads the access token Claude Code keeps
/// in the Keychain, but it must not refresh that token. Anthropic rotates refresh tokens, so a
/// second refresher would rotate the shared OAuth session out from under Claude Code and sign it
/// out. When the stored token has expired, refreshing throws `tokenStale`, and the poll loop holds
/// the last good data until Claude Code refreshes the token on its next use.
struct NoRefreshTokenRefresher: TokenRefreshing {
    func refresh(using credential: KeychainCredential, now: Date) async throws -> KeychainCredential {
        throw APIError.tokenStale
    }
}
