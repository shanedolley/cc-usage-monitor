import XCTest
@testable import CCUsageMonitor

private final class SpyNotificationService: NotificationServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _fireCount = 0
    var fireCount: Int { lock.lock(); defer { lock.unlock() }; return _fireCount }

    func requestAuthorization() async -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func fire(id: String, title: String, body: String) async { increment() }
    func cancel(id: String) async {}

    private func increment() { lock.lock(); _fireCount += 1; lock.unlock() }
}

private func usage(fiveHour: Double) -> UsageResponse {
    UsageResponse(fiveHour: UsageMetric(utilization: fiveHour, resetsAt: nil),
                  sevenDay: nil, sevenDaySonnet: nil, extraUsage: nil)
}

@MainActor
final class UsageRulesBridgeTests: XCTestCase {

    func testFirstPollOnlyArmsAndDoesNotFire() async {
        let service = SpyNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        let bridge = UsageRulesBridge(engine: engine)

        await bridge.handle(usage: usage(fiveHour: 95))   // already over: first poll only arms
        XCTAssertEqual(service.fireCount, 0, "the first poll arms, it never fires")
    }

    func testLaterPollEvaluatesAndFiresOnCrossing() async {
        let service = SpyNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        let bridge = UsageRulesBridge(engine: engine)

        await bridge.handle(usage: usage(fiveHour: 10))   // first poll: below, armed
        await bridge.handle(usage: usage(fiveHour: 90))   // later poll: crosses, fires
        XCTAssertEqual(service.fireCount, 1)
    }

    func testAlreadyOverAtFirstPollStaysSilentUntilReArmed() async {
        let service = SpyNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        let bridge = UsageRulesBridge(engine: engine)

        await bridge.handle(usage: usage(fiveHour: 95))   // first poll: disarmed
        await bridge.handle(usage: usage(fiveHour: 95))   // still over, disarmed
        XCTAssertEqual(service.fireCount, 0)

        await bridge.handle(usage: usage(fiveHour: 50))   // drops below, re-arms
        await bridge.handle(usage: usage(fiveHour: 85))   // crosses, fires
        XCTAssertEqual(service.fireCount, 1)
    }
}
