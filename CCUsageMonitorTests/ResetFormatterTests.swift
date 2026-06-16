import XCTest
@testable import CCUsageMonitor

final class ResetFormatterTests: XCTestCase {

    func testParsesWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(ResetFormatter.parse("2026-06-16T04:39:59.613563+00:00"))
        XCTAssertNotNil(ResetFormatter.parse("2026-06-18T03:59:59+00:00"))
        XCTAssertNil(ResetFormatter.parse("not a date"))
    }

    func testRelativeUnderTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 0)
        let resets = now.addingTimeInterval(2 * 3600 + 55 * 60)   // 2 hr 55 min
        XCTAssertEqual(ResetFormatter.format(resetsAt: resets, now: now), "Resets in 2 hr 55 min")
    }

    func testRelativeMinutesOnly() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ResetFormatter.format(resetsAt: now.addingTimeInterval(40 * 60), now: now),
                       "Resets in 40 min")
    }

    func testPastResetsNow() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ResetFormatter.format(resetsAt: Date(timeIntervalSince1970: 0), now: now), "Resets now")
    }

    func testAbsoluteBeyondTwentyFourHours() {
        let now = ResetFormatter.parse("2026-06-16T00:00:00+00:00")!
        let resets = ResetFormatter.parse("2026-06-18T13:59:00+00:00")!   // > 24h ahead
        let result = ResetFormatter.format(resetsAt: resets, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(result.hasPrefix("Resets "))
        XCTAssertTrue(result.contains("1:59 PM"), "got: \(result)")
    }
}
