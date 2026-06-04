import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        controller.start()
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

// `menubar-usage --once` fetches a single round of usage, prints it as text,
// and exits. Handy for diagnostics and for confirming the data layer works
// without launching the menu bar UI.
if CommandLine.arguments.contains("--once") {
    let store = UsageStore(collectors: [ClaudeUsageCollector(), CodexUsageCollector()])
    Task {
        let snapshots = await store.refresh()
        for provider in Provider.allCases {
            guard let s = snapshots.first(where: { $0.provider == provider }) else { continue }
            let plan = s.planLabel.map { " [\($0)]" } ?? ""
            if !s.isConnected {
                print("\(provider.rawValue): not signed in")
            } else if let error = s.error {
                print("\(provider.rawValue)\(plan): \(error)")
            } else {
                let d = UsageFormat.percentText(s.dailyPercent)
                let w = UsageFormat.percentText(s.weeklyPercent)
                print("\(provider.rawValue)\(plan): 5h \(d) (resets \(UsageFormat.resetText(s.dailyResetAt))), "
                    + "week \(w) (resets \(UsageFormat.resetText(s.weeklyResetAt)))")
            }
        }
        exit(0)
    }
    // Service the main queue so the concurrency runtime makes progress; the Task
    // calls exit(0) when done.
    dispatchMain()
}

let app = NSApplication.shared
// Menu-bar-only: no Dock icon, no main menu window.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
