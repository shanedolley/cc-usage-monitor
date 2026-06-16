import XCTest
@testable import CCUsageMonitor

final class TokenRefresherTests: XCTestCase {

    private let endpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    private func previous() -> KeychainCredential {
        KeychainCredential(accessToken: "old", refreshToken: "old_rt", expiresAt: 0,
                           scopes: ["user:inference"], subscriptionType: "max")
    }

    func testRefreshAppliesNewTokensAndComputesExpiry() async throws {
        let body = Data("""
        {"access_token": "new_at", "refresh_token": "new_rt", "expires_in": 3600}
        """.utf8)
        var captured: URLRequest?
        let refresher = TokenRefresher(endpoint: endpoint, transport: { request in
            captured = request
            return (body, HTTPURLResponse(url: self.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let now = Date(timeIntervalSince1970: 1_000_000)

        let cred = try await refresher.refresh(using: previous(), now: now)

        XCTAssertEqual(cred.accessToken, "new_at")
        XCTAssertEqual(cred.refreshToken, "new_rt")
        XCTAssertEqual(cred.expiresAt, (1_000_000 + 3600) * 1000, "now + expires_in, in ms")
        XCTAssertEqual(cred.scopes, ["user:inference"], "carried over from previous")
        XCTAssertEqual(cred.subscriptionType, "max")
        XCTAssertEqual(captured?.httpMethod, "POST")
    }

    func testRefreshReusesPreviousRefreshTokenWhenServerOmitsIt() async throws {
        let body = Data("""
        {"access_token": "new_at", "expires_in": 100}
        """.utf8)
        let refresher = TokenRefresher(endpoint: endpoint, transport: { _ in
            (body, HTTPURLResponse(url: self.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let cred = try await refresher.refresh(using: previous(), now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(cred.refreshToken, "old_rt", "no rotation: previous refresh token reused")
    }

    func testMissingExpiresInDoesNotMarkTokenImmediatelyExpired() async throws {
        // No expires_in in the body. A zero fallback would set expiry to `now`, so isExpired
        // would be true on the next poll and the app would refresh every cycle forever.
        let body = Data(#"{"access_token": "new_at"}"#.utf8)
        let refresher = TokenRefresher(endpoint: endpoint, transport: { _ in
            (body, HTTPURLResponse(url: self.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let now = Date(timeIntervalSince1970: 1_000_000)

        let cred = try await refresher.refresh(using: previous(), now: now)

        XCTAssertEqual(cred.expiresAt, (1_000_000 + TokenRefreshResponse.fallbackLifetime) * 1000,
                       "now + fallback lifetime, in ms")
        XCTAssertFalse(cred.isExpired(now: now), "a freshly refreshed token must not read as expired")
    }

    func testInvalidGrantMapsToUnauthorized() async {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        let refresher = TokenRefresher(endpoint: endpoint, transport: { _ in
            (body, HTTPURLResponse(url: self.endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await refresher.refresh(using: previous(), now: Date())
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }
}
