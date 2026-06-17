import Foundation

/// Exchanges a refresh token for a fresh credential via Anthropic's OAuth token endpoint.
protocol TokenRefreshing {
    /// Returns a new credential built from the refresh response. `now` is injected so the
    /// new expiry is computed deterministically (see NFR-007).
    func refresh(using credential: KeychainCredential, now: Date) async throws -> KeychainCredential
}
