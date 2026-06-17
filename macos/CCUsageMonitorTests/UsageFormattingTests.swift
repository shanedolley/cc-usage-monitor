import XCTest
@testable import CCUsageMonitor

final class UsageFormattingTests: XCTestCase {

    func testPlanTierFormatting() {
        XCTAssertEqual(PlanTierFormatter.format("default_claude_max_20x"), "Max (20x)")
        XCTAssertEqual(PlanTierFormatter.format("default_claude_max_5x"), "Max (5x)")
        XCTAssertEqual(PlanTierFormatter.format("default_claude_pro"), "Pro")
    }

    func testUnknownTierRendersVerbatim() {
        XCTAssertEqual(PlanTierFormatter.format("some_weird_tier"), "some_weird_tier")
        XCTAssertEqual(PlanTierFormatter.format("max_tier"), "max_tier")
    }

    func testLevelThresholds() {
        XCTAssertEqual(UsageLevel.forUtilization(0), .normal)
        XCTAssertEqual(UsageLevel.forUtilization(79.9), .normal)
        XCTAssertEqual(UsageLevel.forUtilization(80), .warning)
        XCTAssertEqual(UsageLevel.forUtilization(89.9), .warning)
        XCTAssertEqual(UsageLevel.forUtilization(90), .critical)
        XCTAssertEqual(UsageLevel.forUtilization(100), .critical)
    }
}
