import XCTest
@testable import CCUsageMonitor

private final class NoopNotificationService: NotificationServiceProtocol, @unchecked Sendable {
    func requestAuthorization() async -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func fire(id: String, title: String, body: String) async {}
    func cancel(id: String) async {}
}

final class RuleInputTests: XCTestCase {

    func testEmptyTextIsEmptyValidation() {
        XCTAssertEqual(RuleInput.validateThreshold(""), .empty)
        XCTAssertEqual(RuleInput.validateThreshold("   "), .empty)
    }

    func testNonNumberIsInvalid() {
        XCTAssertEqual(RuleInput.validateThreshold("abc"), .invalid("Enter a whole number"))
        XCTAssertEqual(RuleInput.validateThreshold("8.5"), .invalid("Enter a whole number"))
    }

    func testOutOfRangeIsInvalid() {
        XCTAssertEqual(RuleInput.validateThreshold("0"), .invalid("Use a value from 1 to 99"))
        XCTAssertEqual(RuleInput.validateThreshold("100"), .invalid("Use a value from 1 to 99"))
    }

    func testValidRange() {
        XCTAssertEqual(RuleInput.validateThreshold("1"), .valid(1))
        XCTAssertEqual(RuleInput.validateThreshold("99"), .valid(99))
        XCTAssertEqual(RuleInput.validateThreshold(" 42 "), .valid(42))
    }

    func testValidationValueAccessor() {
        XCTAssertEqual(ThresholdValidation.valid(50).value, 50)
        XCTAssertNil(ThresholdValidation.invalid("x").value)
        XCTAssertNil(ThresholdValidation.empty.value)
    }

    func testStatusLabel() {
        XCTAssertEqual(RuleStatus.label(armed: true), "Watching")
        XCTAssertEqual(RuleStatus.label(armed: false), "Triggered")
    }

    @MainActor
    func testValidThresholdAddsRuleAndInvalidDoesNot() {
        let engine = RulesEngine(notificationService: NoopNotificationService())

        if case let .valid(value) = RuleInput.validateThreshold("80") {
            engine.addRule(metric: .fiveHour, threshold: value)
        }
        XCTAssertEqual(engine.rules.count, 1, "a valid threshold adds a rule")

        if case let .valid(value) = RuleInput.validateThreshold("0") {
            engine.addRule(metric: .sevenDay, threshold: value)
        }
        XCTAssertEqual(engine.rules.count, 1, "an invalid threshold never reaches the engine")
    }
}
