import Foundation

/// The usage window a notification rule watches. The raw values match the API's metric keys, so
/// a persisted rule maps back to a `UsageResponse` field without a separate lookup table.
enum RuleMetric: String, Codable, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"

    /// The label shown in the rules UI and in the fired notification.
    var displayName: String {
        switch self {
        case .fiveHour: return "Current Session"
        case .sevenDay: return "Weekly, All Models"
        case .sevenDaySonnet: return "Weekly, Sonnet"
        }
    }
}

/// A user threshold alert: notify when `metric` reaches `threshold` percent.
///
/// Only `id`, `metric`, and `threshold` persist. `armed` and `lastFiredAt` are runtime state that
/// the rules engine rebuilds from the first poll after launch, so they stay out of the encoded form
/// (see `CodingKeys`).
struct NotificationRule: Identifiable, Codable {
    let id: String
    let metric: RuleMetric
    let threshold: Int

    var armed: Bool = true
    var lastFiredAt: Date?

    /// Valid thresholds run from 1 to 99. The engine treats 0 and 100 as never crossing, so it
    /// rejects them outright rather than storing a rule that can never fire.
    static let thresholdRange = 1...99

    /// Returns nil when `threshold` falls outside `thresholdRange`, which keeps an invalid rule from
    /// ever existing.
    init?(id: String = UUID().uuidString, metric: RuleMetric, threshold: Int) {
        guard NotificationRule.thresholdRange.contains(threshold) else { return nil }
        self.id = id
        self.metric = metric
        self.threshold = threshold
    }

    /// Re-checks the range on decode so a stale or hand-edited persisted rule with an
    /// out-of-range threshold is rejected, not loaded into a state that fires on every poll and
    /// never re-arms. `armed` and `lastFiredAt` keep their declared runtime defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedThreshold = try container.decode(Int.self, forKey: .threshold)
        guard NotificationRule.thresholdRange.contains(decodedThreshold) else {
            throw DecodingError.dataCorruptedError(
                forKey: .threshold, in: container,
                debugDescription: "threshold \(decodedThreshold) is outside \(NotificationRule.thresholdRange)")
        }
        id = try container.decode(String.self, forKey: .id)
        metric = try container.decode(RuleMetric.self, forKey: .metric)
        threshold = decodedThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, threshold
    }
}
