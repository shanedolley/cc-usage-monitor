import Foundation

/// Response of `GET /api/oauth/profile`. All fields are optional for version-tolerant
/// parsing (see PRD "Version-Tolerant Parsing"); a schema change degrades, never crashes.
struct ProfileResponse: Decodable, Equatable {
    var account: Account?
    var organization: Organization?

    struct Account: Decodable, Equatable {
        var uuid: String?
        var fullName: String?
        var email: String?
        var hasClaudeMax: Bool?

        enum CodingKeys: String, CodingKey {
            case uuid
            case fullName = "full_name"
            case email
            case hasClaudeMax = "has_claude_max"
        }
    }

    struct Organization: Decodable, Equatable {
        var rateLimitTier: String?
        var subscriptionStatus: String?

        enum CodingKeys: String, CodingKey {
            case rateLimitTier = "rate_limit_tier"
            case subscriptionStatus = "subscription_status"
        }
    }
}

/// Response of `GET /api/oauth/usage`. Each metric object and leaf field is optional.
struct UsageResponse: Decodable, Equatable {
    var fiveHour: UsageMetric?
    var sevenDay: UsageMetric?
    var sevenDaySonnet: UsageMetric?
    var extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

/// A single usage window. `utilization` is a percent in the range 0 to 100, used directly.
struct UsageMetric: Decodable, Equatable {
    var utilization: Double?
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// The usage-credits section. `monthlyLimit` is in integer minor units; render with
/// `decimalPlaces` and `currency` (for example 2000 with 2 places and "AUD" is A$20.00).
struct ExtraUsage: Decodable, Equatable {
    var isEnabled: Bool?
    var monthlyLimit: Int?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?
    var decimalPlaces: Int?
    var disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
        case decimalPlaces = "decimal_places"
        case disabledReason = "disabled_reason"
    }
}
