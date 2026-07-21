import Foundation
import Combine
import Network
import AppKit
import os

/// A successful fetch: profile, usage, and when it was fetched.
struct UsageSnapshot: Equatable {
    var profile: ProfileResponse
    var usage: UsageResponse
    var fetchedAt: Date
}

/// What the UI should show. `snapshot` carries the data; this carries the fetch state.
enum LoadStatus: Equatable {
    case loading             // first fetch in flight, no data yet
    case live                // showing fresh data
    case stale               // showing last good data; the latest fetch failed transiently
    case offline             // no network and no data yet
    case reauthenticate      // token missing or refresh failed; user must sign in to Claude Code
    case keychainDenied      // macOS denied Keychain access
    case endpointUnavailable // persistent API failure (403, 404, 410); the app keeps polling
}

/// Drives the poll loop, owns the published UI state, pauses when the network is down, and refetches
/// on wake. UI updates happen on the main actor.
@MainActor
final class PollingCoordinator: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// Logged on every change. A menu bar app shows one small icon, so when it stops updating there
    /// is nothing on screen to distinguish "waiting", "denied", and "stale". Without this, diagnosing
    /// a stuck app means guessing from a screenshot.
    @Published private(set) var status: LoadStatus = .loading {
        didSet {
            guard status != oldValue else { return }
            Self.logger.info("Status \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.status), privacy: .public)")
        }
    }
    @Published private(set) var lastUpdated: Date?

    private static let logger = Logger(subsystem: "com.shanedolley.ccusagemonitor", category: "PollingCoordinator")

    /// Seconds between polls. Five minutes, not one: at 60s the app sent about 1,440 requests a day
    /// to `/api/oauth/usage`, which rate-limited it for hours at a time (observed 2026-07-21). Usage
    /// figures move slowly enough that five minutes still reads as live, and it cuts the daily
    /// request count to roughly 288.
    static let defaultInterval: TimeInterval = 300

    let interval: TimeInterval
    /// How long to wait before the next poll. Normally `interval`; a 429 raises it to the
    /// `Retry-After` value, capped at `maxBackoff`. A successful poll resets it.
    private(set) var nextDelay: TimeInterval

    /// The most a rate limit can push the next poll out: thirty minutes. It has to exceed
    /// `defaultInterval` by a good margin or the escalation below has nowhere to go, and a limit
    /// seen live lasted hours, so backing off well past the normal interval is the point.
    static let maxBackoff: TimeInterval = 1800

    /// How many polls in a row have been rate-limited. Drives the escalation below and resets on any
    /// successful fetch.
    private var consecutiveRateLimits = 0

    /// Turns a 429 into the delay before the next poll, clamped to `interval...maxBackoff`.
    ///
    /// The floor matters as much as the cap. Anthropic's usage endpoint answers `Retry-After: 0`,
    /// which taken literally means "retry now": the loop slept zero seconds, hammered the endpoint,
    /// and kept its own rate limit alive, leaving the rings frozen indefinitely.
    ///
    /// Because that header is always `0`, it carries no timing information, so the delay comes from
    /// the run of consecutive failures instead: each one doubles the wait, up to the cap. A limit
    /// observed live lasted hours, which a fixed retry would have spent hammering.
    private func backoff(for retryAfter: TimeInterval?) -> TimeInterval {
        consecutiveRateLimits += 1
        let escalated = interval * pow(2, Double(consecutiveRateLimits - 1))
        // A `Retry-After` longer than our own escalation is the server asking for more time, so it
        // still wins; anything shorter is ignored.
        return min(max(escalated, retryAfter ?? 0), Self.maxBackoff)
    }

    private let api: APIClientProtocol
    private let tokenProvider: AccessTokenProviding
    private let clock: ClockProtocol

    private var pollTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    private var isPolling = false
    private var wakeObserver: NSObjectProtocol?

    init(api: APIClientProtocol,
         tokenProvider: AccessTokenProviding,
         clock: ClockProtocol = SystemClock(),
         interval: TimeInterval = PollingCoordinator.defaultInterval) {
        self.api = api
        self.tokenProvider = tokenProvider
        self.clock = clock
        self.interval = interval
        self.nextDelay = interval
    }

    /// Starts polling, network monitoring, and wake recovery.
    func start() {
        startPathMonitor()
        startWakeObserver()
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// One fetch cycle. Directly testable: callers can invoke it and assert the published state.
    ///
    /// Reentrancy guard: the wake and reconnect handlers can each fire a `poll()` while the
    /// periodic one is suspended on the network. Two overlapping cycles would interleave their
    /// writes to `status` and `nextDelay`, so a later success could erase the 429 backoff the
    /// first cycle just set. The guard drops the redundant call; the in-flight cycle already
    /// produces fresh state. The flag is set before the first `await`, so on the main actor
    /// no second cycle can slip past it.
    func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        nextDelay = interval   // default for this cycle; only a 429 below raises it
        guard isOnline else {
            status = (snapshot == nil) ? .offline : .stale
            return
        }
        do {
            apply(try await fetchSnapshot(forceRefresh: false))
        } catch {
            // Logged before the handlers below re-dispatch on the same error, because a failing poll
            // that leaves the status unchanged is otherwise invisible: with no data yet, every
            // failure maps back to `.loading`, so the status log stays silent and the app looks
            // hung. This names the actual cause on every cycle.
            Self.logger.info("Poll failed: \(String(describing: error), privacy: .public)")
            await handle(error)
        }
    }

    /// Maps a failed poll to the published status. Split out of `poll()` so the failure can be
    /// logged once, in one place, before it is classified.
    private func handle(_ error: Error) async {
        switch error {
        case let apiError as APIError:
            switch apiError {
            case .unauthorized:
                await retryAfterForcedRefresh()
            case .tokenStale:
                // Claude Code's token has expired and the monitor never refreshes it, since that
                // would rotate the shared session and sign Claude Code out. Hold the last good data
                // until Claude Code refreshes the token on its next use.
                status = (snapshot == nil) ? .loading : .stale
            case .endpointUnavailable:
                status = .endpointUnavailable
            case .rateLimited(let retryAfter):
                nextDelay = backoff(for: retryAfter)
                status = (snapshot == nil) ? .loading : .stale
            case .network:
                status = (snapshot == nil) ? .offline : .stale
            default:
                // 5xx, decoding, and anything else: keep the last good data if we have it.
                status = (snapshot == nil) ? .loading : .stale
            }
        case let keychainError as KeychainError:
            switch keychainError {
            case .itemNotFound:
                status = .reauthenticate
            case .accessDenied, .interactionRequired:
                // A background read found no grant; show the keychain state without firing a modal.
                // The user re-grants via Grant Access, which prompts once.
                status = .keychainDenied
            default:
                status = (snapshot == nil) ? .loading : .stale
            }
        default:
            status = (snapshot == nil) ? .loading : .stale
        }
    }

    /// Performs the one-time interactive Keychain grant, then refreshes the data. This is the only
    /// path that may present a Keychain prompt; the app calls it at launch and from the Grant Access
    /// button. A denied or failed grant is swallowed, since the following poll reflects the real
    /// state (it shows `.keychainDenied` again rather than a half-set status).
    func establishAccess() async {
        try? await tokenProvider.establishAccess()
        await poll()
    }

    /// The launch path: start the loop, then ask for the Keychain grant.
    ///
    /// The loop starts *first* because the grant can present a modal dialog and block until the user
    /// answers it. Awaiting that before starting meant an unanswered dialog stopped the app polling
    /// at all, with nothing on screen but a spinner. Starting first costs nothing: a poll with no
    /// grant yet fails to `.keychainDenied`, which is the accurate state, and the poll after the
    /// grant recovers on its own.
    ///
    /// Separate from `establishAccess()` because that one polls as well. Calling it and then
    /// `start()` fired two full fetches about 300ms apart on every launch, wasted work that also
    /// helped trip the usage endpoint's rate limit before the first ring was drawn.
    func startAfterEstablishingAccess() async {
        start()
        try? await tokenProvider.establishAccess()
    }

    /// A 401 can mean the token was rejected mid-flight even though it had not expired. Force one
    /// refresh and retry. Only an explicit auth failure on the retry (a rejected refresh or a
    /// missing credential) signs the user out; a transient failure holds the last good data.
    private func retryAfterForcedRefresh() async {
        do {
            apply(try await fetchSnapshot(forceRefresh: true))
        } catch APIError.unauthorized {
            // The refresh token was rejected, or the freshly refreshed token was still refused.
            // This is a genuine auth failure, so sign the user in again.
            status = .reauthenticate
        } catch KeychainError.itemNotFound {
            // The credential is gone: the user must re-seed and sign in.
            status = .reauthenticate
        } catch KeychainError.invalidData {
            // The credential is present but unreadable, so the same re-seed guidance applies.
            status = .reauthenticate
        } catch KeychainError.accessDenied {
            status = .keychainDenied
        } catch KeychainError.interactionRequired {
            // A background read found no grant; show the keychain state without firing a modal.
            // The user re-grants via Grant Access, which prompts once.
            status = .keychainDenied
        } catch APIError.endpointUnavailable(_) {
            status = .endpointUnavailable
        } catch APIError.rateLimited(let retryAfter) {
            // A 429 on the retry is rate-limiting, not an auth failure: back off, do not sign out.
            nextDelay = backoff(for: retryAfter)
            status = (snapshot == nil) ? .loading : .stale
        } catch APIError.network(_) {
            status = (snapshot == nil) ? .offline : .stale
        } catch APIError.tokenStale {
            // The token is expired and the monitor does not refresh it. Signing out would not help,
            // so keep the last good data and wait for Claude Code to refresh.
            status = (snapshot == nil) ? .loading : .stale
        } catch {
            // A transient refresh failure (5xx, a decoding error, or an unexpected status) is not
            // proof that the credentials are bad. Hold the last good data and let the next poll
            // retry, rather than forcing a needless sign-in. Only the explicit auth failures above
            // reach `.reauthenticate`.
            status = (snapshot == nil) ? .loading : .stale
        }
    }

    private func fetchSnapshot(forceRefresh: Bool) async throws -> UsageSnapshot {
        let token = forceRefresh
            ? try await tokenProvider.refreshedAccessToken()
            : try await tokenProvider.validAccessToken()
        async let profileCall = api.fetchProfile(accessToken: token)
        async let usageCall = api.fetchUsage(accessToken: token)
        return UsageSnapshot(profile: try await profileCall,
                             usage: try await usageCall,
                             fetchedAt: clock.now())
    }

    private func apply(_ snap: UsageSnapshot) {
        snapshot = snap
        lastUpdated = snap.fetchedAt
        status = .live
        // The escalated backoff must not outlive the rate limit that caused it.
        consecutiveRateLimits = 0
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let delay = self?.nextDelay ?? Self.defaultInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if online, !wasOnline {
                    await self.poll()   // immediate refetch on reconnect
                } else if !online {
                    self.status = (self.snapshot == nil) ? .offline : .stale
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }
}
