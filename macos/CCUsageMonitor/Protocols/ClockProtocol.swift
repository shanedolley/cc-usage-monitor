import Foundation

/// Abstracts the current time so polling cadence and reset countdowns are testable
/// with a virtual clock (see NFR-007).
protocol ClockProtocol {
    func now() -> Date
}

/// The production clock, backed by the system time.
struct SystemClock: ClockProtocol {
    func now() -> Date { Date() }
}
