import SwiftUI

/// The detail window's content: the usage readout and the rules manager as two tabs.
struct AppRootView: View {
    @ObservedObject var coordinator: PollingCoordinator
    @ObservedObject var rulesEngine: RulesEngine
    /// Checked live when the view appears, so the disabled-notifications banner reflects the real
    /// authorization state rather than a value captured at launch.
    var isAuthorized: () async -> Bool
    var currentUsage: () -> UsageResponse?

    @State private var notificationsAuthorized = true

    var body: some View {
        TabView {
            UsageDetailView(coordinator: coordinator)
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.67percent") }

            RulesView(rulesEngine: rulesEngine,
                      notificationsAuthorized: notificationsAuthorized,
                      currentUsage: currentUsage)
                .tabItem { Label("Rules", systemImage: "bell.badge") }
        }
        .frame(width: 380)
        .frame(minHeight: 360)
        .task { notificationsAuthorized = await isAuthorized() }
    }
}
