import XCTest
@testable import CCUsageMonitor

/// Smoke tests that prove the test target is wired to the app target and that the
/// version-tolerant models decode the live-probe fixture captured on 2026-06-16.
final class ScaffoldSmokeTests: XCTestCase {

    func testSystemClockReturnsNonDecreasingTime() {
        let clock = SystemClock()
        let first = clock.now()
        let second = clock.now()
        XCTAssertLessThanOrEqual(first, second)
    }

    func testUsageResponseDecodesProbeFixture() throws {
        let json = Data("""
        {
          "five_hour": {"utilization": 15.0, "resets_at": "2026-06-16T04:39:59.613563+00:00"},
          "seven_day": {"utilization": 11.0, "resets_at": "2026-06-18T03:59:59+00:00"},
          "seven_day_sonnet": {"utilization": 3.0, "resets_at": "2026-06-18T03:59:59+00:00"},
          "seven_day_opus": null,
          "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 0.0,
                          "utilization": null, "currency": "AUD", "decimal_places": 2,
                          "disabled_reason": null}
        }
        """.utf8)

        let usage = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 15.0)
        XCTAssertEqual(usage.sevenDaySonnet?.utilization, 3.0)
        XCTAssertEqual(usage.extraUsage?.currency, "AUD")
        XCTAssertEqual(usage.extraUsage?.monthlyLimit, 2000)
        XCTAssertEqual(usage.extraUsage?.decimalPlaces, 2)
        XCTAssertNil(usage.extraUsage?.utilization)
    }

    func testProfileResponseDecodesTier() throws {
        let json = Data("""
        {"account": {"full_name": "Shane Dolley", "has_claude_max": true},
         "organization": {"rate_limit_tier": "default_claude_max_20x"}}
        """.utf8)

        let profile = try JSONDecoder().decode(ProfileResponse.self, from: json)

        XCTAssertEqual(profile.organization?.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(profile.account?.hasClaudeMax, true)
    }
}
