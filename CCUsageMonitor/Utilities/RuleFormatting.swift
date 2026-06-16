import Foundation

/// The result of validating the add-rule threshold field.
enum ThresholdValidation: Equatable {
    case empty               // nothing entered yet: no error, but not submittable
    case invalid(String)     // a short reason to show inline
    case valid(Int)          // a submittable value within the rule range

    /// The threshold when valid, nil otherwise, so a view can gate its submit button.
    var value: Int? {
        if case let .valid(number) = self { return number }
        return nil
    }
}

enum RuleInput {
    /// Validates the threshold text against `NotificationRule.thresholdRange` (1 to 99). Whitespace
    /// is trimmed; empty input is `.empty` rather than an error, since an untouched field is not wrong.
    static func validateThreshold(_ text: String) -> ThresholdValidation {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        guard let number = Int(trimmed) else { return .invalid("Enter a whole number") }
        guard NotificationRule.thresholdRange.contains(number) else {
            return .invalid("Use a value from 1 to 99")
        }
        return .valid(number)
    }
}

enum RuleStatus {
    /// The per-row indicator: "Watching" while armed and waiting for a crossing, "Triggered" once
    /// the rule has fired and is waiting to re-arm.
    static func label(armed: Bool) -> String {
        armed ? "Watching" : "Triggered"
    }
}
