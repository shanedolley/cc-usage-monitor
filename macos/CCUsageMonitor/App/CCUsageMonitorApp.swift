import SwiftUI
import AppKit
import Combine
import UserNotifications

/// App entry point. The app is a menu bar accessory (`LSUIElement` in Info.plist): no Dock icon,
/// no main window at launch. The `AppDelegate` is the composition root; the only scene is an empty
/// `Settings` so SwiftUI does not open a window of its own.
@main
struct CCUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Wires the dependency graph and owns the menu bar item and the detail window. Marked `@MainActor`
/// because it builds and drives main-actor objects (the coordinator, the rules engine, the menu bar).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: PollingCoordinator
    private let rulesEngine: RulesEngine
    private let notificationService: NotificationService
    private let persistence = RulePersistence()
    private let bridge: UsageRulesBridge
    /// Recorded at launch beside the store choice below, so the reauthenticate screen gives the
    /// advice that matches the mode actually running.
    private let credentialSource: CredentialSource

    private var menuBarController: MenuBarController?
    private var cancellables = Set<AnyCancellable>()
    private var clickObserver: NSObjectProtocol?

    override init() {
        // Prefer the credentials file once it is seeded. The file holds the monitor's own OAuth
        // session, independent of Claude Code's, so the monitor refreshes it through the same read,
        // refresh, and write-back loop without rotating the session Claude Code uses. File reads
        // never prompt, so the menu bar app stays silent and the Keychain dialogs never appear.
        //
        // Without the file, fall back to reading Claude Code's Keychain credential read-only. A
        // `NoRefreshTokenRefresher` and a nil writer mean the monitor never refreshes or rewrites
        // the shared token, so it cannot rotate Claude Code's session and sign it out. It uses a
        // valid token and reports an expired one as stale until Claude Code refreshes it.
        let tokenManager: TokenManager
        if FileCredentialStore.isConfigured() {
            let store = FileCredentialStore()
            tokenManager = TokenManager(keychain: store, refresher: TokenRefresher(), writer: store)
            credentialSource = .file
        } else {
            tokenManager = TokenManager(keychain: KeychainReader(),
                                        refresher: NoRefreshTokenRefresher(),
                                        writer: nil)
            credentialSource = .keychain
        }
        coordinator = PollingCoordinator(api: APIClient(), tokenProvider: tokenManager)
        notificationService = NotificationService()
        rulesEngine = RulesEngine(notificationService: notificationService)
        bridge = UsageRulesBridge(engine: rulesEngine)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationService
        loadRules()
        observeSnapshotsForRules()
        persistRulesOnChange()
        observeNotificationClicks()

        menuBarController = MenuBarController(coordinator: coordinator) { [weak self] in
            self?.showWindow()
        }

        // Prompt for permission at launch; the banner reads the live state when the window opens.
        Task { _ = await notificationService.requestAuthorization() }
        // Establish the Keychain grant once (the only interactive Keychain prompt), then start the
        // poll loop, which reads non-interactively and never prompts again.
        Task { await coordinator.startAfterEstablishingAccess() }
    }

    /// A menu bar accessory keeps running after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Wiring

    private func loadRules() {
        // A thrown load error means unreadable, not "no rules"; start empty without overwriting it.
        let rules = (try? persistence.loadRules()) ?? []
        rulesEngine.setRules(rules)
    }

    private func observeSnapshotsForRules() {
        coordinator.$snapshot
            .compactMap { $0?.usage }
            .sink { [weak self] usage in
                Task { @MainActor in await self?.bridge.handle(usage: usage) }
            }
            .store(in: &cancellables)
    }

    private func persistRulesOnChange() {
        // Save when the stored shape (id, metric, threshold) changes, not on every armed flip; the
        // first emission is the just-loaded set, which `dropFirst` skips.
        rulesEngine.$rules
            .map { rules in rules.map { "\($0.id)|\($0.metric.rawValue)|\($0.threshold)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                try? self.persistence.saveRules(self.rulesEngine.rules)
            }
            .store(in: &cancellables)
    }

    private func observeNotificationClicks() {
        clickObserver = NotificationCenter.default.addObserver(forName: .openDetailWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWindow() }
        }
    }

    // MARK: - Window

    private lazy var windowController: NSWindowController = {
        let root = AppRootView(coordinator: coordinator,
                               rulesEngine: rulesEngine,
                               isAuthorized: { [notificationService] in await notificationService.isAuthorized() },
                               currentUsage: { [weak coordinator] in coordinator?.snapshot?.usage },
                               credentialSource: credentialSource)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Claude Code Usage"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false   // closing hides the window, the app stays running
        return NSWindowController(window: window)
    }()

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}
