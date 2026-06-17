import Foundation

/// Supplies a currently-valid access token. The polling coordinator depends on this rather
/// than on `TokenManager` directly, so it can be tested with a fake (NFR-007).
protocol AccessTokenProviding {
    func validAccessToken() async throws -> String
    /// Forces a refresh past the expiry check and returns the new token. The coordinator calls this
    /// to recover from a 401 on a token that looked valid by the clock but was rejected.
    func refreshedAccessToken() async throws -> String
    /// Performs the one-time interactive Keychain grant (read, then a no-op write of the same
    /// tokens), so the automatic poll and write-back paths can stay non-interactive. The
    /// coordinator calls this at launch and from the Grant Access action; it is the only path that
    /// may present a Keychain prompt.
    func establishAccess() async throws
}

extension AccessTokenProviding {
    /// Default for providers with no separate force-refresh: fall back to the normal valid token.
    func refreshedAccessToken() async throws -> String { try await validAccessToken() }
    /// Default for fakes: a plain valid-token read.
    func establishAccess() async throws { _ = try await validAccessToken() }
}

extension TokenManager: AccessTokenProviding {}
