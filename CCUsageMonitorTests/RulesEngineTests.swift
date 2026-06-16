import XCTest
@testable import CCUsageMonitor

// MARK: - Test doubles

private final class FakeNotificationService: NotificationServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _fires: [(id: String, title: String, body: String)] = []
    private var _cancels: [String] = []

    var fires: [(id: String, title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }; return _fires
    }
    var cancels: [String] {
        lock.lock(); defer { lock.unlock() }; return _cancels
    }

    /// Optional hook run after each fire is recorded, so a test can mutate the engine mid-pass.
    var onFire: ((String) async -> Void)?

    func requestAuthorization() async -> Bool { true }
    func isAuthorized() async -> Bool { true }

    func fire(id: String, title: String, body: String) async {
        record(fire: (id, title, body))
        await onFire?(id)
    }
    func cancel(id: String) async {
        record(cancel: id)
    }

    // Locking lives in synchronous helpers; NSLock is unavailable from an async context.
    private func record(fire: (id: String, title: String, body: String)) {
        lock.lock(); _fires.append(fire); lock.unlock()
    }
    private func record(cancel id: String) {
        lock.lock(); _cancels.append(id); lock.unlock()
    }
}

private func usage(fiveHour: Double? = nil,
                   sevenDay: Double? = nil,
                   sevenDaySonnet: Double? = nil) -> UsageResponse {
    func metric(_ value: Double?) -> UsageMetric? {
        value.map { UsageMetric(utilization: $0, resetsAt: nil) }
    }
    return UsageResponse(fiveHour: metric(fiveHour),
                         sevenDay: metric(sevenDay),
                         sevenDaySonnet: metric(sevenDaySonnet),
                         extraUsage: nil)
}

// MARK: - Tests

@MainActor
final class RulesEngineTests: XCTestCase {

    func testFiresOnceOnCrossingAndStaysSilentWhileAbove() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 50))

        await engine.evaluate(usage: usage(fiveHour: 85))
        XCTAssertEqual(service.fires.count, 1)

        await engine.evaluate(usage: usage(fiveHour: 90))
        XCTAssertEqual(service.fires.count, 1, "stays silent while still above")
    }

    func testReArmsOnStrictDropBelow() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .sevenDay, threshold: 80)
        engine.initializeArmedState(from: usage(sevenDay: 10))

        await engine.evaluate(usage: usage(sevenDay: 85))   // fires
        await engine.evaluate(usage: usage(sevenDay: 70))   // drops below, re-arms
        await engine.evaluate(usage: usage(sevenDay: 95))   // fires again
        XCTAssertEqual(service.fires.count, 2)
    }

    func testRuleAlreadyOverAtLaunchStartsDisarmed() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 90))   // already over, starts disarmed

        await engine.evaluate(usage: usage(fiveHour: 92))
        XCTAssertEqual(service.fires.count, 0, "no alert for a state that predates launch")

        await engine.evaluate(usage: usage(fiveHour: 70))   // drops below, re-arms
        await engine.evaluate(usage: usage(fiveHour: 88))   // now fires
        XCTAssertEqual(service.fires.count, 1)
    }

    func testFiresExactlyAtThreshold() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 0))

        await engine.evaluate(usage: usage(fiveHour: 80))
        XCTAssertEqual(service.fires.count, 1, "at-or-above the threshold is inclusive")
    }

    func testInitializeAtExactThresholdStartsDisarmed() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 80))

        await engine.evaluate(usage: usage(fiveHour: 80))
        XCTAssertEqual(service.fires.count, 0)
    }

    func testInvalidThresholdRejected() {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        XCTAssertNil(engine.addRule(metric: .fiveHour, threshold: 0))
        XCTAssertNil(engine.addRule(metric: .fiveHour, threshold: 100))
        XCTAssertTrue(engine.rules.isEmpty)
        XCTAssertNotNil(engine.addRule(metric: .fiveHour, threshold: 1))
        XCTAssertNotNil(engine.addRule(metric: .fiveHour, threshold: 99))
        XCTAssertEqual(engine.rules.count, 2)
    }

    func testFireUsesRuleIdAsIdentifier() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        let rule = engine.addRule(metric: .sevenDaySonnet, threshold: 75)!
        engine.initializeArmedState(from: usage(sevenDaySonnet: 0))

        await engine.evaluate(usage: usage(sevenDaySonnet: 80))
        XCTAssertEqual(service.fires.first?.id, rule.id)
        XCTAssertTrue(service.fires.first?.title.contains("Weekly, Sonnet") ?? false)
    }

    func testRemovingRuleCancelsItsNotification() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        let rule = engine.addRule(metric: .fiveHour, threshold: 50)!

        await engine.removeRule(id: rule.id)
        XCTAssertTrue(engine.rules.isEmpty)
        XCTAssertEqual(service.cancels, [rule.id])
    }

    func testMissingMetricDataIsSkipped() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 10))

        await engine.evaluate(usage: usage(sevenDay: 99))   // no five_hour value present
        XCTAssertEqual(service.fires.count, 0, "a missing metric neither fires nor changes arming")
    }

    func testRulesAreIndependent() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        let session = engine.addRule(metric: .fiveHour, threshold: 80)!
        engine.addRule(metric: .sevenDay, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 0, sevenDay: 0))

        await engine.evaluate(usage: usage(fiveHour: 90, sevenDay: 10))
        XCTAssertEqual(service.fires.count, 1)
        XCTAssertEqual(service.fires.first?.id, session.id)
    }

    func testSetRulesReplacesExistingRules() {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        let loaded = [NotificationRule(metric: .sevenDay, threshold: 60)!]

        engine.setRules(loaded)
        XCTAssertEqual(engine.rules.map(\.id), loaded.map(\.id))
    }

    func testAddingRuleWhileAlreadyOverStartsDisarmed() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80, currentUsage: usage(fiveHour: 95))

        await engine.evaluate(usage: usage(fiveHour: 95))
        XCTAssertEqual(service.fires.count, 0, "a rule added while already over waits until it re-arms")

        await engine.evaluate(usage: usage(fiveHour: 70))   // drops below, re-arms
        await engine.evaluate(usage: usage(fiveHour: 90))   // now fires
        XCTAssertEqual(service.fires.count, 1)
    }

    func testPresentMetricWithoutUtilizationIsSkipped() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        engine.addRule(metric: .fiveHour, threshold: 80)
        engine.initializeArmedState(from: usage(fiveHour: 10))

        // The five_hour object is present but its utilization is nil (a version-tolerant parse).
        let partial = UsageResponse(fiveHour: UsageMetric(utilization: nil, resetsAt: "x"),
                                    sevenDay: nil, sevenDaySonnet: nil, extraUsage: nil)
        await engine.evaluate(usage: partial)
        XCTAssertEqual(service.fires.count, 0, "no value means no comparison and no arming change")
    }

    func testNotificationSkippedWhenRuleRemovedMidEvaluate() async {
        let service = FakeNotificationService()
        let engine = RulesEngine(notificationService: service)
        let first = engine.addRule(metric: .fiveHour, threshold: 80)!
        let second = engine.addRule(metric: .sevenDay, threshold: 80)!
        engine.initializeArmedState(from: usage(fiveHour: 0, sevenDay: 0))

        // Delete the second rule while the first one is firing, before the engine reaches it.
        service.onFire = { firedId in
            if firedId == first.id { await engine.removeRule(id: second.id) }
        }

        await engine.evaluate(usage: usage(fiveHour: 90, sevenDay: 90))
        XCTAssertEqual(service.fires.map(\.id), [first.id], "the rule deleted mid-pass does not fire")
    }

    func testDecodingRejectsOutOfRangeThreshold() {
        let low = Data(#"{"id":"a","metric":"five_hour","threshold":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NotificationRule.self, from: low))
        let high = Data(#"{"id":"a","metric":"five_hour","threshold":100}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NotificationRule.self, from: high))
    }

    func testEncodeOmitsRuntimeStateAndDecodeRestoresDefaults() throws {
        var rule = NotificationRule(metric: .fiveHour, threshold: 80)!
        rule.armed = false
        rule.lastFiredAt = Date()

        let data = try JSONEncoder().encode(rule)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("armed"), "armed is runtime-only and must not persist")
        XCTAssertFalse(json.contains("lastFiredAt"), "lastFiredAt is runtime-only and must not persist")

        let restored = try JSONDecoder().decode(NotificationRule.self, from: data)
        XCTAssertTrue(restored.armed, "armed resets to its runtime default on load")
        XCTAssertNil(restored.lastFiredAt)
    }
}
