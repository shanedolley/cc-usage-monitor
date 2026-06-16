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
            button.imagePosition = .imageOnly
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
        button.toolTip = model.tooltip
        switch model.content {
        case .glyph(let symbol):
            button.image = nil
            button.imagePosition = .noImage
            button.title = symbol
            button.contentTintColor = model.level.statusColor
        case .donuts(let specs, let dimmed):
            button.title = ""
            button.imagePosition = .imageOnly
            button.contentTintColor = nil   // the non-template image carries its own colors
            button.image = MenuBarIconRenderer.image(specs: specs, dimmed: dimmed)
        }
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
