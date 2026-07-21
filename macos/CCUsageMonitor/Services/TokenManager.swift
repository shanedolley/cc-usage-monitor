import Foundation
import os

/// Supplies a valid access token, refreshing when needed. A Swift actor so refreshes are
/// single-flight: concurrent callers share one in-flight refresh rather than racing.
///
/// Anthropic rotates refresh tokens and spends the old one the moment a refresh succeeds, so the
/// credential is a lineage with exactly one live holder, not a value that can be copied or replayed.
/// Two rules follow, both learned from credentials that died in production:
///
/// 1. A refresh that succeeds must never be lost. If the write-back fails, the store is left holding
///    a spent refresh token, so the refreshed credential is kept in memory and preferred over the
///    stored one. That failure used to be swallowed and unlogged: the app carried on with the
///    in-memory token, then the next cycle read the dead one and signed the user out for good.
/// 2. Two refreshes must never run at once. Both would present the same single-use token and the
///    server would reject one, which surfaced as a sign-out against a perfectly good store.
actor TokenManager {
    private let keychain: KeychainReading
    private let refresher: TokenRefreshing
    private let writer: KeychainWriting?
    private let clock: ClockProtocol
    private var inFlight: Task<KeychainCredential, Error>?
    /// Identifies the in-flight task so a finishing refresh clears only its own slot, never one a
    /// later refresh has already claimed.
    private var generation = 0
    /// The newest credential this process has obtained. Authoritative over the store when a
    /// write-back has failed, which is the only way the two disagree in this direction.
    private var cached: KeychainCredential?

    private static let logger = Logger(subsystem: "com.shanedolley.ccusagemonitor", category: "TokenManager")

    init(keychain: KeychainReading,
         refresher: TokenRefreshing,
         writer: KeychainWriting?,
         clock: ClockProtocol = SystemClock()) {
        self.keychain = keychain
        self.refresher = refresher
        self.writer = writer
        self.clock = clock
    }

    /// Returns a non-expired access token, refreshing if the stored one is within its
    /// expiry buffer.
    func validAccessToken() async throws -> String {
        try await validCredential().accessToken
    }

    /// Establishes the Keychain grants in one user-visible step: an interactive read grants read
    /// access, and re-writing the same tokens grants write access. After this, the automatic poll
    /// and write-back run non-interactively and never prompt. A write failure here is non-fatal,
    /// because read access alone lets the app show usage.
    ///
    /// The write is skipped while a refresh is in flight. It re-persists whatever it just read, so
    /// running it against a concurrent rotation would put the spent token back on disk.
    func establishAccess() async throws {
        let credential = try keychain.readCredential(allowInteraction: true)
        guard inFlight == nil else { return }
        try? writer?.updateTokens(accessToken: credential.accessToken,
                                  refreshToken: credential.refreshToken,
                                  expiresAt: credential.expiresAt,
                                  allowInteraction: true)
    }

    /// Forces a refresh regardless of the expiry buffer and returns the new access token. Recovers
    /// from a 401 on a token that looked valid by the clock but was rejected by the server.
    func refreshedAccessToken() async throws -> String {
        let current = try currentCredential()
        return try await refresh(previous: current, force: true).accessToken
    }

    func validCredential() async throws -> KeychainCredential {
        let current = try currentCredential()
        if !current.isExpired(now: clock.now()) { return current }
        return try await refresh(previous: current)
    }

    /// The newest credential available: whichever of the in-memory copy and the stored one expires
    /// later. The store normally wins, so a token Claude Code has refreshed is picked up straight
    /// away; the in-memory copy wins only when a write-back failed and left the store stale.
    private func currentCredential() throws -> KeychainCredential {
        let stored = try? keychain.readCredential()
        guard let cached else {
            if let stored { return stored }
            return try keychain.readCredential()   // no cache and no store: surface the real error
        }
        guard let stored else { return cached }
        return stored.expiresAt > cached.expiresAt ? stored : cached
    }

    private func refresh(previous: KeychainCredential, force: Bool = false) async throws -> KeychainCredential {
        // Join, and keep joining. Waiting once is not enough: when an in-flight refresh fails, every
        // caller waiting on it wakes at the same moment, and a single check let them all fall
        // through and each start their own refresh, presenting the same unspent token concurrently.
        // Re-checking means the first caller through starts the retry and the rest join that.
        //
        // This terminates because each turn waits on a strictly newer task, and the run from the
        // final `break` to `inFlight = task` below contains no suspension point, so the actor cannot
        // interleave another caller into that window.
        while let current = inFlight {
            if let joined = try? await current.value {
                // A token other than the one we were sent to replace is the fresh credential.
                if joined.accessToken != previous.accessToken { return joined }
                break
            }
            // That refresh failed. Join a newer one if a caller has already started it; otherwise we
            // are the one who does the work.
            guard let next = inFlight, next != current else { break }
        }
        // Claude Code may have refreshed the credential while we waited, so take that rather than
        // spend a refresh token. A forced refresh skips the shortcut, since its token was rejected
        // even though it has not expired.
        if !force, let latest = try? keychain.readCredential(), !latest.isExpired(now: clock.now()) {
            return latest
        }

        generation += 1
        let mine = generation
        let task = Task { [refresher, clock] () async throws -> KeychainCredential in
            try await refresher.refresh(using: previous, now: clock.now())
        }
        inFlight = task
        defer { if generation == mine { inFlight = nil } }

        let refreshed = try await task.value
        // Cache before persisting. The server has already spent `previous`'s refresh token, so this
        // value is the only usable credential from here on, whether or not it reaches the store.
        cached = refreshed
        persist(refreshed)
        return refreshed
    }

    /// Writes the refreshed credential back, and says so loudly when it cannot.
    ///
    /// The app keeps working either way, on the cached credential, but a store that failed this
    /// write holds a spent refresh token and must be re-seeded before the next launch. This used to
    /// be a bare `try?` with no logging, which is why two credentials died leaving no trace of why.
    private func persist(_ credential: KeychainCredential) {
        guard let writer else { return }
        do {
            try writer.updateTokens(accessToken: credential.accessToken,
                                    refreshToken: credential.refreshToken,
                                    expiresAt: credential.expiresAt)
        } catch {
            Self.logger.error("""
                Refreshed token was NOT persisted (\(String(describing: error), privacy: .public)). \
                The stored credential still holds a spent refresh token, so it is now dead. This app \
                keeps working on the in-memory token until it exits; re-seed before the next launch.
                """)
        }
    }
}
