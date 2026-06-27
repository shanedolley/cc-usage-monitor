import XCTest
@testable import CCUsageMonitor

// MARK: - Test doubles

private final class FakeKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var idx = 0
    private var sequence: [KeychainCredential]
    var error: KeychainError?
    private(set) var readCount = 0
    private(set) var lastAllowInteraction: Bool?

    init(_ creds: KeychainCredential...) { sequence = creds }

    func readCredential(allowInteraction: Bool) throws -> KeychainCredential {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        lastAllowInteraction = allowInteraction
        if let error { throw error }
        let credential = sequence[min(idx, sequence.count - 1)]
        idx += 1
        return credential
    }
}

private final class FakeRefresher: TokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let result: KeychainCredential
    let error: APIError?
    let delayMs: UInt64

    init(result: KeychainCredential, error: APIError? = nil, delayMs: UInt64 = 0) {
        self.result = result
        self.error = error
        self.delayMs = delayMs
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    private func recordCall() { lock.lock(); _calls += 1; lock.unlock() }

    func refresh(using credential: KeychainCredential, now: Date) async throws -> KeychainCredential {
        recordCall()
        if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        if let error { throw error }
        return result
    }
}

private final class FakeWriter: KeychainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var updates: [(accessToken: String, refreshToken: String, expiresAt: TimeInterval)] = []
    private(set) var lastAllowInteraction: Bool?
    var error: Error?

    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval,
                      allowInteraction: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        lastAllowInteraction = allowInteraction
        if let error { throw error }
        updates.append((accessToken, refreshToken, expiresAt))
    }
}

private struct FixedClock: ClockProtocol {
    let date: Date
    func now() -> Date { date }
}

private func credential(expiresAtMs: TimeInterval, accessToken: String = "at") -> KeychainCredential {
    KeychainCredential(accessToken: accessToken, refreshToken: "rt",
                       expiresAt: expiresAtMs, scopes: [], subscriptionType: nil)
}

// MARK: - Tests

final class TokenManagerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 10_000)

    func testReturnsCurrentTokenWhenNotExpired() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 99_000_000, accessToken: "fresh"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 0))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let token = try await manager.validAccessToken()

        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(refresher.calls, 0, "no refresh when the token is valid")
        XCTAssertTrue(writer.updates.isEmpty)
    }

    func testRefreshesAndWritesBackWhenExpired() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let token = try await manager.validAccessToken()

        XCTAssertEqual(token, "refreshed")
        XCTAssertEqual(refresher.calls, 1)
        XCTAssertEqual(writer.updates.count, 1, "new token written back to keep Claude Code in sync")
        XCTAssertEqual(writer.updates.first?.accessToken, "refreshed")
    }

    func testRefreshedAccessTokenForcesRefreshEvenWhenNotExpired() async throws {
        // The token looks valid by the clock but was rejected by the server (a 401), so a forced
        // refresh must hit the network rather than returning the not-expired token.
        let keychain = FakeKeychain(credential(expiresAtMs: 99_000_000, accessToken: "valid-but-rejected"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "forced"))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let token = try await manager.refreshedAccessToken()

        XCTAssertEqual(token, "forced", "a forced refresh ignores the not-expired shortcut")
        XCTAssertEqual(refresher.calls, 1)
        XCTAssertEqual(writer.updates.first?.accessToken, "forced")
    }

    func testReReadFirstSkipsNetworkWhenClaudeCodeAlreadyRefreshed() async throws {
        // First read (stale) triggers refresh; the re-read inside refresh sees a fresh token.
        let keychain = FakeKeychain(
            credential(expiresAtMs: 0, accessToken: "stale"),
            credential(expiresAtMs: 99_000_000, accessToken: "cc-refreshed"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 0, accessToken: "should-not-be-used"))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let token = try await manager.validAccessToken()

        XCTAssertEqual(token, "cc-refreshed")
        XCTAssertEqual(refresher.calls, 0, "re-read found a fresh token, so no network refresh")
        XCTAssertTrue(writer.updates.isEmpty)
    }

    func testSingleFlightCollapsesConcurrentRefreshes() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"))
        let refresher = FakeRefresher(
            result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"), delayMs: 60)
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: FakeWriter(),
                                   clock: FixedClock(date: now))

        async let first = manager.validAccessToken()
        async let second = manager.validAccessToken()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, "refreshed")
        XCTAssertEqual(b, "refreshed")
        XCTAssertEqual(refresher.calls, 1, "two concurrent callers share one refresh")
    }

    func testRefreshUnauthorizedPropagates() async {
        let keychain = FakeKeychain(credential(expiresAtMs: 0))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 0), error: .unauthorized)
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: FakeWriter(),
                                   clock: FixedClock(date: now))

        do {
            _ = try await manager.validAccessToken()
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testReadOnlyReturnsValidTokenWithoutRefreshing() async throws {
        // A NoRefreshTokenRefresher and a nil writer make the manager read-only: a valid token is
        // returned straight from the Keychain, with no refresh and no write-back.
        let keychain = FakeKeychain(credential(expiresAtMs: 99_000_000, accessToken: "fresh"))
        let manager = TokenManager(keychain: keychain, refresher: NoRefreshTokenRefresher(),
                                   writer: nil, clock: FixedClock(date: now))

        let token = try await manager.validAccessToken()

        XCTAssertEqual(token, "fresh")
    }

    func testReadOnlyReportsStaleWhenExpiredAndClaudeCodeHasNotRefreshed() async {
        // The stored token has expired and the monitor does not refresh it, so it reports staleness
        // rather than rotating the shared session.
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"))
        let manager = TokenManager(keychain: keychain, refresher: NoRefreshTokenRefresher(),
                                   writer: nil, clock: FixedClock(date: now))

        do {
            _ = try await manager.validAccessToken()
            XCTFail("expected tokenStale")
        } catch let error as APIError {
            XCTAssertEqual(error, .tokenStale)
        } catch {
            XCTFail("expected APIError.tokenStale, got \(error)")
        }
    }

    func testWriteBackFailureIsNonFatal() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 0))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"))
        let writer = FakeWriter()
        writer.error = KeychainError.unexpectedStatus(-1)
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let token = try await manager.validAccessToken()

        XCTAssertEqual(token, "refreshed", "refresh succeeds even when write-back fails")
    }

    func testValidAccessTokenReadsNonInteractively() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 99_000_000, accessToken: "fresh"))
        let manager = TokenManager(keychain: keychain,
                                   refresher: FakeRefresher(result: credential(expiresAtMs: 0)),
                                   writer: FakeWriter(), clock: FixedClock(date: now))

        _ = try await manager.validAccessToken()

        XCTAssertEqual(keychain.lastAllowInteraction, false, "the poll path must never prompt")
    }

    func testEstablishAccessReadsAndWritesInteractively() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 99_000_000, accessToken: "at"))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain,
                                   refresher: FakeRefresher(result: credential(expiresAtMs: 0)),
                                   writer: writer, clock: FixedClock(date: now))

        try await manager.establishAccess()

        XCTAssertEqual(keychain.lastAllowInteraction, true, "the explicit grant reads interactively")
        XCTAssertEqual(writer.lastAllowInteraction, true, "the explicit grant writes interactively")
        XCTAssertEqual(writer.updates.count, 1, "it re-writes the same tokens to grant write access")
        XCTAssertEqual(writer.updates.first?.accessToken, "at")
    }
}
