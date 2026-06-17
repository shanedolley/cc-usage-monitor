import Foundation

/// Wraps the UserNotifications framework so the rule engine can be tested with a fake.
protocol NotificationServiceProtocol {
    /// Requests authorization at launch; returns whether it was granted.
    func requestAuthorization() async -> Bool
    /// Returns the current authorization status without prompting.
    func isAuthorized() async -> Bool
    /// Fires a notification. `id` doubles as the request identifier for later cancellation.
    func fire(id: String, title: String, body: String) async
    /// Removes a pending or delivered notification by its rule id.
    func cancel(id: String) async
}
