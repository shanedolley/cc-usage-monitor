import Foundation

/// Formats the usage-credits section. `monthlyLimit` is integer minor units divided by
/// 10^decimalPlaces. `usedCredits` denomination is unconfirmed (the spike sample was 0.0),
/// so it is treated as a major-unit amount and flagged for confirmation with real spend.
enum CreditsFormatter {
    struct Display: Equatable {
        let limit: String
        let spent: String
        let isDisabled: Bool
        let disabledReason: String?
    }

    static func format(_ extra: ExtraUsage) -> Display {
        let currency = extra.currency ?? ""
        let places = max(extra.decimalPlaces ?? 2, 0)
        let divisor = pow(10.0, Double(places))
        let limitMajor = Double(extra.monthlyLimit ?? 0) / divisor
        let spentMajor = extra.usedCredits ?? 0

        return Display(
            limit: money(limitMajor, currency: currency, places: places),
            spent: money(spentMajor, currency: currency, places: places),
            isDisabled: !(extra.isEnabled ?? false),
            disabledReason: extra.disabledReason)
    }

    static func money(_ amount: Double, currency: String, places: Int) -> String {
        symbol(for: currency) + String(format: "%.\(places)f", amount)
    }

    private static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "AUD": return "A$"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "": return ""
        default: return currency.uppercased() + " "   // unrecognized: show the code as a prefix
        }
    }
}
