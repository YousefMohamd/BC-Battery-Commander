// AppDelegate.swift — Battery Commander (BC) standalone app, Stage C.
//
// StatusItemController + ActionRunner (design §4). Owns the single
// NSStatusItem, the 10 s refresh timer, and menu presentation. All
// collection happens off the main thread; all UI work on the main
// queue. Actions run the SAME dispatch.sh the plugin invokes, with the
// same single argument, asynchronously (dispatch may open dialogs).
//
// Stage B notes:
//  - Launcher housekeeping (FR-006) IS performed: once per launch, on
//    a background queue, via Housekeeping.swift (the launcher
//    applet's sequence, merged per design §8.1). If another live
//    process already holds the launch lock, this instance exits —
//    the launcher script's single-instance rule.
//  - Quit (menu bottom) is a real tool close (Stage C): it writes
//    the FR-007 closed flag (.tool_closed) and the bc-limit daemon
//    performs the read-back-verified limit release itself. A
//    duplicate instance's exit never writes the flag.
//  - If BC_BENCH_LOG is set in the environment, lifecycle/refresh
//    lines are appended there (evidence aid).

import AppKit

final class NodeRef: NSObject {
    let node: MenuNode
    init(_ node: MenuNode) { self.node = node }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let collectQueue = DispatchQueue(label: "bc.collect", qos: .utility)
    private var lastGood: Snapshot? = nil
    private var housekeepingOutcome: Housekeeping.Outcome? = nil
    private var consecutiveStatusFailures = 0
    private var collectBusy = false
    private var tickCount = 0
    private var menuWasDegraded = false
    private var currentMenu: NSMenu?

    // MARK: Bench log

    private func benchLog(_ msg: String) {
        NSLog("BatteryCommander: %@", msg)
        guard let path = ProcessInfo.processInfo.environment["BC_BENCH_LOG"], !path.isEmpty else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        benchLog("launched (Stage C build, FR-006 launcher merge + FR-007 closed-flag)")
        // App-native notifications (final cleanup 2026-11-18): ask
        // for authorization at first use; the system shows the
        // one-time prompt for this bundle and every later post
        // carries the app's own name + icon automatically.
        Notifier.requestAuthorization { [weak self] msg in self?.benchLog(msg) }
        // FR-006: the absorbed launcher housekeeping runs once, off
        // the main thread (it sleeps and shells out, like the script).
        Housekeeping.runOnce { [weak self] outcome in
            self?.benchLog("housekeeping outcome: \(outcome)")
            DispatchQueue.main.async {
                self?.housekeepingOutcome = outcome
                if outcome == .duplicateInstance { NSApp.terminate(nil) }
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⏳ …"
        }
        refresh(full: true)
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.tickCount += 1
            // Perf fix (2026-11-26): light collect on the 10 s
            // cadence; a full census every 30th tick (5 min) keeps
            // the menu data fresh without paying for it 6x/minute.
            strongSelf.refresh(full: strongSelf.tickCount % 30 == 0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // FR-007 (Stage C): a graceful terminate of the primary
        // instance is a tool close — leave the closed flag for the
        // daemon's release. A duplicate instance must NOT write it:
        // the primary is still running and enforcing.
        if housekeepingOutcome != .duplicateInstance {
            writeToolClosedFlag()
        }
        benchLog("terminated")
    }

    // MARK: FR-007 closed flag (Stage C)

    /// Write ~/.battery-commander/.tool_closed atomically (tmp +
    /// rename). Existence is the whole signal for the daemon; the
    /// content is informational (stage-c-readiness §1.1). Called
    /// only from the primary instance's close paths.
    private func writeToolClosedFlag() {
        guard let dash = StatusProvider.dashPath else { return }
        let flagPath = (dash as NSString).appendingPathComponent(".tool_closed")
        let tmpPath = flagPath + ".tmp"
        let content = "CLOSED_AT=\(Int(Date().timeIntervalSince1970))\nBY=BatteryCommander.app (Quit)\n"
        do {
            try content.write(toFile: tmpPath, atomically: false, encoding: .utf8)
            let fm = FileManager.default
            if fm.fileExists(atPath: flagPath) { try fm.removeItem(atPath: flagPath) }
            try fm.moveItem(atPath: tmpPath, toPath: flagPath)
            benchLog("FR-007: .tool_closed written")
        } catch {
            benchLog("FR-007: .tool_closed write FAILED: \(error)")
        }
    }

    // MARK: Refresh pipeline

    func refresh(full: Bool = false) {
        // Perf fix (2026-11-26): never queue a second collect
        // behind a running one. A slow census (pmset -g log,
        // system_profiler) used to stack snapshots on the serial
        // queue until the backlog drained, spiking CPU and RAM.
        if collectBusy { return }
        collectBusy = true
        collectQueue.async { [weak self] in
            // Drain the script notification queue first (final
            // cleanup 2026-11-18): helpers append title<TAB>body
            // lines to ~/.battery-commander/.notify_queue; the app
            // posts them natively on this same refresh cadence.
            if let dash = StatusProvider.dashPath {
                Notifier.drain(dash: dash) { msg in self?.benchLog(msg) }
            }
            let snap = StatusProvider.collect(full: full)
            DispatchQueue.main.async {
                self?.collectBusy = false
                self?.apply(snap)
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        if snap.stateDirMissing {
            benchLog("degraded: state dir missing")
            presentDegraded()
            return
        }
        if snap.bcStatusOK {
            consecutiveStatusFailures = 0
            lastGood = snap
            present(snap)
        } else {
            consecutiveStatusFailures += 1
            if consecutiveStatusFailures >= 2 || lastGood == nil {
                benchLog("degraded: bc-status unavailable (failures=\(consecutiveStatusFailures))")
                presentDegraded()
            } else if let good = lastGood {
                present(good)   // §9: keep last good snapshot, no flicker
            }
        }
    }

    private func present(_ snap: Snapshot) {
        benchLog("status: \(snap.titleText) mode=\(snap.activeMode)")
        if let button = statusItem.button {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: snap.titleText,
                attributes: [
                    .foregroundColor: nsColor(snap.finalColor) ?? NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 14),
                ])
        }
        // Perf fix (2026-11-26): light snapshots update the title
        // only — rebuilding the whole NSMenu every 10 s was pure
        // waste. The menu is rebuilt on full snapshots, at launch
        // (no menu yet), and when recovering from the degraded menu.
        if snap.isFull || currentMenu == nil || menuWasDegraded {
            menuWasDegraded = false
            let nodes = MenuModel.build(from: snap)
            installMenu(nodes)
        }
    }

    private func presentDegraded() {
        menuWasDegraded = true
        if let button = statusItem.button {
            // §9: dimmed logo glyph + "--%".
            if let iconPath = Bundle.main.path(forResource: "Battery Commander", ofType: "icns"),
               let img = NSImage(contentsOfFile: iconPath) {
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            }
            button.attributedTitle = NSAttributedString(
                string: "--%",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 14),
                ])
        }
        let dash = StatusProvider.dashPath
        let dispatchExists = dash.map {
            FileManager.default.isExecutableFile(
                atPath: ($0 as NSString).appendingPathComponent("dispatch.sh"))
        } ?? false
        installMenu(MenuModel.degraded(stateDirMissing: dash == nil,
                                       dash: dash, dispatchExists: dispatchExists))
    }

    private func installMenu(_ nodes: [MenuNode]) {
        let menu = NSMenu()
        menu.delegate = self
        for n in nodes {
            menu.addItem(menuItem(for: n))
        }
        currentMenu = menu
        statusItem.menu = menu
    }

    // MARK: Menu construction

    private func menuItem(for node: MenuNode) -> NSMenuItem {
        if node.isSeparator { return NSMenuItem.separator() }
        let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
        if node.color != nil || node.size != nil {
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let c = node.color, let ns = nsColor(c) { attrs[.foregroundColor] = ns }
            attrs[.font] = NSFont.systemFont(ofSize: CGFloat(node.size ?? 13))
            item.attributedTitle = NSAttributedString(string: node.title, attributes: attrs)
        }
        if node.checked { item.state = .on }
        if node.disabled { item.isEnabled = false }
        if let children = node.children {
            let sub = NSMenu()
            for c in children { sub.addItem(menuItem(for: c)) }
            item.submenu = sub
        } else if node.action != nil || node.openPath != nil || node.special != nil {
            item.target = self
            item.action = #selector(menuItemClicked(_:))
            item.representedObject = NodeRef(node)
        } else {
            // Pure text line (the plugin's caption/status lines): no
            // action; clicking simply closes the menu, as in SwiftBar.
            item.isEnabled = false
        }
        return item
    }

    private func nsColor(_ token: String) -> NSColor? {
        if token == "red" { return NSColor.red }
        guard token.hasPrefix("#"), token.count == 7,
              let v = UInt32(token.dropFirst(), radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0, alpha: 1.0)
    }

    // MARK: Actions

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? NodeRef else { return }
        let node = ref.node
        if let special = node.special {
            switch special {
            case "refresh": refresh(full: true)
            case "quit":
                // FR-007: write the closed flag FIRST, then exit —
                // the daemon performs the release (read-back
                // verified) on its next run.
                writeToolClosedFlag()
                NSApp.terminate(nil)
            default: break
            }
            return
        }
        if let openPath = node.openPath {
            benchLog("action: open \(openPath)")
            Shell.launch("/usr/bin/open", [openPath]) { _ in }
            return
        }
        guard let action = node.action else { return }
        guard let dash = StatusProvider.dashPath else { return }
        let dispatch = (dash as NSString).appendingPathComponent("dispatch.sh")
        guard FileManager.default.isExecutableFile(atPath: dispatch) else {
            benchLog("action \(action): dispatch.sh missing, ignored")
            return
        }
        benchLog("action: dispatch.sh \(action)")
        sender.isEnabled = false
        Shell.launch(dispatch, [action]) { [weak self] status in
            self?.benchLog("action \(action) exited status=\(status)")
            DispatchQueue.main.async { self?.refresh(full: true) }
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // FR-002: refresh on menu open (async; the timer keeps the
        // snapshot ≤ 10 s old in the meantime). Full census, so the
        // menu the user is looking at converges to fresh data.
        refresh(full: true)
    }
}
