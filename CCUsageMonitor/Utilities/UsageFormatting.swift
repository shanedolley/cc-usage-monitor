import Foundation

/// Color-coding level for a utilization value. Always paired with a number or label in the
/// UI, so color is never the only signal (NFR-006).
enum UsageLevel: Equatable {
    case normal, warning, critical

    /// Fixed v1 thresholds: amber at 80, red at 90.
    static func forUtilization(_ percent: Double) -> UsageLevel {
        if percent >= 90 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }
}

/// Renders `organization.rate_limit_tier` into a display string.
enum PlanTierFormatter {
    /// "default_claude_max_20x" -> "Max (20x)"; "default_claude_pro" -> "Pro"; anything that
    /// does not match the known shape renders verbatim rather than blank.
    static func format(_ raw: String) -> String {
        var stripped = raw
        for prefix in ["default_claude_", "default_"] where stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
        let parts = stripped.split(separator: "_")
        guard let plan = parts.first else { return raw }
        let name = plan.prefix(1).uppercased() + plan.dropFirst()

        if parts.count == 1 {
            return name
        }
        if parts.count == 2, let multiplier = parts.last, isMultiplier(multiplier) {
            return "\(name) (\(multiplier))"
        }
        return raw   // unrecognized shape
    }

    private static func isMultiplier(_ token: Substring) -> Bool {
        guard token.hasSuffix("x") else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

/// Summaries across the three limit metrics.
enum UsageMetricSummary {
    /// The most-used metric across current session and the two weekly limits, for the
    /// glanceable menu bar readout.
    static func highestMetric(_ usage: UsageResponse) -> (name: String, utilization: Double)? {
        let candidates: [(String, Double?)] = [
            ("Current session", usage.fiveHour?.utilization),
            ("Weekly, all models", usage.sevenDay?.utilization),
            ("Weekly, Sonnet", usage.sevenDaySonnet?.utilization),
        ]
        return candidates
            .compactMap { name, value in value.map { (name, $0) } }
            .max { $0.1 < $1.1 }
    }

    static func highestUtilization(_ usage: UsageResponse) -> Double? {
        highestMetric(usage)?.utilization
    }
}
