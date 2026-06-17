import SwiftUI
import AppKit

/// The rules screen: a header with an add button, an optional notifications-disabled banner, and
/// the list of rules or an empty-state prompt. Adding opens a sheet; deleting removes the rule.
struct RulesView: View {
    @ObservedObject var rulesEngine: RulesEngine
    /// Drives the disabled-notifications banner. The composition root supplies the live
    /// authorization state; it defaults to authorized so previews and tests read normally.
    var notificationsAuthorized: Bool = true
    /// Supplies the latest usage when a rule is added, so a rule added while a metric is already
    /// over its threshold starts disarmed. Defaults to no usage (the rule starts armed).
    var currentUsage: () -> UsageResponse? = { nil }

    @State private var showingAddRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notification Rules").font(.headline)
                Spacer()
                Button { showingAddRule = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add rule")
            }

            if !notificationsAuthorized {
                NotificationsDisabledBanner()
            }

            if rulesEngine.rules.isEmpty {
                EmptyRulesView()
            } else {
                ForEach(rulesEngine.rules) { rule in
                    RuleRowView(rule: rule) {
                        Task { await rulesEngine.removeRule(id: rule.id) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .sheet(isPresented: $showingAddRule) {
            AddRuleView(rulesEngine: rulesEngine, currentUsage: currentUsage)
        }
    }
}

/// One rule: metric, threshold, an armed/triggered indicator, and a delete button.
struct RuleRowView: View {
    let rule: NotificationRule
    let onDelete: () -> Void

    var body: some View {
        let status = RuleStatus.label(armed: rule.armed)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.metric.displayName).font(.subheadline)
                Text("Threshold: \(rule.threshold)%")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text(status)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((rule.armed ? Color.green : Color.orange).opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        // Ignore children and expose delete as a named action, so VoiceOver can still delete a row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rule.metric.displayName), threshold \(rule.threshold) percent, \(status)")
        .accessibilityAction(named: "Delete") { onDelete() }
    }
}

/// The add-rule sheet: pick a metric, type a 1 to 99 threshold, with inline validation.
struct AddRuleView: View {
    @ObservedObject var rulesEngine: RulesEngine
    var currentUsage: () -> UsageResponse? = { nil }
    @Environment(\.dismiss) private var dismiss

    @State private var metric: RuleMetric = .fiveHour
    @State private var thresholdText = ""

    private var validation: ThresholdValidation { RuleInput.validateThreshold(thresholdText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Rule").font(.headline)

            Picker("Metric", selection: $metric) {
                ForEach(RuleMetric.allCases, id: \.self) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notify at")
                    TextField("80", text: $thresholdText).frame(width: 60)
                    Text("%")
                }
                if case let .invalid(message) = validation {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation.value == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func add() {
        guard let threshold = validation.value else { return }
        rulesEngine.addRule(metric: metric, threshold: threshold, currentUsage: currentUsage())
        dismiss()
    }
}

/// Shown when there are no rules: a short explanation and an example.
struct EmptyRulesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No rules yet").font(.subheadline).bold()
            Text("Add a rule to be notified when a usage metric crosses a threshold, for example when your current session reaches 80%.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown when notification permission is off: explains the rules cannot alert and links to Settings.
struct NotificationsDisabledBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.slash")
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off").font(.caption).bold()
                Text("Rules will not alert until you allow notifications for this app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { Self.openNotificationSettings() }
                .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
