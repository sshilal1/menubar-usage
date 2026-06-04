import AppKit

/// Owns the menu bar status item, the popover, and the periodic refresh loop.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverController: PopoverViewController

    private var timer: Timer?
    private var latest: [UsageSnapshot] = []
    private var isRefreshing = false

    /// How often we poll. The collectors cache aggressively internally, so this
    /// only redraws; the network is hit far less often.
    private let refreshInterval: TimeInterval = 20

    override init() {
        self.store = UsageStore(collectors: [
            ClaudeUsageCollector(),
            CodexUsageCollector()
        ])
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverController = PopoverViewController()

        super.init()

        // Wire the popover's refresh button back to us now that `self` exists.
        popoverController.onRefresh = { [weak self] in self?.refresh() }

        configureStatusItem()
        configurePopover()
        renderMenuBar() // initial placeholder before first data arrives
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        popover.delegate = self
    }

    func start() {
        refresh()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Pulls fresh snapshots off the main thread, then redraws on the main actor.
    func refresh() {
        if isRefreshing { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let snapshots = await self.store.refresh()
            await MainActor.run {
                self.latest = snapshots
                self.renderMenuBar()
                self.popoverController.update(with: snapshots)
                self.isRefreshing = false
            }
        }
    }

    private func renderMenuBar() {
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        button.image = MenuBarGauge.image(for: latest, height: height)
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        guard !latest.isEmpty else { return "Claude & ChatGPT usage" }
        let parts = Provider.allCases.compactMap { provider -> String? in
            guard let snap = latest.first(where: { $0.provider == provider }) else { return nil }
            guard snap.isConnected else { return "\(provider.rawValue): not signed in" }
            let d = UsageFormat.percentText(snap.dailyPercent)
            let w = UsageFormat.percentText(snap.weeklyPercent)
            return "\(provider.rawValue): 5h \(d), week \(w)"
        }
        return parts.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popoverController.update(with: latest)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Opening is a good moment to pull fresh numbers.
            refresh()
        }
    }
}
