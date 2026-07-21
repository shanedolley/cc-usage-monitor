import SwiftUI
import AppKit

/// The detail window: plan tier header, the three usage rows, the credits section, and a
/// last-updated footer, with dedicated screens for the loading, reauthenticate, keychain,
/// and endpoint states.
struct UsageDetailView: View {
    @ObservedObject var coordinator: PollingCoordinator
    /// Which store the credential comes from. The reauthenticate screen needs it because the two
    /// modes have opposite fixes; defaults to the Keychain, the mode a fresh install runs in.
    var credentialSource: CredentialSource = .keychain

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
                let formatted = PlanTierFormatter.format(tier)
                Text(formatted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Plan \(formatted)")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.status {
        case .loading where coordinator.snapshot == nil:
            ProgressView("Loading usage…").frame(maxWidth: .infinity, minHeight: 120)
        case .reauthenticate:
            // The advice depends on which store the credential comes from: file mode is fixed by
            // re-seeding and is made worse by signing in, Keychain mode is fixed by signing in. A
            // fixed message is wrong in one mode or the other, which is what made the July outage
            // look unfixable.
            let advice = credentialSource.reauthenticateAdvice
            MessageView(title: advice.title,
                        message: advice.message,
                        actionTitle: credentialSource.offersSignIn ? "Sign in to Claude Code" : nil,
                        action: credentialSource.offersSignIn ? { ClaudeLoginLauncher.launch() } : nil)
        case .keychainDenied:
            KeychainPermissionView { await coordinator.establishAccess() }
        case .endpointUnavailable:
            MessageView(title: "Usage endpoint unavailable",
                        message: "Anthropic's usage endpoint is unavailable or has moved. The app keeps retrying.")
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

/// The keychain-denied state: explains the denial and offers a Grant Access button that triggers
/// the one interactive Keychain prompt in place, so the user grants access without relaunching.
/// Opening Keychain Access stays as a fallback.
struct KeychainPermissionView: View {
    /// Runs the one-time interactive grant (the coordinator's `establishAccess`).
    let onGrant: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keychain access needed").font(.subheadline).bold()
            Text("Allow this app to read the Claude Code credentials item. Choose Always Allow so it grants once.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Grant Access") { Task { await onGrant() } }
                Button("Open Keychain Access") { Self.openKeychainAccess() }
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    private static func openKeychainAccess() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
    }
}

/// A titled message used for the reauthenticate and endpoint states. `action` adds a button for the
/// states that have a real fix to offer.
struct MessageView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            Text(message).font(.caption).foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }
}

/// Opens `claude /login` in Terminal.
///
/// The sign-in cannot happen inside this app. Anthropic's OAuth client rejects a third-party
/// authorization-code flow (verified against the real endpoints with the exact parameters the Claude
/// Code binary uses, on both the manual and localhost redirects), so the app cannot mint a session of
/// its own. `claude /login` is an interactive terminal program, so the next best thing is to start it
/// in a terminal and let the user finish there.
enum ClaudeLoginLauncher {
    /// Runs the login in Terminal and brings it to the front. AppleScript, rather than launching the
    /// binary directly, because the login is an interactive TUI: it needs a real terminal to draw in
    /// and to take keystrokes.
    static func launch(runner: (String) -> Void = runAppleScript) {
        runner("""
        tell application "Terminal"
            activate
            do script "claude /login"
        end tell
        """)
    }

    private static func runAppleScript(_ source: String) {
        // `NSAppleScript` needs the Apple Events entitlement to drive another app, so a sandboxed or
        // unentitled build fails here rather than silently doing nothing. The error is surfaced in
        // the log; the message on screen still names the command to run by hand.
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("Could not open Terminal for claude /login: \(error)")
        }
    }
}
