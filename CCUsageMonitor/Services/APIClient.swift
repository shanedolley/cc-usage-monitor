import Foundation

/// Typed errors from the API client. The polling coordinator maps these to UI states
/// and retry behavior (see PRD edge-case table).
enum APIError: Error, Equatable {
    case unauthorized                          // 401: token rejected
    case rateLimited(retryAfter: TimeInterval?) // 429: honor Retry-After up to a cap
    case serverError(Int)                      // 5xx: transient
    case endpointUnavailable(Int)              // 403, 404, 410: terminal
    case network(String)                       // transport failure (offline, timeout)
    case decoding(String)                      // body did not match the model
    case unexpectedStatus(Int)
}

/// Calls Anthropic's OAuth profile and usage endpoints. The transport is injectable so
/// every status-code path is testable without the network (NFR-007).
struct APIClient: APIClientProtocol {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let userAgent: String
    private let transport: Transport

    /// An ephemeral session so a token-bearing response is never persisted to the on-disk
    /// URL cache (NFR-004). Tests inject their own transport and never touch this.
    private static let session = URLSession(configuration: .ephemeral)

    init(baseURL: URL = URL(string: "https://api.anthropic.com")!,
         userAgent: String = "cc-usage-monitor/1.0",
         transport: Transport? = nil) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.transport = transport ?? { request in
            try await Self.session.data(for: request)
        }
    }

    func fetchProfile(accessToken: String) async throws -> ProfileResponse {
        try await get("api/oauth/profile", accessToken: accessToken)
    }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        try await get("api/oauth/usage", accessToken: accessToken)
    }

    private func get<T: Decodable>(_ path: String, accessToken: String) async throws -> T {
        let request = makeRequest(path: path, accessToken: accessToken)

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
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        case 401:
            throw APIError.unauthorized
        case 403, 404, 410:
            throw APIError.endpointUnavailable(http.statusCode)
        case 429:
            throw APIError.rateLimited(retryAfter: Self.retryAfter(from: http))
        case 500...599:
            throw APIError.serverError(http.statusCode)
        default:
            throw APIError.unexpectedStatus(http.statusCode)
        }
    }

    private func makeRequest(path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parses a numeric `Retry-After` header (seconds). HTTP-date form is ignored for now.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value)
    }
}
