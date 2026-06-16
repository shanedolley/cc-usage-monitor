import XCTest
@testable import CCUsageMonitor

final class MenuBarPresenterTests: XCTestCase {

    private func snapshot(_ usageJSON: String) -> UsageSnapshot {
        let usage = try! JSONDecoder().decode(UsageResponse.self, from: Data(usageJSON.utf8))
        let profile = try! JSONDecoder().decode(ProfileResponse.self, from: Data("{}".utf8))
        return UsageSnapshot(profile: profile, usage: usage, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    func testLiveShowsHighestPercentAndLevel() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"five_hour":{"utilization":83},"seven_day":{"utilization":40}}"#),
            status: .live)
        XCTAssertEqual(model.title, "83%")
        XCTAssertEqual(model.level, .warning)
        XCTAssertTrue(model.tooltip.contains("Current session"))
    }

    func testReauthenticateShowsBang() {
        let model = MenuBarPresenter.render(snapshot: nil, status: .reauthenticate)
        XCTAssertEqual(model.title, "!")
        XCTAssertEqual(model.level, .critical)
    }

    func testLoadingShowsEllipsis() {
        let model = MenuBarPresenter.render(snapshot: nil, status: .loading)
        XCTAssertEqual(model.title, "…")
    }

    func testStaleAnnotatesTooltip() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"five_hour":{"utilization":50}}"#), status: .stale)
        XCTAssertEqual(model.title, "50%")
        XCTAssertTrue(model.tooltip.contains("stale"))
    }

    func testCriticalAtNinety() {
        let model = MenuBarPresenter.render(
            snapshot: snapshot(#"{"seven_day":{"utilization":95}}"#), status: .live)
        XCTAssertEqual(model.title, "95%")
        XCTAssertEqual(model.level, .critical)
    }
}
