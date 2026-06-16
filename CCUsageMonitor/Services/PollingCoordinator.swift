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
    case endpointUnavailable // terminal API failure (403, 404, 410)
}

/// Drives the 60-second poll loop, owns the published UI state, pauses when the network is
/// down, and refetches on wake. UI updates happen on the main actor.
@MainActor
final class PollingCoordinator: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: LoadStatus = .loading
    @Published private(set) var lastUpdated: Date?

    let interval: TimeInterval
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
        guard isOnline else {
            status = (snapshot == nil) ? .offline : .stale
            return
        }
        do {
            let token = try await tokenProvider.validAccessToken()
            async let profileCall = api.fetchProfile(accessToken: token)
            async let usageCall = api.fetchUsage(accessToken: token)
            let snap = UsageSnapshot(profile: try await profileCall,
                                     usage: try await usageCall,
                                     fetchedAt: clock.now())
            snapshot = snap
            lastUpdated = snap.fetchedAt
            status = .live
        } catch APIError.unauthorized {
            status = .reauthenticate
        } catch KeychainError.itemNotFound {
            status = .reauthenticate
        } catch KeychainError.accessDenied {
            status = .keychainDenied
        } catch APIError.endpointUnavailable(_) {
            status = .endpointUnavailable
        } catch APIError.network(_) {
            status = (snapshot == nil) ? .offline : .stale
        } catch {
            // Rate limit, 5xx, decoding, and anything else: keep the last good data if we have it.
            status = (snapshot == nil) ? .loading : .stale
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = self?.interval ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
