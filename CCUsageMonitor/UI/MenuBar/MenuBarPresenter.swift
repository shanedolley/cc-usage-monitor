import Foundation

/// What the menu bar item should display, derived purely from state so it is unit-testable.
struct MenuBarText: Equatable {
    let title: String
    let tooltip: String
    let level: UsageLevel
}

enum MenuBarPresenter {
    static func render(snapshot: UsageSnapshot?, status: LoadStatus) -> MenuBarText {
        switch status {
        case .reauthenticate:
            return MenuBarText(title: "!", tooltip: "Sign in to Claude Code, then relaunch", level: .critical)
        case .keychainDenied:
            return MenuBarText(title: "!", tooltip: "Keychain access needed for usage", level: .critical)
        case .endpointUnavailable:
            return MenuBarText(title: "?", tooltip: "Usage endpoint unavailable", level: .warning)
        case .loading where snapshot == nil:
            return MenuBarText(title: "…", tooltip: "Loading Claude Code usage…", level: .normal)
        case .offline where snapshot == nil:
            return MenuBarText(title: "—", tooltip: "Offline", level: .normal)
        default:
            guard let usage = snapshot?.usage,
                  let top = UsageMetricSummary.highestMetric(usage) else {
                return MenuBarText(title: "—", tooltip: "No usage data", level: .normal)
            }
            let percent = Int(top.utilization.rounded())
            let stale = (status == .stale || status == .offline) ? " (stale)" : ""
            return MenuBarText(
                title: "\(percent)%",
                tooltip: "Highest: \(top.name) \(percent)%\(stale)",
                level: .forUtilization(top.utilization))
        }
    }
}
