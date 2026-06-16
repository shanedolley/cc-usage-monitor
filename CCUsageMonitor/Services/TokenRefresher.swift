import Foundation

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

    /// Builds the new credential, carrying over scopes and subscription type, and reusing
    /// the previous refresh token when the server did not return a new one.
    func applied(to previous: KeychainCredential, now: Date) -> KeychainCredential {
        let expiresAtMillis = (now.timeIntervalSince1970 + (expiresIn ?? 0)) * 1000
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

    init(endpoint: URL = URL(string: "https://console.anthropic.com/v1/oauth/token")!,
         clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
         userAgent: String = "cc-usage-monitor/1.0",
         transport: Transport? = nil) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.userAgent = userAgent
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
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
            // invalid_grant: the refresh token is no longer valid; the user must reauthenticate.
            throw APIError.unauthorized
        case 500...599:
            throw APIError.serverError(http.statusCode)
        default:
            throw APIError.unexpectedStatus(http.statusCode)
        }
    }
}
