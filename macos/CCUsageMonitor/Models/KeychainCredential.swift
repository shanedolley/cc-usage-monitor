import Foundation

/// The OAuth credential stored in the `Claude Code-credentials` generic-password item.
/// The Keychain value nests these fields under a `claudeAiOauth` key; the parser handles
/// that wrapper (see `KeychainCredentialParser`).
struct KeychainCredential: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Access-token expiry, milliseconds since the Unix epoch.
    let expiresAt: TimeInterval
    let scopes: [String]
    let subscriptionType: String?

    var expiresAtDate: Date {
        Date(timeIntervalSince1970: expiresAt / 1000)
    }

    /// True when `now` plus the safety buffer reaches or passes expiry. The clock is
    /// injected so the token manager and tests stay deterministic (see NFR-007).
    func isExpired(now: Date, buffer: TimeInterval = 120) -> Bool {
        now.addingTimeInterval(buffer) >= expiresAtDate
    }
}
