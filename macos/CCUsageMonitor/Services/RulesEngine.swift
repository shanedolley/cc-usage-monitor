import Foundation
import Combine

/// Evaluates usage against the user's threshold rules and fires a notification when a metric
/// crosses from below to at-or-above a threshold.
///
/// De-duplication keeps one crossing to one notification. Each rule carries an `armed` flag:
/// firing disarms it, and only a strict drop below the threshold re-arms it. A rule that is already
/// over its threshold at launch starts disarmed (`initializeArmedState`), so the user is not alerted
/// for a state that predates the app.
///
/// `rules` is `@Published` so the management UI re-renders as rules are added, removed, or change
/// armed state.
@MainActor
final class RulesEngine: ObservableObject {
    @Published private(set) var rules: [NotificationRule] = []
    private let notificationService: NotificationServiceProtocol

    init(notificationService: NotificationServiceProtocol) {
        self.notificationService = notificationService
    }

    /// Replaces the rule set, for loading persisted rules. Every loaded rule starts armed; call
    /// `initializeArmedState` after the first poll to disarm any that are already over threshold.
    func setRules(_ rules: [NotificationRule]) {
        self.rules = rules
    }

    /// Adds a rule with a generated id. Returns the new rule, or nil if `threshold` is outside
    /// `NotificationRule.thresholdRange`.
    ///
    /// Pass `currentUsage` when adding at runtime: a rule whose metric is already at or above its
    /// threshold starts disarmed, so adding it does not fire an alert for a state that predates it.
    @discardableResult
    func addRule(metric: RuleMetric, threshold: Int, currentUsage: UsageResponse? = nil) -> NotificationRule? {
        guard var rule = NotificationRule(metric: metric, threshold: threshold) else { return nil }
        if let usage = currentUsage, let value = utilization(for: metric, in: usage) {
            rule.armed = value < Double(threshold)
        }
        rules.append(rule)
        return rule
    }

    /// Removes a rule and cancels any notification it left pending.
    func removeRule(id: String) async {
        rules.removeAll { $0.id == id }
        await notificationService.cancel(id: id)
    }

    /// Sets each rule's initial armed state from the first poll. A rule at or above its threshold
    /// starts disarmed; a rule below it starts armed. A metric with no value keeps the default.
    func initializeArmedState(from usage: UsageResponse) {
        for index in rules.indices {
            if let value = utilization(for: rules[index].metric, in: usage) {
                rules[index].armed = value < Double(rules[index].threshold)
            }
        }
    }

    /// Evaluates every rule against the latest usage. Fires the rules that just crossed to
    /// at-or-above while armed, and re-arms any rule that dropped strictly below its threshold.
    ///
    /// State changes apply synchronously before any notification fires, so a re-entrant call during
    /// the async `fire` cannot act on a stale `rules` index.
    func evaluate(usage: UsageResponse) async {
        var pending: [(rule: NotificationRule, utilization: Double)] = []
        // Index iteration is deliberate: NotificationRule is a value type, so `rules[index].armed =`
        // mutates the stored element in place. A `for rule in rules` loop would mutate a copy.
        for index in rules.indices {
            // A nil value (metric absent, or present without a utilization) gives nothing to
            // compare, so the rule is skipped and its armed state left unchanged.
            guard let value = utilization(for: rules[index].metric, in: usage) else { continue }
            if value >= Double(rules[index].threshold) {
                if rules[index].armed {
                    rules[index].armed = false
                    rules[index].lastFiredAt = Date()
                    pending.append((rules[index], value))
                }
            } else {
                rules[index].armed = true
            }
        }
        for item in pending {
            // A rule removed during an earlier fire in this pass must not still alert.
            guard rules.contains(where: { $0.id == item.rule.id }) else { continue }
            await fire(rule: item.rule, utilization: item.utilization)
        }
    }

    private func fire(rule: NotificationRule, utilization: Double) async {
        let title = "\(rule.metric.displayName) at \(Int(utilization.rounded()))%"
        let body = "Usage reached your \(rule.threshold)% alert."
        await notificationService.fire(id: rule.id, title: title, body: body)
    }

    private func utilization(for metric: RuleMetric, in usage: UsageResponse) -> Double? {
        switch metric {
        case .fiveHour: return usage.fiveHour?.utilization
        case .sevenDay: return usage.sevenDay?.utilization
        case .sevenDaySonnet: return usage.sevenDaySonnet?.utilization
        }
    }
}
