import AppKit
import Combine

/// Owns the `NSStatusItem` and keeps it in sync with the coordinator's published state.
/// Presentation logic lives in `MenuBarPresenter`; this is the thin AppKit glue.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onOpen: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(coordinator: PollingCoordinator, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "…"
            button.target = self
            button.action = #selector(handleClick)
        }

        coordinator.$snapshot
            .combineLatest(coordinator.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, status in
                self?.apply(snapshot: snapshot, status: status)
            }
            .store(in: &cancellables)
    }

    private func apply(snapshot: UsageSnapshot?, status: LoadStatus) {
        guard let button = statusItem.button else { return }
        let model = MenuBarPresenter.render(snapshot: snapshot, status: status)
        button.title = model.title
        button.toolTip = model.tooltip
        button.contentTintColor = model.level.statusColor
    }

    @objc private func handleClick() { onOpen() }
}

private extension UsageLevel {
    var statusColor: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
