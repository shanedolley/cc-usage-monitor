import XCTest
@testable import CCUsageMonitor

final class APIClientTests: XCTestCase {

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: usageURL, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func assertAPIError(
        _ expected: APIError, _ block: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected APIError, got \(error)", file: file, line: line)
        }
    }

    func testFetchUsageDecodesBodyAndSetsHeaders() async throws {
        let json = Data("""
        {"five_hour": {"utilization": 15.0, "resets_at": "2026-06-16T04:39:59+00:00"},
         "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 0.0,
                         "currency": "AUD", "decimal_places": 2}}
        """.utf8)
        var captured: URLRequest?
        let client = APIClient(transport: { request in
            captured = request
            return (json, self.response(200))
        })

        let usage = try await client.fetchUsage(accessToken: "TOKEN123")

        XCTAssertEqual(usage.fiveHour?.utilization, 15.0)
        XCTAssertEqual(usage.extraUsage?.currency, "AUD")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), "cc-usage-monitor/1.0")
    }

    func testFetchProfileHitsProfilePath() async throws {
        var captured: URLRequest?
        let client = APIClient(transport: { request in
            captured = request
            return (Data("{}".utf8), self.response(200))
        })
        _ = try await client.fetchProfile(accessToken: "t")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.anthropic.com/api/oauth/profile")
    }

    func testUnauthorizedMapsToError() async {
        let client = APIClient(transport: { _ in (Data(), self.response(401)) })
        await assertAPIError(.unauthorized) { _ = try await client.fetchUsage(accessToken: "t") }
    }

    func testRateLimitedParsesRetryAfter() async {
        let client = APIClient(transport: { _ in (Data(), self.response(429, headers: ["Retry-After": "30"])) })
        await assertAPIError(.rateLimited(retryAfter: 30)) { _ = try await client.fetchUsage(accessToken: "t") }
    }

    func testServerErrorIsTransient() async {
        let client = APIClient(transport: { _ in (Data(), self.response(503)) })
        await assertAPIError(.serverError(503)) { _ = try await client.fetchUsage(accessToken: "t") }
    }

    func testForbiddenIsTerminal() async {
        let client = APIClient(transport: { _ in (Data(), self.response(403)) })
        await assertAPIError(.endpointUnavailable(403)) { _ = try await client.fetchUsage(accessToken: "t") }
    }

    func testMalformedBodyIsDecodingError() async {
        let client = APIClient(transport: { _ in (Data("<<not json>>".utf8), self.response(200)) })
        do {
            _ = try await client.fetchUsage(accessToken: "t")
            XCTFail("expected a decoding error")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testTransportFailureIsNetworkError() async {
        struct Boom: Error {}
        let client = APIClient(transport: { _ in throw Boom() })
        do {
            _ = try await client.fetchUsage(accessToken: "t")
            XCTFail("expected a network error")
        } catch let error as APIError {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }
}
