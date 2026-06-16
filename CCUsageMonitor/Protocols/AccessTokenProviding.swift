import Foundation

/// Supplies a currently-valid access token. The polling coordinator depends on this rather
/// than on `TokenManager` directly, so it can be tested with a fake (NFR-007).
protocol AccessTokenProviding {
    func validAccessToken() async throws -> String
}

extension TokenManager: AccessTokenProviding {}
