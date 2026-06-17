import XCTest
@testable import CCUsageMonitor

final class KeychainCredentialPatcherTests: XCTestCase {

    func testPatchUpdatesTokensAndPreservesOtherFields() throws {
        let original = Data("""
        {"claudeAiOauth": {"accessToken": "old_at", "refreshToken": "old_rt",
          "expiresAt": 1000, "scopes": ["user:inference"], "subscriptionType": "max",
          "extraField": "keep-me"}, "topLevelExtra": 42}
        """.utf8)

        let patched = try KeychainCredentialPatcher.patch(
            original, accessToken: "new_at", refreshToken: "new_rt", expiresAt: 2_000_000)

        let root = try JSONSerialization.jsonObject(with: patched) as! [String: Any]
        let oauth = root["claudeAiOauth"] as! [String: Any]

        XCTAssertEqual(oauth["accessToken"] as? String, "new_at")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new_rt")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 2_000_000, "expiry written as an integer")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max", "preserved")
        XCTAssertEqual(oauth["extraField"] as? String, "keep-me", "unknown nested field preserved")
        XCTAssertEqual(root["topLevelExtra"] as? Int, 42, "unknown top-level field preserved")
    }

    func testPatchTopLevelCredential() throws {
        let original = Data("""
        {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "scopes": []}
        """.utf8)

        let patched = try KeychainCredentialPatcher.patch(
            original, accessToken: "a2", refreshToken: "r2", expiresAt: 5)

        let root = try JSONSerialization.jsonObject(with: patched) as! [String: Any]
        XCTAssertEqual(root["accessToken"] as? String, "a2")
        XCTAssertEqual(root["refreshToken"] as? String, "r2")
        XCTAssertEqual(root["expiresAt"] as? Int, 5)
    }

    func testPatchRejectsNonObjectJSON() {
        XCTAssertThrowsError(try KeychainCredentialPatcher.patch(
            Data("[1,2,3]".utf8), accessToken: "a", refreshToken: "r", expiresAt: 1))
    }
}
