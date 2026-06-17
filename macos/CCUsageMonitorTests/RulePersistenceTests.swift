import XCTest
@testable import CCUsageMonitor

final class RulePersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RulePersistenceTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> RulePersistence { RulePersistence(directory: directory) }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("notification-rules.json"))
    }

    func testMissingFileReturnsEmpty() throws {
        XCTAssertEqual(try makeStore().loadRules().count, 0)
    }

    func testEmptyFileReturnsEmpty() throws {
        try write("")
        XCTAssertEqual(try makeStore().loadRules().count, 0)
    }

    func testRulesRoundTrip() throws {
        let store = makeStore()
        let rules = [NotificationRule(id: "a", metric: .fiveHour, threshold: 80)!,
                     NotificationRule(id: "b", metric: .sevenDaySonnet, threshold: 50)!]
        try store.saveRules(rules)

        let loaded = try store.loadRules()
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded.map(\.metric), [.fiveHour, .sevenDaySonnet])
        XCTAssertEqual(loaded.map(\.threshold), [80, 50])
    }

    func testArmedStateNotPersisted() throws {
        let store = makeStore()
        var rule = NotificationRule(id: "a", metric: .fiveHour, threshold: 80)!
        rule.armed = false
        rule.lastFiredAt = Date()
        try store.saveRules([rule])

        let json = try String(contentsOf: directory.appendingPathComponent("notification-rules.json"),
                              encoding: .utf8)
        XCTAssertFalse(json.contains("armed"), "armed is runtime-only and must not persist")
        XCTAssertFalse(json.contains("lastFiredAt"))

        let loaded = try store.loadRules()
        XCTAssertEqual(loaded.first?.armed, true, "armed is always re-derived, never loaded")
    }

    func testUnknownMetricAndInvalidThresholdDropped() throws {
        try write("""
        [
          {"id":"good","metric":"five_hour","threshold":80},
          {"id":"bad-metric","metric":"yearly","threshold":50},
          {"id":"bad-threshold","metric":"seven_day","threshold":0}
        ]
        """)

        let loaded = try makeStore().loadRules()
        XCTAssertEqual(loaded.map(\.id), ["good"], "unknown metric and out-of-range threshold drop individually")
    }

    func testSaveCreatesMissingDirectory() throws {
        let nested = directory.appendingPathComponent("nested").appendingPathComponent("deeper")
        let store = RulePersistence(directory: nested)
        try store.saveRules([NotificationRule(id: "a", metric: .fiveHour, threshold: 80)!])
        XCTAssertEqual(try store.loadRules().map(\.id), ["a"])
    }
}
