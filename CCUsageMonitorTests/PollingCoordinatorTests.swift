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

    func test429SetsBackoffCappedAtFiveMinutes() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 600)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 300, "Retry-After is capped at 5 minutes")
    }

    func test429HonorsRetryAfterUnderCap() async {
        let api = FakeAPI(profile: .success(emptyProfile()),
                          usage: .failure(APIError.rateLimited(retryAfter: 120)))
        let coordinator = makeCoordinator(api: api)

        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 120)
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
        XCTAssertEqual(coordinator.nextDelay, 300)

        api.usageResult = .success(usage(5))
        await coordinator.poll()

        XCTAssertEqual(coordinator.nextDelay, 60, "a good poll restores the normal interval")
        XCTAssertEqual(coordinator.status, .live)
    }
}
