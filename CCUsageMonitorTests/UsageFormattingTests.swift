import XCTest
@testable import CCUsageMonitor

final class UsageFormattingTests: XCTestCase {

    private func usage(_ json: String) -> UsageResponse {
        try! JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

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

    func testHighestMetricSelection() {
        let result = UsageMetricSummary.highestMetric(usage(
            #"{"five_hour":{"utilization":10},"seven_day":{"utilization":42},"seven_day_sonnet":{"utilization":5}}"#))
        XCTAssertEqual(result?.name, "Weekly, all models")
        XCTAssertEqual(result?.utilization, 42)
    }

    func testHighestMetricIgnoresNulls() {
        let result = UsageMetricSummary.highestMetric(usage(
            #"{"five_hour":{"utilization":7},"seven_day":null}"#))
        XCTAssertEqual(result?.name, "Current session")
        XCTAssertEqual(result?.utilization, 7)
    }

    func testHighestMetricNilWhenNoData() {
        XCTAssertNil(UsageMetricSummary.highestMetric(usage("{}")))
    }
}
