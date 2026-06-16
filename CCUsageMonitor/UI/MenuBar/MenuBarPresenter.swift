import Foundation

/// One donut in the menu bar: a metric's percentage and its color level. `label` names the
/// metric for the tooltip.
struct DonutSpec: Equatable {
    let label: String
    let percent: Int
    let level: UsageLevel
}

/// What to draw in the menu bar. A glyph for the states with no data to chart, or one or two
/// donuts for live and stale data.
enum MenuBarContent: Equatable {
    case glyph(String)
    case donuts(specs: [DonutSpec], dimmed: Bool)
}

/// The full menu bar model, derived purely from state so it is unit-testable. `level` is the
/// most severe of the donuts, for any monochrome glyph tint.
struct MenuBarModel: Equatable {
    let content: MenuBarContent
    let tooltip: String
    let level: UsageLevel
}

enum MenuBarPresenter {
    /// Session on the left, weekly all-models on the right. A metric absent from the response
    /// drops its donut; with neither present, the model falls back to a dash glyph.
    static func render(snapshot: UsageSnapshot?, status: LoadStatus) -> MenuBarModel {
        switch status {
        case .reauthenticate:
            return glyph("!", "Sign in to Claude Code, then relaunch", .critical)
        case .keychainDenied:
            return glyph("!", "Keychain access needed for usage", .critical)
        case .endpointUnavailable:
            return glyph("?", "Usage endpoint unavailable", .warning)
        case .loading where snapshot == nil:
            return glyph("…", "Loading Claude Code usage…", .normal)
        case .offline where snapshot == nil:
            return glyph("—", "Offline", .normal)
        default:
            guard let usage = snapshot?.usage else {
                return glyph("—", "No usage data", .normal)
            }
            var specs: [DonutSpec] = []
            if let value = usage.fiveHour?.utilization {
                specs.append(donut("Current session", value))
            }
            if let value = usage.sevenDay?.utilization {
                specs.append(donut("Weekly, all models", value))
            }
            guard !specs.isEmpty else {
                return glyph("—", "No usage data", .normal)
            }
            let dimmed = (status == .stale || status == .offline)
            let staleSuffix = dimmed ? " (stale)" : ""
            let tooltip = specs.map { "\($0.label) \($0.percent)%" }.joined(separator: ", ") + staleSuffix
            return MenuBarModel(content: .donuts(specs: specs, dimmed: dimmed),
                                tooltip: tooltip,
                                level: overallLevel(specs))
        }
    }

    private static func donut(_ label: String, _ utilization: Double) -> DonutSpec {
        DonutSpec(label: label,
                  percent: Int(utilization.rounded()),
                  level: .forUtilization(utilization))
    }

    private static func glyph(_ symbol: String, _ tooltip: String, _ level: UsageLevel) -> MenuBarModel {
        MenuBarModel(content: .glyph(symbol), tooltip: tooltip, level: level)
    }

    private static func overallLevel(_ specs: [DonutSpec]) -> UsageLevel {
        if specs.contains(where: { $0.level == .critical }) { return .critical }
        if specs.contains(where: { $0.level == .warning }) { return .warning }
        return .normal
    }
}
