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
    func validAccessToken() async throws -> String { try result.get() }
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
}
