import XCTest
@testable import CCUsageMonitor

final class MenuBarPresenterTests: XCTestCase {

    private func snapshot(_ usageJSON: String) -> UsageSnapshot {
        let usage = try! JSONDecoder().decode(UsageResponse.self, from: Data(usageJSON.utf8))
        let profile = try! JSONDecoder().decode(ProfileResponse.self, from: Data("{}".utf8))
        return UsageSnapshot(profile: profile, usage: usage, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    func testLiveShowsSessionThenWeeklyDonuts() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"five_hour":{"utilization":83},"seven_day":{"utilization":40}}"#),
            status: .live)
        XCTAssertEqual(model.content, .donuts(specs: [
            DonutSpec(label: "Current session", percent: 83, level: .warning),
            DonutSpec(label: "Weekly, all models", percent: 40, level: .normal),
        ], dimmed: false))
        XCTAssertEqual(model.level, .warning, "overall level is the most severe donut")
        XCTAssertTrue(model.tooltip.contains("Current session 83%"))
        XCTAssertTrue(model.tooltip.contains("Weekly, all models 40%"))
    }

    func testRoundsPercentForTheNumberInside() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"five_hour":{"utilization":12.6}}"#), status: .live)
        XCTAssertEqual(model.content, .donuts(specs: [
            DonutSpec(label: "Current session", percent: 13, level: .normal),
        ], dimmed: false))
    }

    func testWeeklyAloneStillRendersWhenSessionMissing() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"seven_day":{"utilization":95}}"#), status: .live)
        XCTAssertEqual(model.content, .donuts(specs: [
            DonutSpec(label: "Weekly, all models", percent: 95, level: .critical),
        ], dimmed: false))
        XCTAssertEqual(model.level, .critical)
    }

    func testStaleDimsTheDonutsAndAnnotatesTooltip() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"five_hour":{"utilization":50}}"#), status: .stale)
        XCTAssertEqual(model.content, .donuts(specs: [
            DonutSpec(label: "Current session", percent: 50, level: .normal),
        ], dimmed: true))
        XCTAssertTrue(model.tooltip.contains("stale"))
    }

    func testNoMetricsFallsBackToDash() {
        let model = MenuBarPresenter.render(snapshot: snapshot("{}"), status: .live)
        XCTAssertEqual(model.content, .glyph("—"))
    }

    func testReauthenticateShowsBangGlyph() {
        let model = MenuBarPresenter.render(snapshot: nil, status: .reauthenticate)
        XCTAssertEqual(model.content, .glyph("!"))
        XCTAssertEqual(model.level, .critical)
    }

    func testLoadingShowsEllipsisGlyph() {
        let model = MenuBarPresenter.render(snapshot: nil, status: .loading)
        XCTAssertEqual(model.content, .glyph("…"))
    }
}
