import Foundation

/// Parses and formats the `resets_at` timestamp into the countdown shown next to each metric.
enum ResetFormatter {
    /// Parses an ISO 8601 string (with or without fractional seconds). Returns nil if unparseable.
    static func parse(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// Relative format ("Resets in 2 hr 55 min") under 24 hours, absolute ("Resets Thu 1:59 PM")
    /// at or beyond 24 hours, recomputed against `now` by the view's per-minute timeline.
    static func format(resetsAt: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 { return "Resets now" }

        if interval < 24 * 3600 {
            let totalMinutes = Int(interval) / 60
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0, minutes > 0 { return "Resets in \(hours) hr \(minutes) min" }
            if hours > 0 { return "Resets in \(hours) hr" }
            // Sub-minute remainder truncates to zero; avoid the misleading "Resets in 0 min".
            if minutes == 0 { return "Resets in under a minute" }
            return "Resets in \(minutes) min"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: resetsAt))"
    }
}
