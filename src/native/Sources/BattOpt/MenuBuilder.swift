import Cocoa

final class ActionTarget: NSObject {
    static let shared = ActionTarget()
    var refreshCallback: (() -> Void)?

    @objc func runDispatch(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let a = d["action"] as? String else { return }
        let args = d["args"] as? [String] ?? []
        DispatchBridge.runDispatch(a, args: args)
    }
    @objc func runRefresh(_ sender: NSMenuItem) { refreshCallback?() }
    @objc func openAbout() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/BattOpt.app"))
    }
}

enum MenuBuilder {
    static func build(snapshot: BatterySnapshot?,
                      activeMode: String,
                      config: (upper: Int, lower: Int, sailing: Bool, gap: Int),
                      onRefresh: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        ActionTarget.shared.refreshCallback = onRefresh

        let pct = snapshot.map { "\($0.pct)%" } ?? "--%"
        let temp = snapshot.map { String(format: "%.1f°C", $0.temp) } ?? "--"

        // === Header ===
        menu.addItem(dis("🔋 \(pct) | \(activeMode)"))
        menu.addItem(NSMenuItem.separator())

        // === Status detail ===
        menu.addItem(dis("Charge: \(pct)"))
        menu.addItem(dis("Mode: \(activeMode)"))
        if config.sailing {
            menu.addItem(dis("Sailing · \(config.lower)-\(config.upper)%"))
        }
        menu.addItem(dis("Active Limit: \(config.upper)% / \(config.lower)%"))
        menu.addItem(dis("Temperature: \(temp)"))
        menu.addItem(NSMenuItem.separator())

        // === Quick Actions submenu ===
        let qa = sub("Quick Actions")
        qa.submenu?.addItem(act("Fast Sleep · 5/5/15 · office", "power_mode_fast"))
        qa.submenu?.addItem(act("Balanced · 18/10/15 · daily", "power_mode_balanced"))
        qa.submenu?.addItem(act("Always Awake · AC only · presentations", "power_mode_awake"))
        qa.submenu?.addItem(act("Deep Only · immediate · travel", "power_mode_deep"))
        qa.submenu?.addItem(NSMenuItem.separator())
        qa.submenu?.addItem(act("Set Custom Values…", "power_mode_custom"))
        menu.addItem(qa)

        // === Sleep Mode submenu ===
        let sl = sub("Sleep Mode")
        sl.submenu?.addItem(act("Normal · macOS handles sleep", "sleep_mode_default"))
        sl.submenu?.addItem(act("Presentation · never sleeps on AC", "sleep_mode_presentation"))
        sl.submenu?.addItem(act("Long Tasks · lid closed, AC required", "sleep_mode_download"))
        sl.submenu?.addItem(act("Travel · battery holds longer (4h)", "sleep_mode_travel"))
        sl.submenu?.addItem(NSMenuItem.separator())
        sl.submenu?.addItem(act("Prepare for Sleep · closes audio apps", "arm_sleep"))
        menu.addItem(sl)

        menu.addItem(NSMenuItem.separator())

        // === Charge Limits submenu ===
        let cl = sub("Charge Limits")
        cl.submenu?.addItem(act("Charge to 100%", "charge_full"))
        cl.submenu?.addItem(act("Custom Limit…", "limit_custom"))
        cl.submenu?.addItem(act("Smart Discharge…", "smart_discharge"))
        cl.submenu?.addItem(act("Hold at Current", "hold_at_current"))
        cl.submenu?.addItem(NSMenuItem.separator())
        let hm = sub("Hold Mode")
        let on = act("With Sailing — battery oscillates", "sail_on")
        on.state = config.sailing ? .on : .off
        hm.submenu?.addItem(on)
        let off = act("Static Hold — frozen at upper", "sail_off")
        off.state = config.sailing ? .off : .on
        hm.submenu?.addItem(off)
        hm.submenu?.addItem(NSMenuItem.separator())
        for g in [5, 10, 15, 30] {
            let it = act("Gap: \(g)%", "sail_gap_set", args: ["\(g)"])
            it.state = (config.gap == g) ? .on : .off
            hm.submenu?.addItem(it)
        }
        hm.submenu?.addItem(act("Gap: Custom…", "sail_gap_set", args: ["custom"]))
        cl.submenu?.addItem(hm)
        menu.addItem(cl)

        // === Battery Care submenu ===
        let bc = sub("Battery Care")
        let cal = sub("Calibration")
        cal.submenu?.addItem(act("Start Calibration", "calibrate"))
        cal.submenu?.addItem(act("Stop Calibration (API)", "cal_stop"))
        cal.submenu?.addItem(act("Force Stop Calibration", "kill_calibrate"))
        bc.submenu?.addItem(cal)
        let clam = sub("Clamshell Mode")
        clam.submenu?.addItem(act("Off — sleep when lid closes", "clam0"))
        clam.submenu?.addItem(act("On — keep running (AC only)", "clam1"))
        clam.submenu?.addItem(act("On + screen — always visible", "clam2"))
        bc.submenu?.addItem(clam)
        let sched = sub("Schedule")
        sched.submenu?.addItem(act("Enable — auto calibration", "sched_on"))
        sched.submenu?.addItem(act("Disable", "sched_off"))
        bc.submenu?.addItem(sched)
        menu.addItem(bc)

        // === System Resources submenu ===
        let sr = sub("System Resources")
        sr.submenu?.addItem(dis("🔋 Battery: \(pct)"))
        sr.submenu?.addItem(dis("🌡️ Temperature: \(temp)"))
        sr.submenu?.addItem(NSMenuItem.separator())
        sr.submenu?.addItem(act("Health Check", "project_health"))
        sr.submenu?.addItem(act("Conflict Check", "conflict_check"))
        sr.submenu?.addItem(act("Verify All Components", "verify"))
        menu.addItem(sr)

        menu.addItem(NSMenuItem.separator())

        // === System Actions ===
        let rf = NSMenuItem(title: "Refresh", action: #selector(ActionTarget.runRefresh(_:)), keyEquivalent: "r")
        rf.target = ActionTarget.shared
        menu.addItem(rf)
        menu.addItem(act("Shutdown BattOpt", "shutdown"))
        menu.addItem(act("Resume BattOpt", "resume"))
        menu.addItem(act("Toggle Login Item", "login_toggle"))

        menu.addItem(NSMenuItem.separator())

        // === About / Quit ===
        let ab = NSMenuItem(title: "About BattOpt", action: #selector(ActionTarget.openAbout), keyEquivalent: "")
        ab.target = ActionTarget.shared
        menu.addItem(ab)
        let qt = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(qt)

        return menu
    }

    private static func dis(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
    private static func sub(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.submenu = NSMenu()
        return i
    }
    private static func act(_ t: String, _ a: String, args: [String] = []) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: #selector(ActionTarget.runDispatch(_:)), keyEquivalent: "")
        i.target = ActionTarget.shared
        i.representedObject = ["action": a, "args": args]
        return i
    }
}
