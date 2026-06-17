import XCTest
import UserNotifications
@testable import CCUsageMonitor

// MARK: - Test double

/// A fake notification center that records what the service asks of it, so the service's logic is
/// tested without the system framework or a real authorization prompt. `@unchecked Sendable` is
/// safe here: each test owns its instance and drives it sequentially with `await`, so the mutable
/// records are never touched concurrently.
private final class FakeCenter: UserNotificationCentering, @unchecked Sendable {
    var authorizationGranted = true
    var authorizationError: Error?
    var status: UNAuthorizationStatus = .authorized

    private(set) var requestedOptions: UNAuthorizationOptions?
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        if let authorizationError { throw authorizationError }
        return authorizationGranted
    }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
    func removePending(identifiers: [String]) { removedPending.append(contentsOf: identifiers) }
    func removeDelivered(identifiers: [String]) { removedDelivered.append(contentsOf: identifiers) }
}

private struct FakeError: Error {}

// MARK: - Tests

final class NotificationServiceTests: XCTestCase {

    func testRequestAuthorizationReturnsGrant() async {
        let center = FakeCenter()   // authorizationGranted defaults to true
        let service = NotificationService(center: center)

        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(center.requestedOptions, [.alert, .sound])
    }

    func testRequestAuthorizationReturnsFalseWhenDenied() async {
        let center = FakeCenter()
        center.authorizationGranted = false
        let service = NotificationService(center: center)

        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
    }

    func testRequestAuthorizationReturnsFalseOnError() async {
        let center = FakeCenter()
        center.authorizationError = FakeError()
        let service = NotificationService(center: center)

        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted, "a thrown authorization error is treated as not granted")
    }

    func testIsAuthorizedTrueForAuthorizedAndProvisional() async {
        let center = FakeCenter()
        let service = NotificationService(center: center)

        center.status = .authorized
        let authorized = await service.isAuthorized()
        XCTAssertTrue(authorized)

        center.status = .provisional
        let provisional = await service.isAuthorized()
        XCTAssertTrue(provisional)
    }

    func testIsAuthorizedFalseForDeniedAndNotDetermined() async {
        let center = FakeCenter()
        let service = NotificationService(center: center)

        center.status = .denied
        let denied = await service.isAuthorized()
        XCTAssertFalse(denied)

        center.status = .notDetermined
        let notDetermined = await service.isAuthorized()
        XCTAssertFalse(notDetermined)
    }

    func testFireBuildsRequestWithGivenContent() async {
        let center = FakeCenter()
        let service = NotificationService(center: center)

        await service.fire(id: "rule-1", title: "Current Session at 80%", body: "Usage reached your 80% alert.")

        XCTAssertEqual(center.added.count, 1)
        let request = center.added.first
        XCTAssertEqual(request?.identifier, "rule-1")
        XCTAssertEqual(request?.content.title, "Current Session at 80%")
        XCTAssertEqual(request?.content.body, "Usage reached your 80% alert.")
        XCTAssertNotNil(request?.content.sound)
        XCTAssertNil(request?.trigger, "the notification is delivered immediately")
    }

    func testCancelRemovesPendingAndDelivered() async {
        let center = FakeCenter()
        let service = NotificationService(center: center)

        await service.cancel(id: "rule-1")
        XCTAssertEqual(center.removedPending, ["rule-1"])
        XCTAssertEqual(center.removedDelivered, ["rule-1"])
    }

    func testNotificationClickPostsOpenDetailWindow() {
        let service = NotificationService(center: FakeCenter())
        let posted = expectation(forNotification: .openDetailWindow, object: nil)

        service.handleNotificationClick()
        wait(for: [posted], timeout: 1)
    }
}
