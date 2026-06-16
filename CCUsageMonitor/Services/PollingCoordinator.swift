import Foundation
import Combine
import Network
import AppKit

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

/// Drives the 60-second poll loop, owns the published UI state, pauses when the network is
/// down, and refetches on wake. UI updates happen on the main actor.
@MainActor
final class PollingCoordinator: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: LoadStatus = .loading
    @Published private(set) var lastUpdated: Date?

    let interval: TimeInterval
    /// How long to wait before the next poll. Normally `interval`; a 429 raises it to the
    /// `Retry-After` value, capped at `maxBackoff`. A successful poll resets it.
    private(set) var nextDelay: TimeInterval

    /// The most a 429 `Retry-After` can push the next poll out: five minutes.
    static let maxBackoff: TimeInterval = 300

    private let api: APIClientProtocol
    private let tokenProvider: AccessTokenProviding
    private let clock: ClockProtocol

    private var pollTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    private var wakeObserver: NSObjectProtocol?

    init(api: APIClientProtocol,
         tokenProvider: AccessTokenProviding,
         clock: ClockProtocol = SystemClock(),
         interval: TimeInterval = 60) {
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
    func poll() async {
        nextDelay = interval   // default for this cycle; only a 429 below raises it
        guard isOnline else {
            status = (snapshot == nil) ? .offline : .stale
            return
        }
        do {
            apply(try await fetchSnapshot(forceRefresh: false))
        } catch APIError.unauthorized {
            await retryAfterForcedRefresh()
        } catch KeychainError.itemNotFound {
            status = .reauthenticate
        } catch KeychainError.accessDenied {
            status = .keychainDenied
        } catch APIError.endpointUnavailable(_) {
            status = .endpointUnavailable
        } catch APIError.rateLimited(let retryAfter) {
            nextDelay = min(retryAfter ?? interval, Self.maxBackoff)
            status = (snapshot == nil) ? .loading : .stale
        } catch APIError.network(_) {
            status = (snapshot == nil) ? .offline : .stale
        } catch {
            // 5xx, decoding, and anything else: keep the last good data if we have it.
            status = (snapshot == nil) ? .loading : .stale
        }
    }

    /// A 401 can mean the token was rejected mid-flight even though it had not expired. Force one
    /// refresh and retry; a second failure means the credentials are genuinely stale.
    private func retryAfterForcedRefresh() async {
        do {
            apply(try await fetchSnapshot(forceRefresh: true))
        } catch KeychainError.accessDenied {
            status = .keychainDenied
        } catch APIError.endpointUnavailable(_) {
            status = .endpointUnavailable
        } catch APIError.rateLimited(let retryAfter) {
            // A 429 on the retry is rate-limiting, not an auth failure: back off, do not sign out.
            nextDelay = min(retryAfter ?? interval, Self.maxBackoff)
            status = (snapshot == nil) ? .loading : .stale
        } catch APIError.network(_) {
            status = (snapshot == nil) ? .offline : .stale
        } catch {
            // Still unauthorized, refresh failed, or token missing: the user must sign in again.
            status = .reauthenticate
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
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let delay = self?.nextDelay ?? 60
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
