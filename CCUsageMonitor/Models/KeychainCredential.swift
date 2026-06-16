import Foundation

/// The JSON value stored in the `Claude Code-credentials` generic-password item.
/// Concrete decoding (including the `claudeAiOauth` wrapper) is implemented in the
/// Keychain reader (task 2); this is the shared model.
struct KeychainCredential: Equatable {
    let accessToken: String
    let refreshToken: String
    /// Access-token expiry, milliseconds since the Unix epoch.
    let expiresAtMillis: Double
    let scopes: [String]
    let subscriptionType: String?

    /// Expiry as a `Date`.
    var expiresAt: Date {
        Date(timeIntervalSince1970: expiresAtMillis / 1000)
    }
}
