import XCTest
import AppKit
@testable import CCUsageMonitor

final class MenuBarIconRendererTests: XCTestCase {

    func testTwoDonutsAreWiderThanOne() {
        let one = MenuBarIconRenderer.image(specs: [
            DonutSpec(label: "Current session", percent: 50, level: .normal),
        ], dimmed: false)
        let two = MenuBarIconRenderer.image(specs: [
            DonutSpec(label: "Current session", percent: 50, level: .normal),
            DonutSpec(label: "Weekly, all models", percent: 40, level: .normal),
        ], dimmed: false)

        XCTAssertGreaterThan(one.size.width, 0)
        XCTAssertGreaterThan(two.size.width, one.size.width, "a second donut adds width")
        XCTAssertEqual(two.size.height, 22, accuracy: 0.001, "icon fits the menu bar thickness")
    }

    func testRendersFullAndZeroAndOverHundredWithoutCrashing() {
        for percent in [0, 100, 137] {
            let image = MenuBarIconRenderer.image(specs: [
                DonutSpec(label: "Current session", percent: percent, level: .critical),
            ], dimmed: false)
            // Drawing actually runs when a representation is requested.
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                            "percent \(percent) renders")
        }
    }
}
