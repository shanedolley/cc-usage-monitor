import Foundation

/// Supplies a valid access token, refreshing when needed. A Swift actor so refreshes are
/// single-flight: concurrent callers share one in-flight refresh rather than racing.
///
/// Policy (see `14-spike-findings.md`): re-read the Keychain first so a token Claude Code
/// already refreshed is used without a network call; otherwise refresh and write the new
/// token back so Claude Code stays in sync.
actor TokenManager {
    private let keychain: KeychainReading
    private let refresher: TokenRefreshing
    private let writer: KeychainWriting?
    private let clock: ClockProtocol
    private var inFlight: Task<KeychainCredential, Error>?

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

    func validCredential() async throws -> KeychainCredential {
        let current = try keychain.readCredential()
        if !current.isExpired(now: clock.now()) { return current }
        return try await refresh(previous: current)
    }

    private func refresh(previous: KeychainCredential) async throws -> KeychainCredential {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { [keychain, refresher, writer, clock] () async throws -> KeychainCredential in
            // Re-read: Claude Code may have refreshed the token while we waited.
            if let latest = try? keychain.readCredential(), !latest.isExpired(now: clock.now()) {
                return latest
            }
            let base = (try? keychain.readCredential()) ?? previous
            let refreshed = try await refresher.refresh(using: base, now: clock.now())
            // Write back so Claude Code stays in sync. A write failure is non-fatal: the
            // app still has a valid token in hand for this session.
            try? writer?.updateTokens(accessToken: refreshed.accessToken,
                                      refreshToken: refreshed.refreshToken,
                                      expiresAt: refreshed.expiresAt)
            return refreshed
        }
        inFlight = task
        do {
            let result = try await task.value
            inFlight = nil
            return result
        } catch {
            inFlight = nil
            throw error
        }
    }
}
