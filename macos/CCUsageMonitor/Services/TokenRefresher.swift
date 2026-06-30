import Foundation
import os

/// The subset of Anthropic's OAuth token response this app needs. Standard OAuth 2.0
/// fields; the server may omit `refresh_token` when it does not rotate.
struct TokenRefreshResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?   // seconds until the new access token expires

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    /// Used when the server omits `expires_in`. A zero fallback would mark the new token
    /// expired on arrival, so `isExpired` would be true on the next poll and the app would
    /// refresh every cycle forever; one hour is a safe, conservative lifetime instead.
    static let fallbackLifetime: TimeInterval = 3600

    /// Builds the new credential, carrying over scopes and subscription type, and reusing
    /// the previous refresh token when the server did not return a new one.
    func applied(to previous: KeychainCredential, now: Date) -> KeychainCredential {
        let expiresAtMillis = (now.timeIntervalSince1970 + (expiresIn ?? Self.fallbackLifetime)) * 1000
        return KeychainCredential(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previous.refreshToken,
            expiresAt: expiresAtMillis,
            scopes: previous.scopes,
            subscriptionType: previous.subscriptionType
        )
    }
}

/// Calls `POST /v1/oauth/token` with the refresh-token grant. The endpoint and public
/// client id were confirmed by the Phase 1 spike. Transport is injectable for tests.
struct TokenRefresher: TokenRefreshing {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    let endpoint: URL
    let clientID: String
    let userAgent: String
    private let transport: Transport

    /// An ephemeral session so a token-bearing response is never persisted to the on-disk
    /// URL cache (NFR-004). Tests inject their own transport and never touch this.
    private static let session = URLSession(configuration: .ephemeral)

    private static let logger = Logger(subsystem: "com.shanedolley.ccusagemonitor", category: "TokenRefresher")

    init(endpoint: URL = URL(string: "https://console.anthropic.com/v1/oauth/token")!,
         clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
         userAgent: String = "cc-usage-monitor/1.0",
         transport: Transport? = nil) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.userAgent = userAgent
        self.transport = transport ?? { try await Self.session.data(for: $0) }
    }

    func refresh(using credential: KeychainCredential, now: Date) async throws -> KeychainCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
            "client_id": clientID,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(TokenRefreshResponse.self, from: data).applied(to: credential, now: now)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        case 400, 401:
            // The refresh token was rejected; the user must reauthenticate. Log the response body
            // so the exact reason (invalid_grant, invalid_client, and so on) is diagnosable. A 4xx
            // token-endpoint body carries an OAuth `error` code, not a secret, so logging it as
            // public is safe; the 2xx body, which does hold tokens, is never logged.
            Self.logger.error("Refresh rejected (HTTP \(http.statusCode, privacy: .public)): \(Self.bodyText(data), privacy: .public)")
            throw APIError.unauthorized
        case 500...599:
            throw APIError.serverError(http.statusCode)
        default:
            // An unexpected status is opaque, so log its body to aid diagnosis. A non-2xx body
            // never carries tokens.
            Self.logger.error("Refresh returned unexpected HTTP \(http.statusCode, privacy: .public): \(Self.bodyText(data), privacy: .public)")
            throw APIError.unexpectedStatus(http.statusCode)
        }
    }

    /// Decodes a non-2xx response body to text for logging, truncated so a stray large body cannot
    /// flood the log. Only ever called on error responses, which carry no tokens.
    private static func bodyText(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 512 ? String(text.prefix(512)) + "…(truncated)" : text
    }
}
