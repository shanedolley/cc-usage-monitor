import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the user clicks a fired notification, so the app brings up the detail window.
    static let openDetailWindow = Notification.Name("com.shanedolley.ccusagemonitor.openDetailWindow")
}

/// The slice of `UNUserNotificationCenter` the service uses, behind a protocol so tests inject a
/// fake instead of touching the system framework or prompting for authorization.
protocol UserNotificationCentering {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
    func removePending(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func removeDelivered(identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Delivers threshold alerts through `UNUserNotificationCenter`. The rules engine decides when to
/// fire and supplies the already-formatted title and body; this service only delivers and cancels.
///
/// The composition root (task 13) owns two wiring steps this service cannot do for itself: assign
/// `UNUserNotificationCenter.current().delegate = service` so taps reach `handleNotificationClick`,
/// and observe `.openDetailWindow` to bring up the window.
final class NotificationService: NSObject, NotificationServiceProtocol, UNUserNotificationCenterDelegate {
    private let center: UserNotificationCentering

    init(center: UserNotificationCentering = UNUserNotificationCenter.current()) {
        self.center = center
        super.init()
    }

    /// Requests alert and sound permission. A denial or a thrown error both report as not granted.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Reports whether notifications may be shown, without prompting. Provisional counts as allowed.
    /// (`.ephemeral` is iOS-only, so it is not a reachable case on macOS.)
    func isAuthorized() async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    /// Fires a notification immediately. `id` is the request identifier, so `cancel(id:)` can later
    /// remove it. A delivery error is swallowed: a missed alert must not crash the poll loop.
    func fire(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Removes the rule's notification whether it is still pending or already delivered.
    func cancel(id: String) async {
        center.removePending(identifiers: [id])
        center.removeDelivered(identifiers: [id])
    }

    /// Brings up the detail window. Extracted from the delegate callback so it is unit-testable
    /// without constructing a `UNNotificationResponse`, which has no public initializer.
    ///
    /// The delegate callback runs off the main thread, so the post hops to the main actor: an
    /// observer that opens an AppKit window must do so on the main thread.
    func handleNotificationClick() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .openDetailWindow, object: nil)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        handleNotificationClick()
    }

    /// Shows the alert even while the app is frontmost, so a threshold crossing is never silent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
