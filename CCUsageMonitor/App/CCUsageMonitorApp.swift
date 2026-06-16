import SwiftUI

/// App entry point. Real menu bar and window wiring arrives in later tasks (6, 7, 13);
/// this scaffold shows a placeholder window so the project builds and runs.
@main
struct CCUsageMonitorApp: App {
    var body: some Scene {
        Window("CC Usage Monitor", id: "main") {
            ContentPlaceholderView()
        }
    }
}

struct ContentPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.largeTitle)
            Text("CC Usage Monitor")
                .font(.headline)
            Text("Scaffold ready")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 200)
    }
}
