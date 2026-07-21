import XCTest
@testable import CCUsageMonitor

private final class FakeAPI: APIClientProtocol, @unchecked Sendable {
    var profileResult: Result<ProfileResponse, Error>
    var usageResult: Result<UsageResponse, Error>

    init(profile: Result<ProfileResponse, Error>, usage: Result<UsageResponse, Error>) {
        profileResult = profile
        usageResult = usage
    }

    func fetchProfile(accessToken: String) async throws -> ProfileResponse { try profileResult.get() }
    func fetchUsage(accessToken: String) async throws -> UsageResponse { try usageResult.get() }
}

private struct FakeToken: AccessTokenProviding {
    var result: Result<String, Error> = .success("token")
    var refreshResult: Result<String, Error>?
    func validAccessToken() async throws -> String { try result.get() }
    func refreshedAccessToken() async throws -> String { try (refreshResult ?? result).get() }
}

/// A token provider whose result can change between polls, so a test can succeed once and then go
/// stale on the next poll.
private final class MutableToken: AccessTokenProviding, @unchecked Sendable {
    var result: Result<String, Error>
    init(_ result: Result<String, Error>) { self.result = result }
    func validAccessToken() async throws -> String { try result.get() }
    func refreshedAccessToken() async throws -> String { try result.get() }
}

/// Stands in for a Keychain grant sitting behind a modal dialog the user has not answered: the call
/// never returns. Mirrors the live failure where `SecurityAgent` held a prompt open and the app,
/// awaiting the grant before starting its loop, never polled.
private struct BlockingGrantToken: AccessTokenProviding {
    func validAccessToken() async throws -> String { "token" }
    func establishAccess() async throws {
        try await Task.sleep(nanoseconds: .max)
    }
}

/// Polls `condition` until it holds or the timeout expires, so a test waits for real state instead
/// of a fixed sleep sized by guesswork.
private func waitUntil(timeout: TimeInterval = 2,
                       _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Counts fetches, so a test can prove how many the launch path makes. An actor so the count is
/// async-safe.
private actor CountingAPI: APIClientProtocol {
    private let profileValue: ProfileResponse
    private let usageValue: UsageResponse
    private(set) var calls = 0

    init(profile: ProfileResponse, usage: UsageResponse) {
        self.profileValue = profile
        self.usageValue = usage
    }

    func fetchProfile(accessToken: String) async throws -> ProfileResponse { calls += 1; return profileValue }
    func fetchUsage(accessToken: String) async throws -> UsageResponse { calls += 1; return usageValue }
}

/// Records `establishAccess()` so the grant-then-poll flow is testable.
private final class RecordingToken: AccessTokenProviding, @unchecked Sendable {
    private(set) var establishCalls = 0
    func validAccessToken() async throws -> String { "token" }
    func establishAccess() async throws { establishCalls += 1 }
}

/// Returns a different usage result on each fetch, so a 401-then-success retry can be tested.
/// An actor so its mutable sequence is async-safe without manual locking.
private actor SequencedAPI: APIClientProtocol {
    let profile: Result<ProfileResponse, Error>
    private var usageResults: [Result<UsageResponse, Error>]

    init(profile: Result<ProfileResponse, Error>, usage: [Result<UsageResponse, Error>]) {
        self.profile = profile
        self.usageResults = usage
    }

    func fetchProfile(accessToken: String) async throws -> ProfileResponse { try profile.get() }
    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        let next = usageResults.first ?? usageResults.last!
        if usageResults.count > 1 { usageResults.removeFirst() }
        return try next.get()
    }
}

/// Fails the usage call with 401 unless the request carries the force-refreshed token, so a
/// test can prove the retry actually used `refreshedAccessToken()` and not the original. An
/// actor so its recorded tokens are async-safe without manual locking.
private actor TokenAwareAPI: APIClientProtocol {
    let profile: Result<ProfileResponse, Error>
    let refreshedToken: String
    let usageOnRefreshed: UsageResponse
    private(set) var seenTokens: [String] = []

    init(profile: Result<ProfileResponse, Error>, refreshedToken: String, usage: UsageResponse) {
        self.profile = profile
        self.refreshedToken = refreshedToken
        self.usageOnRefreshed = usage
    }

    func fetchProfile(accessToken: String) async throws -> ProfileResponse { try profile.get() }
    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        seenTokens.append(accessToken)
        if accessToken == refreshedToken { return usageOnRefreshed }
        throw APIError.unauthorized
    }
}

/// A token provider whose `validAccessToken()` blocks until released, so a test can start one
/// poll, suspend it mid-flight, fire a second poll, and assert the second one is ignored. An
/// actor so its state is async-safe without manual locking.
private actor GatedToken: AccessTokenProviding {
    private(set) var validCalls = 0
    private var entered = false
    private var released = false
    private var enterCont: CheckedContinuation<Void, Never>?
    private var releaseCont: CheckedContinuation<Void, Never>?

    func validAccessToken() async throws -> String {
        validCalls += 1
        entered = true
        enterCont?.resume(); enterCont = nil
        if !released {
            await withCheckedContinuation { releaseCont = $0 }
        }
        return "token"
    }

    func refreshedAccessToken() async throws -> String { "token" }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterCont = $0 }
    }

    func release() {
        released = true
        releaseCont?.resume(); releaseCont = nil
    }
}

private struct FixedClock: ClockProtocol {
    let date: Date
    func now() -> Date { date }
}

@MainActor
final class PollingCoordinatorTests: XCTestCase {

    private func emptyProfile() -> ProfileResponse {
        try! JSONDecoder().decode(ProfileResponse.self, from: Data("{}".utf8))
    }
    private func usage(_ utilization: Double) -> UsageResponse {
        try! JSONDecoder().decode(UsageResponse.self,
            from: Data("{\"five_hour\":{\"utilization\":\(utilization)}}".utf8))
    }

    private func makeCoordinator(api: APIClientProtocol, token: AccessTokenProviding = FakeToken()) -> PollingCoordinator {
        PollingCoordinator(api: api, tokenProvider: token,
                           clock: FixedClock(date: Date(timeIntervalSince1970: 1000)), interval: 60)
    }

    func testLiveOnSuccess() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(15)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .live)
        XCTAssertEqual(coordinator.snapshot?.usage.fiveHour?.utilization, 15)
        XCTAssertEqual(coordinator.lastUpdated, Date(timeIntervalSince1970: 1000))
    }

    func testReauthenticateOnUnauthorized() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .failure(APIError.unauthorized))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .reauthenticate)
    }

    func testEndpointUnavailableIsTerminal() async {
        let api = FakeAPI(profile: .failure(APIError.endpointUnavailable(410)), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .endpointUnavailable)
    }

    func testOfflineWhenNetworkFailsWithNoData() async {
        let api = FakeAPI(profile: .failure(APIError.network("down")), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .offline)
        XCTAssertNil(coordinator.snapshot)
    }

    func testStaleKeepsLastSnapshotWhenNetworkFails() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(20)))
        let coordinator = makeCoordinator(api: api)
        await coordinator.poll()
        XCTAssertEqual(coordinator.status, .live)

        api.usageResult = .failure(APIError.network("dropped"))
        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .stale)
        XCTAssertEqual(coordinator.snapshot?.usage.fiveHour?.utilization, 20, "last good data retained")
    }

    func testKeychainDeniedStatus() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api, token: FakeToken(result: .failure(KeychainError.accessDenied)))

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .keychainDenied)
    }

    func testMissingTokenIsReauthenticate() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api, token: FakeToken(result: .failure(KeychainError.itemNotFound)))

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .reauthenticate)
    }

    func testTokenStaleWithNoDataStaysLoadingNotReauthenticate() async {
        // The monitor reads but never refreshes Claude Code's token. An expired token with no data
        // yet must keep loading, not tell the user to sign in.
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api, token: MutableToken(.failure(APIError.tokenStale)))

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .loading)
    }

    func testTokenStaleKeepsLastGoodDataNotReauthenticate() async {
        // After a good poll, an expired token holds the last good data rather than signing the user
        // out, since Claude Code refreshes the token on its next use.
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(20)))
        let token = MutableToken(.success("token"))
        let coordinator = makeCoordinator(api: api, token: token)
        await coordinator.poll()
        XCTAssertEqual(coordinator.status, .live)

        token.result = .failure(APIError.tokenStale)
        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .stale)
        XCTAssertEqual(coordinator.snapshot?.usage.fiveHour?.utilization, 20, "last good data retained")
    }

    func testServerErrorWithNoDataStaysLoading() async {
        let api = FakeAPI(profile: .failure(APIError.serverError(503)), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .loading)
    }

    func test401ForcesRefreshAndRetrySucceeds() async {
        // The API rejects the original token and accepts only the force-refreshed one, so this
        // fails if the retry used validAccessToken() instead of refreshedAccessToken().
        let api = TokenAwareAPI(profile: .success(emptyProfile()),
                                refreshedToken: "fresh", usage: usage(42))
        let token = FakeToken(result: .success("stale"), refreshResult: .success("fresh"))
        let coordinator = makeCoordinator(api: api, token: token)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .live, "a refreshed token recovers from a mid-flight 401")
        XCTAssertEqual(coordinator.snapshot?.usage.fiveHour?.utilization, 42)
        let seen = await api.seenTokens
        XCTAssertEqual(seen, ["stale", "fresh"],
                       "the retry must use the force-refreshed token, not the original")
    }

    func testReentrantPollIsIgnoredWhileOneIsInFlight() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(7)))
        let token = GatedToken()
        let coordinator = makeCoordinator(api: api, token: token)

        // Start a poll that blocks inside the token provider, then fire a second poll while the
        // first is suspended: the guard must drop it (no second token read).
        let first = Task { await coordinator.poll() }
        await token.waitUntilEntered()
        await coordinator.poll()
        let calls = await token.validCalls
        XCTAssertEqual(calls, 1, "a reentrant poll is ignored while one is in flight")

        await token.release()
        await first.value
        XCTAssertEqual(coordinator.status, .live)
    }

    func test401ThatPersistsAfterRefreshShowsReauthenticate() async {
        let api = SequencedAPI(profile: .success(emptyProfile()),
                               usage: [.failure(APIError.unauthorized)])
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .reauthenticate, "a 401 that survives a refresh needs sign-in")
    }

    func test401ThenRateLimitedOnRetryBacksOffNotReauthenticate() async {
        let api = SequencedAPI(profile: .success(emptyProfile()),
                               usage: [.failure(APIError.unauthorized),
                                       .failure(APIError.rateLimited(retryAfter: 120))])
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 120)
        XCTAssertNotEqual(coordinator.status, .reauthenticate,
                          "a 429 on the retry is rate-limiting, not an auth failure")
    }

    func test401ThenServerErrorOnRetryStaysLoadingNotReauthenticate() async {
        // A 5xx on the forced refresh is transient, not an auth failure. With no data yet the app
        // keeps loading; it must not tell the user to sign in.
        let api = SequencedAPI(profile: .success(emptyProfile()),
                               usage: [.failure(APIError.unauthorized),
                                       .failure(APIError.serverError(503))])
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .loading,
                       "a transient 5xx on the retry must not force a sign-in")
    }

    func test401ThenServerErrorOnRetryKeepsLastGoodDataNotReauthenticate() async {
        // After a good poll, a 401 followed by a 5xx on the forced refresh holds the last good data
        // as stale rather than signing the user out over a transient server error.
        let api = SequencedAPI(profile: .success(emptyProfile()),
                               usage: [.success(usage(20)),
                                       .failure(APIError.unauthorized),
                                       .failure(APIError.serverError(503))])
        let coordinator = makeCoordinator(api: api)
        await coordinator.poll()
        XCTAssertEqual(coordinator.status, .live)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .stale,
                       "a transient 5xx on the retry keeps the last good data, not reauthenticate")
        XCTAssertEqual(coordinator.snapshot?.usage.fiveHour?.utilization, 20, "last good data retained")
    }

    func test401ThenDecodingErrorOnRetryStaysLoadingNotReauthenticate() async {
        // A decoding failure on the forced refresh is a transient or upstream-format problem, not a
        // rejected credential, so it must not force a sign-in.
        let api = SequencedAPI(profile: .success(emptyProfile()),
                               usage: [.failure(APIError.unauthorized),
                                       .failure(APIError.decoding("bad body"))])
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .loading,
                       "a decoding error on the retry must not force a sign-in")
    }

    /// The interval is a rate-limit control, not a cosmetic preference: at 60s the app made roughly
    /// 1,440 requests a day to the usage endpoint and was rate-limited for hours. The cap must stay
    /// clear of it, or the escalation in `backoff(for:)` has nowhere to climb.
    func testDefaultIntervalIsFiveMinutesAndBelowTheBackoffCap() {
        XCTAssertEqual(PollingCoordinator.defaultInterval, 300)
        XCTAssertGreaterThan(PollingCoordinator.maxBackoff, PollingCoordinator.defaultInterval)
    }

    func test429SetsBackoffCappedAtMaxBackoff() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 9000)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, PollingCoordinator.maxBackoff,
                       "an outsized Retry-After is capped")
    }

    /// A `Retry-After` longer than our own escalation is the server asking for more time, so it wins.
    func test429HonorsRetryAfterLongerThanEscalation() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 600)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 600, "600s beats the first escalation step of 60s")
    }

    func test429HonorsRetryAfterUnderCap() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 120)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 120)
    }

    /// Anthropic's usage endpoint answers `Retry-After: 0` when it rate-limits. Taken literally that
    /// means "retry immediately", so the poll loop slept zero seconds and hammered the endpoint,
    /// which kept the rate limit alive indefinitely: the app became the reason it stayed limited.
    /// Observed live on 2026-07-21, with the rings frozen and the status stuck on stale.
    func test429WithZeroRetryAfterDoesNotBusyLoop() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 0)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertGreaterThanOrEqual(coordinator.nextDelay, 60,
                                    "a zero Retry-After must never poll faster than the normal interval")
    }

    /// The Keychain grant can block on a modal dialog the user has not answered. The poll loop must
    /// not be gated on it, or an ignored dialog leaves the app showing a spinner forever, never
    /// polling. Observed live on 2026-07-21 with a `SecurityAgent` prompt open and the app silent.
    func testLoopStartsEvenWhenTheGrantNeverCompletes() async {
        let api = CountingAPI(profile: emptyProfile(), usage: usage(1))
        let coordinator = makeCoordinator(api: api, token: BlockingGrantToken())

        // Not awaited: the grant never returns, which is the condition under test. The app calls this
        // from a detached Task for the same reason.
        let launch = Task { await coordinator.startAfterEstablishingAccess() }
        await waitUntil { await api.calls >= 2 }
        launch.cancel()
        coordinator.stop()

        let calls = await api.calls
        XCTAssertGreaterThanOrEqual(calls, 2, "the loop must poll without waiting on the grant")
    }

    /// The launch path must fetch once, not twice. Two fetches ~300ms apart was wasted work and a
    /// way to trip the usage endpoint's rate limit before the first ring was drawn.
    func testLaunchPathFetchesOnce() async {
        let api = CountingAPI(profile: emptyProfile(), usage: usage(1))
        let coordinator = makeCoordinator(api: api)

        await coordinator.startAfterEstablishingAccess()
        // The loop polls on its own task, so wait for the first fetch rather than assuming it has
        // landed. The duplicate this guards against arrived ~300ms after the first, so settle well
        // past that before counting; the next scheduled poll is a full interval away.
        await waitUntil { await api.calls >= 2 }
        try? await Task.sleep(nanoseconds: 600_000_000)
        coordinator.stop()

        let calls = await api.calls
        XCTAssertEqual(calls, 2, "one poll fetches profile and usage once each, not twice")
    }

    /// Anthropic's usage endpoint sends `Retry-After: 0` on every rate limit, so the header carries
    /// no timing information at all. Retrying at a fixed interval against a limit that lasts hours
    /// just sustains the pressure, so consecutive 429s must back off progressively.
    func test429BacksOffProgressivelyWhileLimited() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 0)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()
        let first = coordinator.nextDelay
        await coordinator.poll()
        let second = coordinator.nextDelay
        await coordinator.poll()
        let third = coordinator.nextDelay

        XCTAssertGreaterThan(second, first, "a second consecutive 429 must wait longer")
        XCTAssertGreaterThan(third, second, "and a third longer still")
        XCTAssertLessThanOrEqual(third, PollingCoordinator.maxBackoff, "capped at five minutes")
    }

    /// The backoff must not outlive the condition: once a poll succeeds, the next one is due at the
    /// normal interval, not at the escalated delay.
    func testSuccessResetsTheRateLimitBackoff() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 0)))
        let coordinator = makeCoordinator(api: api)
        await coordinator.poll()
        await coordinator.poll()
        XCTAssertGreaterThan(coordinator.nextDelay, 60)

        api.usageResult = .success(usage(30))
        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .live)
        XCTAssertEqual(coordinator.nextDelay, 60, "a success returns to the normal interval")
    }

    /// Same guarantee for a small positive value: anything under the poll interval is still faster
    /// than the app ever needs to poll.
    func test429WithTinyRetryAfterIsFlooredAtInterval() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 3)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 60)
    }

    func test429WithoutRetryAfterFallsBackToInterval() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: nil)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 60, "no Retry-After falls back to the normal interval")
    }

    func testSuccessfulPollResetsBackoff() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 600)))
        let coordinator = makeCoordinator(api: api)
        await coordinator.poll()
        XCTAssertEqual(coordinator.nextDelay, 600)

        api.usageResult = .success(usage(5))
        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 60, "a good poll restores the normal interval")
        XCTAssertEqual(coordinator.status, .live)
    }

    func testInteractionRequiredShowsKeychainDeniedWithoutPrompting() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(1)))
        let coordinator = makeCoordinator(api: api,
            token: FakeToken(result: .failure(KeychainError.interactionRequired)))

        await coordinator.poll()

        XCTAssertEqual(coordinator.status, .keychainDenied,
                       "a background read that needs a prompt shows the keychain state, no modal")
    }

    func testEstablishAccessGrantsThenPolls() async {
        let api = FakeAPI(profile: .success(emptyProfile()), usage: .success(usage(5)))
        let token = RecordingToken()
        let coordinator = makeCoordinator(api: api, token: token)

        await coordinator.establishAccess()

        XCTAssertEqual(token.establishCalls, 1)
        XCTAssertEqual(coordinator.status, .live, "after granting, the follow-up poll shows live data")
    }
}
