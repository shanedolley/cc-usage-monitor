import Foundation

/// Fetches the profile and usage data from Anthropic's OAuth endpoints.
/// The access token is passed in so the caller (TokenManager) owns token lifecycle.
protocol APIClientProtocol {
    func fetchProfile(accessToken: String) async throws -> ProfileResponse
    func fetchUsage(accessToken: String) async throws -> UsageResponse
}
