import AppKit

class StatusItemController {
    private let statusItem: NSStatusItem
    private var timer: Timer?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔋"
        buildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "BattOpt (native)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refresh() {
        // Placeholder: dynamic title later (SMC/IOReg)
        statusItem.button?.title = "🔋"
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func cleanup() {
        timer?.invalidate()
        timer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
