import XCTest
@testable import CCUsageMonitor

final class CreditsFormatterTests: XCTestCase {

    private func extra(_ json: String) -> ExtraUsage {
        try! JSONDecoder().decode(ExtraUsage.self, from: Data(json.utf8))
    }

    func testAudWithTwoDecimalPlaces() {
        let display = CreditsFormatter.format(extra(
            #"{"is_enabled":true,"monthly_limit":2000,"used_credits":0.0,"currency":"AUD","decimal_places":2}"#))
        XCTAssertEqual(display.limit, "A$20.00")
        XCTAssertEqual(display.spent, "A$0.00")
        XCTAssertFalse(display.isDisabled)
    }

    func testZeroDecimalPlaces() {
        let display = CreditsFormatter.format(extra(
            #"{"is_enabled":true,"monthly_limit":2000,"used_credits":150,"currency":"JPY","decimal_places":0}"#))
        XCTAssertEqual(display.limit, "JPY 2000")
        XCTAssertEqual(display.spent, "JPY 150")
    }

    func testUnknownCurrencyShowsCodePrefix() {
        let display = CreditsFormatter.format(extra(
            #"{"is_enabled":true,"monthly_limit":1000,"used_credits":5.5,"currency":"XYZ","decimal_places":2}"#))
        XCTAssertEqual(display.limit, "XYZ 10.00")
        XCTAssertEqual(display.spent, "XYZ 5.50")
    }

    func testDisabledCreditsCarryReason() {
        let display = CreditsFormatter.format(extra(
            #"{"is_enabled":false,"monthly_limit":2000,"currency":"AUD","decimal_places":2,"disabled_reason":"turned off"}"#))
        XCTAssertTrue(display.isDisabled)
        XCTAssertEqual(display.disabledReason, "turned off")
    }
}
