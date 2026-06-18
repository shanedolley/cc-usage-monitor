import XCTest
@testable import CCUsageMonitor

final class FileCredentialStoreTests: XCTestCase {

    /// A unique directory under the temp directory, removed after each test.
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String = "credentials.json") -> URL {
        dir.appendingPathComponent(name)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsSeededKeychainJSON() throws {
        let file = url()
        // The wrapped shape `claude` stores, which is what a one-time seed copies in verbatim.
        try write("""
        {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt", "expiresAt": 1781600781908,
          "scopes": ["user:inference", "user:profile"], "subscriptionType": "max"}}
        """, to: file)

        let cred = try FileCredentialStore(url: file).readCredential(allowInteraction: false)

        XCTAssertEqual(cred.accessToken, "at")
        XCTAssertEqual(cred.refreshToken, "rt")
        XCTAssertEqual(cred.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(cred.subscriptionType, "max")
    }

    func testMissingFileThrowsItemNotFound() {
        XCTAssertThrowsError(try FileCredentialStore(url: url()).readCredential(allowInteraction: false)) {
            XCTAssertEqual($0 as? KeychainError, .itemNotFound)
        }
    }

    func testInvalidJSONThrowsInvalidData() throws {
        let file = url()
        try write("not json", to: file)

        XCTAssertThrowsError(try FileCredentialStore(url: file).readCredential(allowInteraction: false)) {
            XCTAssertEqual($0 as? KeychainError, .invalidData)
        }
    }

    func testUpdateTokensRoundTripsAndPreservesScopes() throws {
        let file = url()
        try write("""
        {"claudeAiOauth": {"accessToken": "old", "refreshToken": "old-rt", "expiresAt": 1000,
          "scopes": ["user:inference", "user:profile"], "subscriptionType": "max"}}
        """, to: file)
        let store = FileCredentialStore(url: file)

        try store.updateTokens(accessToken: "new", refreshToken: "new-rt", expiresAt: 2000)
        let cred = try store.readCredential(allowInteraction: false)

        XCTAssertEqual(cred.accessToken, "new")
        XCTAssertEqual(cred.refreshToken, "new-rt")
        XCTAssertEqual(cred.expiresAt, 2000)
        XCTAssertEqual(cred.scopes, ["user:inference", "user:profile"], "a refresh keeps the scopes")
        XCTAssertEqual(cred.subscriptionType, "max", "a refresh keeps the subscription type")
    }

    func testUpdateTokensCreatesDirectoryAndSetsOwnerOnlyPermissions() throws {
        let file = dir.appendingPathComponent("nested/credentials.json")   // parent does not exist yet

        try FileCredentialStore(url: file).updateTokens(accessToken: "a", refreshToken: "r", expiresAt: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the parent directory is created")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "the secret file is owner-only")
    }

    func testIsConfiguredReflectsFilePresence() throws {
        let file = url()
        XCTAssertFalse(FileCredentialStore.isConfigured(url: file))

        try write("{}", to: file)
        XCTAssertTrue(FileCredentialStore.isConfigured(url: file))
    }
}
