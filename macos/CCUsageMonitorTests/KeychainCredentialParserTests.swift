import XCTest
@testable import CCUsageMonitor

final class KeychainCredentialParserTests: XCTestCase {

    func testParsesWrappedCredential() throws {
        let json = Data("""
        {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt",
          "expiresAt": 1781600781908, "scopes": ["user:inference", "user:profile"],
          "subscriptionType": "max"}}
        """.utf8)

        let cred = try KeychainCredentialParser.parse(json)

        XCTAssertEqual(cred.accessToken, "at")
        XCTAssertEqual(cred.refreshToken, "rt")
        XCTAssertEqual(cred.expiresAt, 1781600781908)
        XCTAssertEqual(cred.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(cred.subscriptionType, "max")
    }

    func testParsesTopLevelCredential() throws {
        let json = Data("""
        {"accessToken": "a", "refreshToken": "r", "expiresAt": 1000,
          "scopes": [], "subscriptionType": null}
        """.utf8)

        let cred = try KeychainCredentialParser.parse(json)

        XCTAssertEqual(cred.accessToken, "a")
        XCTAssertNil(cred.subscriptionType)
    }

    func testInvalidDataThrowsInvalidData() {
        XCTAssertThrowsError(try KeychainCredentialParser.parse(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? KeychainError, .invalidData)
        }
    }

    func testExpiryRespectsBuffer() {
        // expiresAt = 1_000_000 ms = 1000 s after epoch.
        let cred = KeychainCredential(accessToken: "a", refreshToken: "r",
                                      expiresAt: 1_000_000, scopes: [], subscriptionType: nil)
        let expiry = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(cred.isExpired(now: expiry.addingTimeInterval(-200), buffer: 120),
                       "200s before expiry is outside the 120s buffer, so not expired")
        XCTAssertTrue(cred.isExpired(now: expiry.addingTimeInterval(-60), buffer: 120),
                      "60s before expiry is inside the 120s buffer, so treated as expired")
        XCTAssertTrue(cred.isExpired(now: expiry.addingTimeInterval(10), buffer: 120),
                      "past expiry is expired")
    }
}
