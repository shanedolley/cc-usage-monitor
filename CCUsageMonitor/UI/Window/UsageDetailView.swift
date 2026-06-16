import SwiftUI

/// The detail window: plan tier header, the three usage rows, the credits section, and a
/// last-updated footer, with dedicated screens for the loading, reauthenticate, keychain,
/// and endpoint states.
struct UsageDetailView: View {
    @ObservedObject var coordinator: PollingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(20)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Claude Code Usage").font(.headline)
            Spacer()
            if let tier = coordinator.snapshot?.profile.organization?.rateLimitTier {
                Text(PlanTierFormatter.format(tier))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Plan \(PlanTierFormatter.format(tier))")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.status {
        case .loading where coordinator.snapshot == nil:
            ProgressView("Loading usage…").frame(maxWidth: .infinity, minHeight: 120)
        case .reauthenticate:
            MessageView(title: "Sign in to Claude Code",
                        message: "Open Claude Code in your terminal and sign in again, then relaunch this app.")
        case .keychainDenied:
            MessageView(title: "Keychain access needed",
                        message: "Allow access to the Claude Code credentials item in System Settings, then relaunch.")
        case .endpointUnavailable:
            MessageView(title: "Usage endpoint unavailable",
                        message: "Anthropic's usage endpoint did not respond. The app keeps retrying.")
        default:
            if let snapshot = coordinator.snapshot {
                metrics(snapshot)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @ViewBuilder private func metrics(_ snapshot: UsageSnapshot) -> some View {
        // The timeline re-renders each minute so the countdowns stay current between polls.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(alignment: .leading, spacing: 14) {
                if let metric = snapshot.usage.fiveHour {
                    UsageRowView(label: "Current session", metric: metric, now: context.date)
                }
                if let metric = snapshot.usage.sevenDay {
                    UsageRowView(label: "Weekly · All models", metric: metric, now: context.date)
                }
                if let metric = snapshot.usage.sevenDaySonnet {
                    UsageRowView(label: "Weekly · Sonnet only", metric: metric, now: context.date)
                }
                if let extra = snapshot.usage.extraUsage {
                    CreditsView(extra: extra)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let updated = coordinator.lastUpdated {
            let isStale = coordinator.status == .stale || coordinator.status == .offline
            Text((isStale ? "Stale · updated " : "Updated ") + Self.age.localizedString(for: updated, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(isStale ? Color.orange : Color.secondary)
        }
    }

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// One metric: label, percent, colored progress bar, and reset countdown.
struct UsageRowView: View {
    let label: String
    let metric: UsageMetric
    let now: Date

    private var percent: Double { metric.utilization ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.subheadline).monospacedDigit().foregroundStyle(color)
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100).tint(color)
            if let resets = metric.resetsAt, let date = ResetFormatter.parse(resets) {
                Text(ResetFormatter.format(resetsAt: date, now: now))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }

    private var color: Color {
        switch UsageLevel.forUtilization(percent) {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// The usage-credits section: spent over limit, or an off state with the reason.
struct CreditsView: View {
    let extra: ExtraUsage

    var body: some View {
        let display = CreditsFormatter.format(extra)
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("Usage credits").font(.subheadline)
                Spacer()
                if display.isDisabled {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(display.spent) / \(display.limit)")
                        .font(.subheadline).monospacedDigit()
                }
            }
            if display.isDisabled, let reason = display.disabledReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// A titled message used for the reauthenticate, keychain, and endpoint states.
struct MessageView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }
}
