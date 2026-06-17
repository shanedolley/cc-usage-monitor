import Foundation

/// Supplies a currently-valid access token. The polling coordinator depends on this rather
/// than on `TokenManager` directly, so it can be tested with a fake (NFR-007).
protocol AccessTokenProviding {
    func validAccessToken() async throws -> String
    /// Forces a refresh past the expiry check and returns the new token. The coordinator calls this
    /// to recover from a 401 on a token that looked valid by the clock but was rejected.
    func refreshedAccessToken() async throws -> String
}

extension AccessTokenProviding {
    /// Default for providers with no separate force-refresh: fall back to the normal valid token.
    func refreshedAccessToken() async throws -> String { try await validAccessToken() }
}

extension TokenManager: AccessTokenProviding {}
