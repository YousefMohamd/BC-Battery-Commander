// MenuModel.swift — Battery Commander (BC) standalone app, Stage A.
//
// The menu as data: a node tree built from a Snapshot, mirroring the
// CURRENT SwiftBar plugin's rendered menu item-for-item (titles,
// order, separators, checkmarks, dynamic labels, conditional items),
// including the Calibration and Verification sections the plugin has
// today. The same model drives both the real NSMenu and the
// --dump-menu text dump, so the two can never diverge.
//
// Documented deviations from the plugin (design §5.3):
//   1. "Open Battery Commander.app" (open_app) is omitted — the user
//      is already inside the app.
//   2. "Refresh Now" is app-internal (no dispatch action).
//   3. A "Quit Battery Commander" item sits at the menu bottom.
//      Stage A bench behaviour: Quit is a plain UI exit. The amended
//      FR-007 full tool shutdown is a Stage C cutover item.

import Foundation

struct MenuNode {
    var title: String = ""
    var action: String? = nil        // dispatch.sh action name
    var openPath: String? = nil      // /usr/bin/open target (Logs item)
    var special: String? = nil       // "refresh" | "quit"
    var checked: Bool = false
    var disabled: Bool = false
    var color: String? = nil         // "#RRGGBB" or "red"
    var size: Int? = nil
    var isSeparator: Bool = false
    var children: [MenuNode]? = nil

    static func sep() -> MenuNode { MenuNode(isSeparator: true) }
    static func item(_ title: String, action: String? = nil, openPath: String? = nil,
                     special: String? = nil, checked: Bool = false, disabled: Bool = false,
                     color: String? = nil, size: Int? = nil,
                     children: [MenuNode]? = nil) -> MenuNode {
        MenuNode(title: title, action: action, openPath: openPath, special: special,
                 checked: checked, disabled: disabled, color: color, size: size,
                 children: children)
    }
}

private let GRAY = "#909090"
private let ORANGE = "#FF9500"
private let BLUE = "#007AFF"
private let GREEN = "#30D158"
private let DARK = "#505050"
private let WHITE = "#FFFFFF"
private let SEP26 = String(repeating: "─", count: 26)
private let SEP5 = String(repeating: "─", count: 5)

enum MenuModel {

    static func build(from s: Snapshot) -> [MenuNode] {
        if s.stateDirMissing {
            return degraded(stateDirMissing: true, dash: nil, dispatchExists: false)
        }
        var nodes: [MenuNode] = []
        let pctOrQ = s.pct.isEmpty ? "?" : s.pct
        let healthOrQ = s.health.isEmpty ? "?" : s.health
        let cyclesOrQ = s.cycles.isEmpty ? "?" : s.cycles

        // ---- Header statistics block — MOVED (final cleanup
        // 2026-11-18, owner order): the long stats block no longer
        // heads the menu; it renders inside the "Status & Resources"
        // submenu at the menu bottom (built here, appended there).
        var statLines: [MenuNode] = []
        statLines.append(.item("Charge: \(pctOrQ)%", size: 11))
        statLines.append(.item("Mode: \(s.modeText)", size: 11))
        if !s.dischargeStatus.isEmpty {
            statLines.append(.item(s.dischargeStatus, color: ORANGE, size: 11))
        }
        if !s.calibrationStatus.isEmpty {
            statLines.append(.item(s.calibrationStatus, color: ORANGE, size: 11))
        }
        statLines.append(.item("Health: \(healthOrQ)% - \(cyclesOrQ) cycles", color: GRAY, size: 11))
        if !s.temp.isEmpty {
            statLines.append(.item("Temperature: \(s.temp)°C", color: s.alertColor, size: 11))
        }
        if !s.backend.isEmpty {
            statLines.append(.item("Backend: \(s.backend)", color: GRAY, size: 11))
        }
        if let o = s.overnight {
            statLines.append(.item("Overnight: \(o)", color: GRAY, size: 11))
        }
        if let v = s.verificationSummary {
            statLines.append(.item(v, color: GRAY, size: 11))
        }
        if s.iconExt == "Yes" && s.isHold {
            // Option C garnish (Stage C, display only): on AC in
            // hold, the state at lid-close is the state through
            // sleep — say so; change nothing.
            statLines.append(.item("Closing the lid keeps this state during sleep", color: GRAY, size: 11))
        }

        // ---- Charge actions
        let stopPrefix = (s.activeMode == "hold" || s.isHold) ? "✓ " : ""
        nodes.append(.item("\(stopPrefix)Stop Charging Now (hold at \(pctOrQ)%)", action: "stop_now"))
        let cfCheck = s.activeMode == "charge_full" && (s.chargeTarget.isEmpty || s.chargeTarget == "100")
        nodes.append(.item("\(cfCheck ? "✓ " : "")Charge to 100% & Hold", action: "charge_full"))
        if s.dischargeSessionExists {
            // State-aware label (2026-11-14, mirrors the plugin):
            // while a session exists this item CANCELS it (the
            // dispatch action is a toggle) — the label says so.
            // Gate fix (2026-11-15, mirrors the plugin): keyed on
            // the session file's existence — activeMode is never
            // "discharge" for a discharge session, so the old gate
            // was unreachable while a session was armed or parked.
            let target = s.sdTarget.isEmpty ? s.upper : s.sdTarget
            nodes.append(.item("■ Cancel Discharge (to \(target)%)", action: "smart_discharge",
                               color: ORANGE))
            nodes.append(.item("↳ Stop Discharge (hold here)", action: "kill_discharge", color: GRAY))
        } else {
            nodes.append(.item("★ Smart Discharge...", action: "smart_discharge", color: ORANGE))
        }
        nodes.append(.sep())

        
// ---- Charge Limits
        nodes.append(.item("Charge Limits", disabled: true, color: BLUE, size: 11))
        let clPrefix = (s.activeMode == "idle" || s.activeMode == "hold") ? "✓ " : ""
        nodes.append(.item("\(clPrefix)Custom Limit — \(s.upper)% / \(s.lower)%", action: "limit_custom"))
        nodes.append(.item("Remove Hold (return to \(s.upper)%/\(s.lower)%)", action: "remove_limit_hold"))
        nodes.append(.item("Disable All Limits (charge to 100%)", action: "disable_limit", color: GRAY))
        nodes.append(.item("Reset to Defaults", action: "reset_defaults", color: GRAY))
        nodes.append(.sep())

        
// ---- Battery Care: Calibration submenu
        nodes.append(.item("Battery Care", disabled: true, color: BLUE, size: 11))
        var calChildren: [MenuNode] = [
            .item("Full cycle: 100% → health-based floor → 100%", disabled: true, color: GRAY, size: 10),
            .item(SEP26, disabled: true, color: DARK, size: 9),
        ]
        if s.calRunExists {
            if s.calWaiting {
                calChildren.append(.item("Resume Calibration", action: "calibrate_resume", size: 12))
            }
            calChildren.append(.item("Cancel Calibration", action: "calibrate", size: 12))
            calChildren.append(.item("Restores your limit + power settings.", disabled: true, color: GRAY, size: 9))
            calChildren.append(.item("Force Stop Calibration", action: "kill_calibrate", size: 12))
            calChildren.append(.item("Immediate stop if calibration is stuck.", disabled: true, color: GRAY, size: 9))
        } else {
            calChildren.append(.item("Start Calibration", action: "calibrate", size: 12))
            calChildren.append(.item("Floor + emergency stop are chosen automatically from battery health.",
                                     disabled: true, color: GRAY, size: 9))
            calChildren.append(.item("Takes most of a day: charge, rest, drain while you work, rest, recharge.",
                                     disabled: true, color: GRAY, size: 9))
        }
        let calTitle = "Calibration" + (s.activeMode == "calibration" ? " · running" : "")
        nodes.append(.item(calTitle, color: WHITE, size: 14, children: calChildren))
        nodes.append(.sep())

        
// ---- Power & Sleep: Power Mode submenu (header renamed from Quick Actions, redesign 2026-11-15)
        nodes.append(.item("Power & Sleep", disabled: true, color: BLUE, size: 11))
        let pm = s.powerModeKey
        nodes.append(.item("Power Mode — \(s.powerModeName)", color: WHITE, size: 14, children: [
            .item("Fast Sleep", action: "power_mode_fast", checked: pm == "fast", size: 12),
            .item("Sleep 5m · standby 5m · deep hibernate", disabled: true, color: GRAY, size: 9),
            .item("Balanced", action: "power_mode_balanced", checked: pm == "balanced", size: 12),
            .item("Sleep 18m · standby 15m · daily use", disabled: true, color: GRAY, size: 9),
            .item("Always Awake", action: "power_mode_awake", checked: pm == "awake", size: 12),
            .item("Never sleeps · presentations", disabled: true, color: GRAY, size: 9),
            .item("Deep Only", action: "power_mode_deep", checked: pm == "deep", size: 12),
            .item("Sleep 5m · hibernate immediately · travel", disabled: true, color: GRAY, size: 9),
            .item("Set Custom Values…", action: "power_mode_custom", checked: pm == "custom", size: 12),
            .item("Configure manually", disabled: true, color: GRAY, size: 9),
            .item("Active: Bat \(s.pmSleepBat)/\(s.pmDisplayBat)/\(s.pmDiskBat)m · AC \(s.pmSleepAC)m",
                  disabled: true, color: DARK, size: 10),
            .item("Usage: \(s.powerUseWhen)", disabled: true, color: DARK, size: 10),
        ]))

        
// ---- Sleep Mode submenu
        let sm = s.sleepModeState
        nodes.append(.item("Sleep Mode — \(s.sleepModeTitle)", color: BLUE, size: 14, children: [
            .item("Normal", action: "sleep_mode_default", checked: sm == "default", size: 12),
            .item("macOS handles sleep", disabled: true, color: GRAY, size: 9),
            .item("Presentation", action: "sleep_mode_presentation", checked: sm == "presentation", size: 12),
            .item("Never sleeps on AC", disabled: true, color: GRAY, size: 9),
            .item("Stay Awake (Lid Closed)", action: "sleep_mode_download", checked: sm == "download", size: 12),
            .item("Lid closed · AC required · never sleeps", disabled: true, color: GRAY, size: 9),
            .item("Stay Awake (On Battery)", action: "stay_awake_batt_toggle", checked: s.stayAwakeBatt, size: 12),
            .item("Never sleeps on battery · auto-off at 20%", disabled: true, color: GRAY, size: 9),
            .item(SEP26, disabled: true, color: DARK, size: 9),
            .item("Hibernate timing — after the Mac sleeps", disabled: true, color: DARK, size: 9),
            .item("Travel", action: "sleep_mode_travel", checked: sm == "travel", size: 12),
            .item("Battery holds longer (4h)", disabled: true, color: GRAY, size: 9),
            .item("Long Day", action: "sleep_mode_long", checked: sm == "long", size: 12),
            .item("Ready longer on battery + AC", disabled: true, color: GRAY, size: 9),
            .item(SEP26, disabled: true, color: DARK, size: 9),
            .item("Prepare for Sleep", action: "arm_sleep", color: BLUE, size: 12),
            .item("Close audio apps · arm sleep", disabled: true, color: GRAY, size: 9),
        ]))

        
// ---- Sleep Report submenu (the plugin's sleep-report block)
        var sr: [MenuNode] = []
        sr.append(.item("Battery: \(pctOrQ)%", size: 11))
        sr.append(.item("Health: \(healthOrQ)% · \(cyclesOrQ) cycles", color: GRAY, size: 11))
        if !s.temp.isEmpty {
            sr.append(.item("Temperature: \(s.temp)°C",
                            color: s.tempColor.isEmpty ? nil : s.tempColor, size: 11))
        } else {
            sr.append(.item("Temperature: N/A", color: "red", size: 11))
        }
        sr.append(.item("State: \(s.stateText)", size: 11))
        if let sail = s.sailing {
            let gap = (digitsToInt(s.upper) ?? 0) - (digitsToInt(s.lower) ?? 0)
            sr.append(.item(SEP5))
            sr.append(.item("Sailing Range: \(s.lower)%–\(s.upper)% (\(gap)% gap)", color: BLUE, size: 11))
            sr.append(.item("Position: \(sail.position)", color: sail.positionColor, size: 11))
            if !sail.lastTime.isEmpty {
                sr.append(.item("Last change: \(sail.lastTime)", color: GRAY, size: 10))
            }
            let tr = sail.transitions.isEmpty ? "0" : sail.transitions
            sr.append(.item("Transitions: \(tr)", color: GRAY, size: 11))
            if sail.transitions == "0" || (digitsToInt(sail.transitions) ?? 0) < 2 {
                sr.append(.item("Intel Mac: static hold (normal)", color: GRAY, size: 10))
            }
        }
        sr.append(.item(SEP5))
        sr.append(.item(SEP26, disabled: true, color: DARK, size: 9))
        sr.append(.item(s.powerSaverOn ? "✓ Power Saver: ENABLED" : "✗ Power Saver: DISABLED",
                        color: s.powerSaverOn ? GREEN : ORANGE, size: 11))
        sr.append(.item(s.powerNap == "0" ? "✓ Power Nap: OFF" : "✗ Power Nap: ON",
                        color: s.powerNap == "0" ? GREEN : ORANGE, size: 11))
        sr.append(.item(s.womp == "0" ? "✓ Wake on Network: OFF" : "✗ Wake on Network: ON",
                        color: s.womp == "0" ? GREEN : ORANGE, size: 11))
        sr.append(.item(s.tcpKeepAlive == "0" ? "✓ TCP Keep-Alive: OFF" : "✗ TCP Keep-Alive: ON",
                        color: s.tcpKeepAlive == "0" ? GREEN : ORANGE, size: 11))
        sr.append(.item("\(s.standbyMin <= 30 ? "✓" : "✗") Hibernate after: \(s.standbyMin) min",
                        color: s.standbyMin <= 30 ? GREEN : ORANGE, size: 11))
        if s.hibernateMode == "25" {
            sr.append(.item("✓ Deep Hibernate (RAM→Disk)", color: GREEN, size: 11))
        } else if s.hibernateMode == "3" {
            sr.append(.item("✗ Safe Sleep (RAM powered)", color: ORANGE, size: 11))
        } else {
            sr.append(.item("Hibernatemode: \(s.hibernateMode)", color: GRAY, size: 11))
        }
        sr.append(.item(SEP26, disabled: true, color: DARK, size: 9))
        sr.append(.item("Wake events: \(s.wakeCount)", color: GRAY, size: 11))
        sr.append(.item("External USB: \(s.usbExt)", color: GRAY, size: 11))
        sr.append(.item(SEP26, disabled: true, color: DARK, size: 9))
        var issues = ""
        if !s.powerSaverOn { issues += "PS off; " }
        if s.powerNap != "0" { issues += "PN on; " }
        if s.womp != "0" { issues += "WoMP on; " }
        if s.standbyMin > 30 { issues += "Slow hib; " }
        if issues.isEmpty {
            sr.append(.item("✓ All systems optimized", color: GREEN, size: 11))
        } else {
            let trimmed = issues.trimmingCharacters(in: .whitespaces)
            sr.append(.item("Issues: \(trimmed)", color: ORANGE, size: 11))
        }
        sr.append(.item(SEP26, disabled: true, color: DARK, size: 9))
        if s.powerSaverOn {
            sr.append(.item("Disable Power Saver", action: "power_saver_off", size: 12))
        } else {
            sr.append(.item("Enable Power Saver", action: "power_saver_on", color: GREEN, size: 12))
        }
        sr.append(.item("Show Full Report", action: "power_saver_report", size: 12))
        nodes.append(.item("Sleep Report: \(s.powerSaverOn ? "OPTIMIZED" : "STANDARD")",
                           color: GRAY, children: sr))

        
// ---- Auto Cleanup submenu
        var ac: [MenuNode] = [
            .item("Auto-pauses background services when idle", color: GRAY, size: 10),
            .item("(Spotlight, Photos, Time Machine, VLC)", color: GRAY, size: 10),
            .item("Trigger: after 15 min idle", color: GRAY, size: 10),
            .item("Current idle: \(s.idleMin) min", color: GRAY, size: 11),
            .item("Last cleanup: \(s.cleanupDone ? "YES" : "NO")", color: GRAY, size: 11),
            .item(SEP26, disabled: true, color: DARK, size: 9),
            .item("Run Cleanup Now", action: "pre_sleep_now", size: 12),
            .item("Pause Spotlight, Photos, Time Machine, VLC now", color: GRAY, size: 10),
            .item("Restore Services", action: "post_wake_now", size: 12),
            .item("Resume all paused services", color: GRAY, size: 10),
        ]
        if s.autoCleanupOn {
            ac.append(.item("Disable Auto Cleanup", action: "auto_cleanup_toggle", size: 12))
            ac.append(.item("Stop auto-cleanup only (other features keep working)", color: GRAY, size: 10))
        } else {
            ac.append(.item("Enable Auto Cleanup", action: "auto_cleanup_toggle", color: GREEN, size: 12))
            ac.append(.item("Auto-pause services after 15 min idle", color: GRAY, size: 10))
        }
        nodes.append(.item("Auto Cleanup: \(s.autoCleanupOn ? "ON" : "OFF")", color: GRAY, children: ac))

        nodes.append(.sep())

        // ---- Reports & Verification (new group, redesign 2026-11-15)
        nodes.append(.item("Reports & Verification", disabled: true, color: BLUE, size: 11))
        // ---- Reports row
        nodes.append(.item("Refresh Now", special: "refresh"))
        nodes.append(.item("Show Full Status...", action: "details"))
        nodes.append(.item("Sleep & Battery Report", action: "sleep_report"))
        nodes.append(.item("Overnight Report", action: "overnight_report"))
        nodes.append(.item("Save Report (silent)", action: "sleep_report_save"))
        nodes.append(.item("Open Reports Folder", action: "open_reports"))

        // ---- Verification submenu
        var vsChildren: [MenuNode] = []
        func vsVal(_ vs: [String: String], _ key: String, _ def: String) -> String {
            let v = vs[key] ?? ""
            return v.isEmpty ? def : v
        }
        if let vs = s.verificationState {
            let cycle = vs["LAST_CYCLE"] ?? ""
            if !cycle.isEmpty && cycle != "—" {
                vsChildren.append(.item("Last full cycle: \(cycle) — \(vs["LAST_CYCLE_VERDICT"] ?? "")",
                                        color: GRAY, size: 11))
            } else {
                vsChildren.append(.item("Last full cycle: — (none yet)", color: GRAY, size: 11))
            }
            vsChildren.append(.item("Holds (24h): \(vsVal(vs, "HOLDS_PASS", "0"))/\(vsVal(vs, "HOLDS_24H", "0")) PASS",
                                    color: GRAY, size: 11))
            let sn = vs["SLEEP_NIGHTS_7D"] ?? ""
            if !sn.isEmpty && sn != "0" {
                let sbc = vs["SLEEP_BC_INVOLVED"] ?? ""
                let bcTxt = (sbc.isEmpty || sbc == "0") ? "never" : "\(sbc) night(s)"
                vsChildren.append(.item("Sleep (7d): \(sn) nights · median \(vs["SLEEP_MEDIAN_PCT_H"] ?? "")%/h · BC involved: \(bcTxt)",
                                        color: GRAY, size: 11))
            } else {
                vsChildren.append(.item("Sleep (7d): — (no nights yet)", color: GRAY, size: 11))
            }
            vsChildren.append(.item("Limit changes (7d): \(vsVal(vs, "LIMIT_CHANGES_7D", "0")) · slowest enforcement: \(vsVal(vs, "LIMIT_MAX_LATENCY_S", "—"))",
                                    color: GRAY, size: 11))
            vsChildren.append(.item("Overshoot max (7d): \(vsVal(vs, "OVERSHOOT_MAX_7D", "—"))",
                                    color: GRAY, size: 11))
            vsChildren.append(.item("Phase C: \(vsVal(vs, "PHASE_C", "—"))", color: GRAY, size: 11))
        } else {
            vsChildren.append(.item("No verification data yet", color: GRAY, size: 11))
        }
        vsChildren.append(.item("Open Verification Report", action: "verification_report", size: 12))
        vsChildren.append(.item("Re-run Verification", action: "verify_now", size: 12))
        nodes.append(.item("Verification", color: WHITE, size: 14, children: vsChildren))

        nodes.append(.sep())

        
        // ---- Services & Maintenance (new group, redesign 2026-11-15)
        nodes.append(.item("Services & Maintenance", disabled: true, color: BLUE, size: 11))
        // ---- Developer Tools submenu
        nodes.append(.item("Developer Tools", color: BLUE, size: 11, children: [
            .item("Project Health Check", action: "project_health", size: 12),
            .item("Verify all components", disabled: true, color: GRAY, size: 10),
            .item("Conflict Detection", action: "conflict_check", size: 12),
            .item("Find tools that clash", disabled: true, color: GRAY, size: 10),
            .item("Predictive Analysis", action: "predictive", size: 12),
            .item("Detect trends before problems", disabled: true, color: GRAY, size: 10),
            .item("Process Monitor", action: "process_monitor", size: 12),
            .item("Auto-fix process loops", disabled: true, color: GRAY, size: 10),
        ]))

        
// ---- Logs submenu
        nodes.append(.item("Logs", color: BLUE, size: 11, children: [
            .item("AI Diagnostic Bundle", action: "logs_ai_bundle", color: GREEN, size: 12),
            .item("Collects everything for AI analysis", color: GRAY, size: 10),
            .item(SEP5),
            .item("Actions Log", action: "logs_actions"),
            .item("Battery control operations", color: GRAY, size: 10),
            .item("Sailing History", action: "logs_sailing"),
            .item("Battery transitions", color: GRAY, size: 10),
            .item("Arm Log", action: "logs_arm"),
            .item("Pre-sleep preparations", color: GRAY, size: 10),
            .item("Daemon Logs", action: "logs_daemon"),
            .item("BC daemon activity", color: GRAY, size: 10),
        ]))

        nodes.append(.item("Force Reset", action: "force_reset", color: GRAY))
        nodes.append(.item("Open Battery Commander (BC) Logs", openPath: s.dash))
        nodes.append(.item("\(s.loginState > 0 ? "✓ " : "")Launch at Login", action: "login_toggle"))
        nodes.append(.sep())

// ---- Status & Resources submenu (final cleanup 2026-11-18):
        // the header statistics block (statLines, built at the top of
        // this function) + the old System Resources lines + the tool's
        // own CPU/RAM footprint, grouped in one submenu.
        var srNodes: [MenuNode] = statLines
        srNodes.append(.sep())
        for dl in s.daemonLines {
            srNodes.append(.item(dl.text, color: dl.color, size: 11))
        }
        srNodes.append(.item("Services: \(s.agentCount) agents loaded", color: GRAY, size: 11))
        if !s.usageLines.isEmpty {
            srNodes.append(.sep())
            for ul in s.usageLines {
                srNodes.append(.item(ul.text, color: ul.color, size: 11))
            }
        }
        nodes.append(.item("Status & Resources", color: WHITE, size: 14, children: srNodes))

        // Deviation §5.3.3: Quit at the menu bottom (Stage A: plain exit).
        nodes.append(.sep())
        // Deviation §5.3.1: "Open Battery Commander.app" (open_app) omitted.
        nodes.append(.item("About Battery Commander (BC)...", action: "about"))
        nodes.append(.item("Quit Battery Commander", special: "quit", color: "red"))

        if !s.dispatchExists {
            // Design §9: status display keeps working; actions disabled
            // with a note line at the menu top.
            nodes = disableActions(nodes)
            nodes.insert(.item("dispatch.sh missing — actions disabled", disabled: true, color: "red"),
                         at: 0)
        }
        return nodes
    }

    private static func disableActions(_ nodes: [MenuNode]) -> [MenuNode] {
        nodes.map { n in
            var m = n
            if m.action != nil { m.disabled = true }
            if let ch = m.children { m.children = disableActions(ch) }
            return m
        }
    }

    /// Design §9 degraded menu (state dir missing, or bc-status down
    /// twice in a row): never a crash, never a fallback to the old dir.
    static func degraded(stateDirMissing: Bool, dash: String?, dispatchExists: Bool) -> [MenuNode] {
        var nodes: [MenuNode] = [
            .item("Battery Commander: status unavailable", disabled: true),
        ]
        if dispatchExists {
            nodes.append(.item("About Battery Commander (BC)...", action: "about"))
        }
        if let d = dash {
            nodes.append(.item("Open Battery Commander (BC) Logs", openPath: d))
        }
        nodes.append(.item("Refresh Now", special: "refresh"))
        nodes.append(.sep())
        nodes.append(.item("Quit Battery Commander", special: "quit", color: "red"))
        return nodes
    }

    // MARK: - Canonical dump (parity checking)

    static func dump(title: String, color: String, nodes: [MenuNode]) -> String {
        var out = "TITLE: \(title) [color=\(color)]\n"
        for n in nodes { dumpNode(n, depth: 0, into: &out) }
        return out
    }

    private static func dumpNode(_ n: MenuNode, depth: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        if n.isSeparator {
            out += "\(indent)---\n"
            return
        }
        var line = indent
        if n.checked { line += "[x] " }
        line += n.title
        if let a = n.action { line += " [action:\(a)]" }
        if let o = n.openPath { line += " [open:\(o)]" }
        if let sp = n.special { line += " [\(sp)]" }
        if n.disabled { line += " [disabled]" }
        if let c = n.color { line += " [color=\(c)]" }
        out += line + "\n"
        if let ch = n.children {
            for c in ch { dumpNode(c, depth: depth + 1, into: &out) }
        }
    }
}
