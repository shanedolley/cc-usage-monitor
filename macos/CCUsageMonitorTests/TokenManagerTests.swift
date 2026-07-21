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

/// Fails its first `failures` calls, then succeeds. Models a transient network error on a refresh
/// that other callers have already joined.
private final class FlakyRefresher: TokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private(set) var presented: [String] = []
    let result: KeychainCredential
    let failures: Int
    let delayMs: UInt64

    init(result: KeychainCredential, failures: Int, delayMs: UInt64 = 60) {
        self.result = result
        self.failures = failures
        self.delayMs = delayMs
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func refresh(using credential: KeychainCredential, now: Date) async throws -> KeychainCredential {
        lock.lock()
        _calls += 1
        let attempt = _calls
        presented.append(credential.refreshToken)
        lock.unlock()
        if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        if attempt <= failures { throw APIError.network("transient") }
        return result
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

    // MARK: - Surviving a failed write-back

    /// The refresh burns the old refresh token server-side the moment it succeeds, so a failed
    /// write-back leaves a dead credential in the store. Until now the failure was swallowed and
    /// never logged: the app kept working on the in-memory token, then read the dead one from the
    /// store on the next cycle and signed the user out permanently. This killed the credential twice
    /// in production. The refreshed credential must survive in memory and be used in preference to
    /// the stale stored one.
    func testFailedWriteBackDoesNotLoseTheRefreshedCredential() async throws {
        // The store keeps handing back the stale credential, exactly as a failed write leaves it.
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"))
        let writer = FakeWriter()
        writer.error = KeychainError.unexpectedStatus(-1)
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        let first = try await manager.validAccessToken()
        XCTAssertEqual(first, "refreshed")
        XCTAssertEqual(refresher.calls, 1)

        // The critical assertion: the next cycle must not fall back to the burned stored token.
        let second = try await manager.validAccessToken()

        XCTAssertEqual(second, "refreshed", "the refreshed credential must survive a failed write")
        XCTAssertEqual(refresher.calls, 1, "and must not burn another refresh token to get there")
    }

    /// A newer credential in the store still wins, so a token Claude Code refreshed is picked up
    /// rather than shadowed by a stale in-memory copy.
    func testStoreWinsWhenItHoldsANewerCredential() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"),
                                    credential(expiresAtMs: 99_000_000, accessToken: "newer-from-store"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 50_000_000, accessToken: "refreshed"))
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        _ = try await manager.validAccessToken()          // refreshes, caches "refreshed"
        let token = try await manager.validAccessToken()  // store now offers a later expiry

        XCTAssertEqual(token, "newer-from-store")
    }

    // MARK: - Single-flight

    /// A forced refresh used to bypass the single-flight join entirely, so it ran concurrently with
    /// an in-flight refresh and both presented the same single-use refresh token. One was rejected,
    /// which surfaced as a spurious sign-out even though the stored credential was fine.
    func testForcedRefreshDoesNotRunConcurrentlyWithAnInFlightRefresh() async throws {
        let keychain = FakeKeychain(credential(expiresAtMs: 0, accessToken: "stale"))
        let refresher = FakeRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"),
                                      delayMs: 120)
        let writer = FakeWriter()
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: writer,
                                   clock: FixedClock(date: now))

        async let normal = manager.validAccessToken()
        async let forced = manager.refreshedAccessToken()
        let (a, b) = try await (normal, forced)

        XCTAssertEqual(a, "refreshed")
        XCTAssertEqual(b, "refreshed")
        XCTAssertEqual(refresher.calls, 1,
                       "the two must share one refresh, not each burn the same single-use token")
    }

    /// When the in-flight refresh FAILS, every caller joined to it wakes up at once. A single join
    /// check let them all fall through and each start their own refresh, presenting the same
    /// still-unspent token concurrently: the very race the join exists to prevent. Joining has to
    /// re-check for a newer in-flight refresh, not assume one attempt settles it.
    func testJoinersOfAFailedRefreshDoNotAllStartTheirOwn() async throws {
        let stale = credential(expiresAtMs: 0, accessToken: "stale")
        let keychain = FakeKeychain(stale)
        let refresher = FlakyRefresher(result: credential(expiresAtMs: 99_000_000, accessToken: "refreshed"),
                                       failures: 1)
        let manager = TokenManager(keychain: keychain, refresher: refresher, writer: FakeWriter(),
                                   clock: FixedClock(date: now))

        // Three concurrent callers over one credential; the first attempt fails.
        async let a = try? await manager.validAccessToken()
        async let b = try? await manager.validAccessToken()
        async let c = try? await manager.validAccessToken()
        _ = await (a, b, c)

        XCTAssertLessThanOrEqual(refresher.calls, 2,
                                 "one failed attempt plus one retry, not one retry per caller")
        let spentTwice = refresher.presented.filter { $0 == stale.refreshToken }.count
        XCTAssertLessThanOrEqual(spentTwice, 2,
                                 "the same single-use refresh token must not be presented three times")
    }
}
