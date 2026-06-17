import Foundation

/// Connects the poll loop to the rules engine. The first successful poll only arms the rules, so a
/// metric already over its threshold at launch does not alert for a state that predates the app.
/// Every later poll evaluates and fires.
@MainActor
final class UsageRulesBridge {
    private let engine: RulesEngine
    private var hasArmed = false

    init(engine: RulesEngine) {
        self.engine = engine
    }

    /// Feeds one poll's usage to the engine: arm on the first call, evaluate on the rest.
    func handle(usage: UsageResponse) async {
        if hasArmed {
            await engine.evaluate(usage: usage)
        } else {
            engine.initializeArmedState(from: usage)
            hasArmed = true
        }
    }
}
