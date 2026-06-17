import Foundation
import os

/// Reads and writes notification rules as JSON in Application Support. Only the stable fields
/// persist: `NotificationRule`'s `Codable` already excludes the runtime `armed`/`lastFiredAt`, so
/// no separate persistable type is needed.
final class RulePersistence {
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.shanedolley.ccusagemonitor", category: "RulePersistence")

    /// `directory` is injectable so tests write to a temporary folder. When nil, rules live in
    /// Application Support/CCUsageMonitor. The folder is created up front so the first save succeeds.
    init(directory: URL? = nil) {
        let folder = directory ?? RulePersistence.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("notification-rules.json")
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CCUsageMonitor")
    }

    /// Loads saved rules. A missing or empty file yields an empty list. A rule that fails to decode,
    /// from an unknown metric or an out-of-range threshold, is dropped with a logged warning rather
    /// than failing the whole load.
    ///
    /// A thrown error means the file could not be read or is structurally corrupt; it does not mean
    /// "no rules". A caller must not answer it by saving an empty list, which would erase the file.
    func loadRules() throws -> [NotificationRule] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                        && error.code == NSFileReadNoSuchFileError {
            return []   // no file yet is the normal first-run case
        }
        guard !data.isEmpty else { return [] }

        let decoded = try JSONDecoder().decode([LenientRule].self, from: data)
        let rules = decoded.compactMap(\.rule)
        let dropped = decoded.count - rules.count
        if dropped > 0 {
            logger.warning("Dropped \(dropped) unreadable notification rule(s) on load")
        }
        return rules
    }

    /// Writes the rules atomically. `armed` and `lastFiredAt` are omitted by `NotificationRule`'s
    /// `Codable`, so they never reach disk.
    func saveRules(_ rules: [NotificationRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Decodes one rule without throwing: a rule that fails validation becomes nil and is dropped,
    /// so one bad entry cannot sink the whole file. The wrapper still consumes its array slot, which
    /// keeps the surrounding array decode from looping.
    private struct LenientRule: Decodable {
        let rule: NotificationRule?
        init(from decoder: Decoder) throws {
            rule = try? NotificationRule(from: decoder)
        }
    }
}
