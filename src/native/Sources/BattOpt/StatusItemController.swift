import Cocoa

class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔋 --%"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let snap = SMCReader.readBattery()
        let mode = StateStore.readActiveMode()
        let cfg  = StateStore.readConfig()
        let icon = pickIcon(snap: snap, mode: mode)
        let pct  = snap.map { "\($0.pct)%" } ?? "--%"
        statusItem.button?.title = "\(icon) \(pct)"

        statusItem.menu = MenuBuilder.build(
            snapshot: snap,
            activeMode: mode,
            config: cfg,
            onRefresh: { [weak self] in self?.refresh() })
    }

    private func pickIcon(snap: BatterySnapshot?, mode: String) -> String {
        if mode == "charge_full" || mode == "calibration" { return "⚡" }
        if mode == "discharge" { return "🔋" }
        guard let s = snap else { return "🔴" }
        if s.isCharging && s.chCur > 50 { return "⚡" }
        if s.ext && !s.isCharging { return "🔌" }
        return "🔴"
    }

    func cleanup() {
        timer?.invalidate(); timer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    }
}
