// StatusProvider.swift — Battery Commander (BC) standalone app, Stage A.
//
// A line-by-line port of the SwiftBar plugin's data collection
// (battery-commander.10s.sh, W2 status path). Same sources, same order,
// same guards, same fallback rules — so the app's values cannot drift
// from the plugin's proven rendering:
//   bc-status (allow-listed "Key: value") + ioreg + canonical config,
//   with display_state.sh as the SOLE icon/colour decider (executed,
//   never re-implemented), pmset for the power/sleep sections, and the
//   state-dir files for the dynamic elements.
//
// The app adds NO writes anywhere: where the plugin refreshes a cache
// file (.status_cache/.login_cache/.usb_cache/.wake_cache), the app
// only READS a fresh cache and otherwise computes the same value
// itself. The plugin's notification/audit side effects are NOT ported
// (they stay the plugin's/watchdog's job during coexistence).

import Foundation

struct SailingInfo {
    var transitions: String
    var lastTime: String
    var position: String
    var positionColor: String
}

struct DaemonLine {
    var text: String
    var color: String?
}

struct Snapshot {
    // Environment
    var dash: String = ""
    var stateDirMissing = false
    var dispatchPath: String = ""
    var dispatchExists = false

    // Session / config
    var activeMode: String = "idle"      // post display_state.sh update
    var upper: String = "86"
    var lower: String = "85"

    // bc-status (allow-listed keys)
    var bcStatusOK = false
    var pct: String = ""                 // plugin PCT (bc-status, SMC fallback)
    var health: String = ""
    var cycles: String = ""
    var temp: String = ""                // integer part, as the plugin renders
    var bclm: String = ""
    var backend: String = ""

    // ioreg
    var smcPct: String = "?"             // plugin SMC_PCT (title %)
    var iconExt: String = ""
    var iconIsChg: String = ""
    var iconNcr: String = "0"
    var isCharging = false
    var isDischarging = false
    var isHold = false

    // display_state.sh verdict
    var icon: String = ""
    var finalColor: String = "#909090"   // token after "color="
    var dischargeStatus: String = ""
    var calibrationStatus: String = ""

    var neutral = false
    var modeText: String = "Unknown"
    var stateText: String = ""
    var tempColor: String = ""           // $TEMP_COLOR (may be empty)
    var alertColor: String = "#909090"   // resolved ${ALERT_COLOR:-color=#909090}

    // Header extras
    var overnight: String? = nil
    var verificationSummary: String? = nil

    // pmset sections
    var pmSleepBat = "?", pmDisplayBat = "?", pmDiskBat = "?", pmHibBat = "?", pmSleepAC = "?"
    var powerModeName = "Custom", powerModeKey = "custom", powerUseWhen = "manual values"
    var sleepModeState = "default", sleepModeTitle = "Normal"

    // Charge/session items
    var chargeTarget: String = ""
    var sdTarget: String = ""
    var dischargeSessionExists = false   // .discharge_session file present (label gate, 2026-11-15)

    // Calibration
    var calRunExists = false
    var calWaiting = false

    // Reports/mid sections
    var verificationState: [String: String]? = nil
    var loginState = 0
    var powerSaverOn = false
    var powerNap = "0", womp = "0", tcpKeepAlive = "0", hibernateMode = "3"
    var standbyMin = 70
    var usbExt = "0"
    var wakeCount = "0"
    var sailing: SailingInfo? = nil
    var autoCleanupOn = false
    var idleMin = 0
    var cleanupDone = false

    // System resources
    var daemonLines: [DaemonLine] = []
    var agentCount = 0

    // Final cleanup 2026-11-18: Stay Awake (On Battery) toggle state
    // (.stay_awake_batt marker) + the tool's own CPU/RAM footprint
    // lines for the Status & Resources submenu.
    var stayAwakeBatt = false
    var usageLines: [DaemonLine] = []

    var titleText: String { "\(icon) \(smcPct)%" }
}

enum StatusProvider {

    static var dashPath: String? {
        if let override = ProcessInfo.processInfo.environment["BC_DASH"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let d = (home as NSString).appendingPathComponent(".battery-commander")
        return FileManager.default.fileExists(atPath: d) ? d : nil
    }

    static func collect() -> Snapshot {
        var s = Snapshot()
        let fm = FileManager.default
        guard let dash = dashPath else {
            s.stateDirMissing = true
            return s
        }
        s.dash = dash
        s.dispatchPath = (dash as NSString).appendingPathComponent("dispatch.sh")
        s.dispatchExists = fm.isExecutableFile(atPath: s.dispatchPath)

        // --- Session mode (state_guard.sh read_effective_session port:
        // pure read of .active_mode, validated against the known set).
        let rawMode = readFileStripped((dash as NSString).appendingPathComponent(".active_mode")) ?? ""
        let modeTrimmed = rawMode.components(separatedBy: .whitespacesAndNewlines).joined()
        if ["hold", "discharge", "charge_full", "calibration", "idle"].contains(modeTrimmed) {
            s.activeMode = modeTrimmed
        } else {
            s.activeMode = "idle"
        }

        // --- Canonical config (allow-list parse, canonical defaults).
        var lastUpper = "86", lastLower = "85"
        if let cfg = readFile((dash as NSString).appendingPathComponent("config")) {
            for line in cfg.components(separatedBy: "\n") {
                guard let kv = splitFirst(line, "=") else { continue }
                switch kv.head {
                case "LAST_UPPER": lastUpper = kv.tail
                case "LAST_LOWER": lastLower = kv.tail
                default: break
                }
            }
        }
        if !isAllDigits(lastUpper) { lastUpper = "86" }
        if !isAllDigits(lastLower) { lastLower = "85" }
        s.upper = lastUpper
        s.lower = lastLower

        // --- bc-status (plugin: 20 s .status_cache TTL; app reads a
        // fresh cache, otherwise runs bc-status itself — no writes).
        // bc-status resolves from the runtime state dir, never from a
        // build tree (root-cause fix 2026-11-19: the old default pointed
        // into the developer's project folder, so any machine without
        // that exact tree — including this one after the project moved —
        // showed "status unavailable").
        let bcStatusPath = (dash as NSString).appendingPathComponent("bc-status")
        var bcOut = ""
        let cachePath = (dash as NSString).appendingPathComponent(".status_cache")
        if let age = fileAgeSeconds(cachePath), age < 20, let cached = readFile(cachePath), !cached.isEmpty {
            bcOut = cached
        } else if fm.isExecutableFile(atPath: bcStatusPath) {
            let r = Shell.run(bcStatusPath)
            if r.status == 0 { bcOut = r.stdout }
        }
        if !bcOut.isEmpty {
            s.bcStatusOK = true
            func bcValue(_ key: String) -> String? {
                for line in bcOut.components(separatedBy: "\n") {
                    if line.hasPrefix("\(key):") {
                        var v = line
                        if let kv = splitFirst(v, ": ") { v = kv.tail }
                        return v.components(separatedBy: .whitespacesAndNewlines).joined()
                    }
                }
                return nil
            }
            func intPart(_ v: String) -> String {
                var t = v
                if let dot = splitFirst(t, ".") { t = dot.head }
                return t
            }
            if var v = bcValue("Capacity") {
                if v.hasSuffix("%") { v.removeLast() }
                let p = intPart(v)
                if isAllDigits(p) { s.pct = p }
            }
            if var v = bcValue("Health") {
                if v.hasSuffix("%") { v.removeLast() }
                let h = intPart(v)
                if isAllDigits(h) { s.health = h }
            }
            if let v = bcValue("Cycle"), isAllDigits(v) { s.cycles = v }
            if var v = bcValue("TempBatteryPack") {
                if v.hasSuffix("C") { v.removeLast() }
                let t = intPart(v)
                if isAllDigits(t) { s.temp = t }
            }
            if let v = bcValue("BCLM"), v == "10" || v == "100" { s.bclm = v }
            if let v = bcValue("Backend") { s.backend = v }
        }

        // --- ioreg (hardware truth).
        let ioreg = Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]).stdout
        s.iconExt = firstCapture("\"ExternalConnected\" = ([A-Za-z]+)", in: ioreg) ?? ""
        s.iconIsChg = firstCapture("\"IsCharging\" = ([A-Za-z]+)", in: ioreg) ?? ""
        s.iconNcr = firstCapture("\"NotChargingReason\"=([0-9]+)", in: ioreg) ?? "0"
        let curCap = firstCapture("\"CurrentCapacity\" = ([0-9]+)", in: ioreg) ?? ""
        let maxCap = firstCapture("\"MaxCapacity\" = ([0-9]+)", in: ioreg) ?? ""
        if let cur = digitsToInt(curCap), let max = digitsToInt(maxCap), max > 0 {
            s.smcPct = String((cur * 100 + max / 2) / max)
        } else {
            s.smcPct = "?"
        }
        if s.pct.isEmpty && s.smcPct != "?" { s.pct = s.smcPct }
        s.isCharging = (s.iconIsChg == "Yes")
        s.isDischarging = (s.iconExt == "No" && s.iconIsChg == "No")
        if s.bclm == "10" && s.iconExt == "Yes" && s.iconIsChg == "No" {
            s.isHold = true
        } else if s.bclm.isEmpty && s.iconNcr == "14" && s.iconExt == "Yes" && s.iconIsChg == "No" {
            s.isHold = true   // secondary hint only (BCLM unreadable)
        }

        // --- display_state.sh: the SOLE icon/colour decider (executed).
        var displayOK = false
        let helperDash = (dash as NSString).appendingPathComponent("display_state.sh")
        let helperPath = fm.isExecutableFile(atPath: helperDash) ? helperDash : ""
        if !helperPath.isEmpty {
            let env = [
                "DISPLAY_MODE": s.activeMode,
                "TEMP_INT": s.temp,
                "PCT_IN": s.pct,
                "LIMIT_IN": s.upper,
                "BCLM_IN": s.bclm,
            ]
            let out = Shell.run(helperPath, env: env).stdout
            var icon = "", finalColor = ""
            for line in out.components(separatedBy: "\n") {
                guard let kv = splitFirst(line, "=") else { continue }
                switch kv.head {
                case "DISPLAY_MODE": s.activeMode = kv.tail
                case "ICON": icon = kv.tail
                case "FINAL_COLOR": finalColor = kv.tail
                case "DISCHARGE_STATUS": s.dischargeStatus = kv.tail
                case "CALIBRATION_STATUS": s.calibrationStatus = kv.tail
                default: break
                }
            }
            if !icon.isEmpty && !finalColor.isEmpty {
                displayOK = true
                s.icon = icon
                s.finalColor = finalColor.hasPrefix("color=") ? String(finalColor.dropFirst(6)) : finalColor
            }
        }
        if !displayOK {
            // Minimal safe default only (plugin's documented fallback).
            if s.iconIsChg == "Yes" {
                s.icon = "⚡"; s.finalColor = "#707070"
            } else if s.iconExt == "Yes" {
                s.icon = "🔌"; s.finalColor = "#FFFFFF"
            } else {
                // Discharge mode (icon fix, 2026-11-16): while
                // bc-limit holds the manager discharge mode the
                // adapter path is dropped (EXT=No) — the engage
                // marker + live session classify the state as
                // discharge (battery), not plain battery use
                // (red circle). Mirrors display_state.sh.
                var sessStarted = ""
                if let sess = readFile((dash as NSString).appendingPathComponent(".discharge_session")) {
                    for line in sess.components(separatedBy: "\n") where line.hasPrefix("STARTED=") {
                        sessStarted = String(line.dropFirst("STARTED=".count)).trimmingCharacters(in: .whitespaces)
                    }
                }
                var markStarted = ""
                if let mark = readFile((dash as NSString).appendingPathComponent(".bc-limit-acengage")) {
                    for line in mark.components(separatedBy: "\n") where line.hasPrefix("STARTED=") {
                        markStarted = String(line.dropFirst("STARTED=".count)).trimmingCharacters(in: .whitespaces)
                    }
                }
                if !sessStarted.isEmpty && sessStarted == markStarted {
                    s.icon = "🔋"; s.finalColor = "#8A9AAB"
                } else {
                    s.icon = "🔴"; s.finalColor = "#E8A0A0"
                }
            }
        }

        // --- MODE text (plugin's case table, post-display update).
        let pctOrQ = s.pct.isEmpty ? "?" : s.pct
        switch s.activeMode {
        case "charge_full": s.modeText = "Charging to 100%"
        case "calibration": s.modeText = "Calibrating"
        case "discharge": s.modeText = "Discharging to \(s.upper)%"
        case "hold": s.modeText = "Holding at \(pctOrQ)%"
        default:
            if s.iconIsChg == "Yes" {
                if let p = digitsToInt(s.pct), let u = digitsToInt(s.upper), p < u {
                    s.modeText = "Topping to \(s.upper)%"
                } else {
                    s.modeText = "Charging"
                }
            } else if s.iconExt == "Yes" && s.iconIsChg == "No" {
                if let p = digitsToInt(s.pct), let u = digitsToInt(s.upper) {
                    if p > u { s.modeText = "Above limit (\(s.pct)% / \(s.upper)%)" }
                    else if p == u { s.modeText = "Holding at \(s.upper)%" }
                    else { s.modeText = "Below limit (\(s.pct)% / \(s.upper)%)" }
                } else if !s.upper.isEmpty {
                    s.modeText = "Holding at \(s.upper)%"
                } else {
                    s.modeText = "On adapter"
                }
            } else if s.iconExt == "No" {
                s.modeText = "On battery"
            } else {
                s.modeText = "Unknown"
            }
        }

        // --- STATE text (sleep report).
        if s.iconIsChg == "Yes" { s.stateText = "charging" }
        else if s.iconExt == "Yes" { s.stateText = "no charging" }
        else { s.stateText = "discharging" }

        // --- Temperature colours.
        let tempInt = digitsToInt(s.temp)
        if let t = tempInt, t >= 42 {
            s.tempColor = "#FF3B30"; s.alertColor = "#FF3B30"
        } else if let t = tempInt, t >= 38 {
            s.tempColor = "#FF9500"; s.alertColor = "#FF9500"
        } else {
            s.tempColor = ""; s.alertColor = "#909090"
        }

        // --- Neutral render (ioreg missing/invalid only).
        if s.smcPct == "?" || s.iconExt.isEmpty || s.iconIsChg.isEmpty {
            s.neutral = true
            s.icon = "⏳"
            s.finalColor = "#909090"
        }

        // --- Header extra lines.
        if let o = readFileStripped((dash as NSString).appendingPathComponent(".overnight_summary")) {
            s.overnight = o
        }
        if let v = readFileStripped((dash as NSString).appendingPathComponent(".verification_summary")) {
            s.verificationSummary = v
        }

        // --- pmset -g custom (power mode determination).
        let pmsetCustom = Shell.run("/usr/bin/pmset", ["-g", "custom"]).stdout
        var section = ""
        for line in pmsetCustom.components(separatedBy: "\n") {
            if line == "Battery Power:" { section = "bat"; continue }
            if line == "AC Power:" { section = "ac"; continue }
            if section.isEmpty { continue }
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 2 else { continue }
            let (key, val) = (toks[0], toks[1])
            if section == "bat" {
                switch key {
                case "sleep": if s.pmSleepBat == "?" { s.pmSleepBat = val }
                case "displaysleep": if s.pmDisplayBat == "?" { s.pmDisplayBat = val }
                case "disksleep": if s.pmDiskBat == "?" { s.pmDiskBat = val }
                case "hibernatemode": if s.pmHibBat == "?" { s.pmHibBat = val }
                default: break
                }
            } else if section == "ac" && key == "sleep" {
                if s.pmSleepAC == "?" { s.pmSleepAC = val }
            }
        }
        if s.pmSleepBat == "5" && s.pmDisplayBat == "5" {
            s.powerModeName = "Fast Sleep"; s.powerModeKey = "fast"; s.powerUseWhen = "leaving office"
        } else if s.pmSleepBat == "18" && s.pmDisplayBat == "10" {
            s.powerModeName = "Balanced"; s.powerModeKey = "balanced"; s.powerUseWhen = "daily use"
        } else if s.pmSleepBat == "60" && s.pmDisplayBat == "15" {
            s.powerModeName = "Always Awake"; s.powerModeKey = "awake"; s.powerUseWhen = "presentations"
        } else if s.pmSleepBat == "0" && s.pmHibBat == "25" {
            s.powerModeName = "Deep Only"; s.powerModeKey = "deep"; s.powerUseWhen = "travel / storage"
        } else {
            s.powerModeName = "Custom"; s.powerModeKey = "custom"; s.powerUseWhen = "manual values"
        }

        // --- Sleep mode state file.
        s.sleepModeState = readFileStripped((dash as NSString).appendingPathComponent(".sleep_mode")) ?? "default"
        switch s.sleepModeState {
        case "presentation": s.sleepModeTitle = "Presentation"
        case "download": s.sleepModeTitle = "Stay Awake (Lid Closed)"
        case "travel": s.sleepModeTitle = "Travel"
        case "long": s.sleepModeTitle = "Long Day"
        default: s.sleepModeTitle = "Normal"
        }

        // --- Session files.
        s.chargeTarget = readFileStripped((dash as NSString).appendingPathComponent(".charge_target")) ?? ""
        // Label gate (2026-11-15, mirrors the plugin fix): the
        // Cancel Discharge label keys on the session file itself —
        // activeMode is never "discharge" for a discharge session,
        // so the old gate was unreachable while a session existed.
        s.dischargeSessionExists = fm.fileExists(atPath: (dash as NSString).appendingPathComponent(".discharge_session"))
        // Discharge target for the state-aware menu label: the live
        // session file's TARGET is the truth (mirrors the plugin);
        // the legacy .sd_watch value is the fallback.
        var sdFromSession = ""
        if let sess = readFile((dash as NSString).appendingPathComponent(".discharge_session")) {
            for line in sess.components(separatedBy: "\n") where line.hasPrefix("TARGET=") {
                let v = String(line.dropFirst("TARGET=".count)).trimmingCharacters(in: .whitespaces)
                if isAllDigits(v) { sdFromSession = v }
            }
        }
        if !sdFromSession.isEmpty {
            s.sdTarget = sdFromSession
        } else {
            let sdRaw = readFileStripped((dash as NSString).appendingPathComponent(".sd_watch")) ?? ""
            s.sdTarget = isAllDigits(sdRaw) ? sdRaw : ""   // corrupt file: plugin deletes it; app only reads
        }
        let calRunPath = (dash as NSString).appendingPathComponent(".calibration_run")
        s.calRunExists = fm.fileExists(atPath: calRunPath)
        if s.calRunExists, let run = readFile(calRunPath) {
            s.calWaiting = run.components(separatedBy: "\n").contains { $0.hasPrefix("WAITING=1") }
        }

        // --- Verification state (read-only render of .verification_state).
        if let vsText = readFile((dash as NSString).appendingPathComponent(".verification_state")) {
            var vs: [String: String] = [:]
            for line in vsText.components(separatedBy: "\n") {
                guard let kv = splitFirst(line, "=") else { continue }
                if vs[kv.head] == nil { vs[kv.head] = kv.tail }
            }
            s.verificationState = vs
        }

        // --- Login item (plugin: 1 h .login_cache; app reads cache,
        // otherwise runs the same osascript query — no write).
        let loginCache = (dash as NSString).appendingPathComponent(".login_cache")
        if let age = fileAgeSeconds(loginCache), age < 3600,
           let v = readFileStripped(loginCache), let n = digitsToInt(v) {
            s.loginState = n
        } else {
            let out = Shell.run("/usr/bin/osascript",
                ["-e", "tell application \"System Events\" to get the name of every login item"]).stdout
            s.loginState = (out.contains("BattOpt") || out.contains("BatteryCommander")
                            || out.contains("Battery Commander")) ? 1 : 0
        }

        // --- pmset -g values (power saver block).
        s.powerSaverOn = fm.fileExists(atPath: (dash as NSString).appendingPathComponent(".power_saver"))
        let pmsetG = Shell.run("/usr/bin/pmset", ["-g"]).stdout
        func pmValue(_ key: String, _ def: String) -> String {
            for line in pmsetG.components(separatedBy: "\n") {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if toks.count >= 2 && toks[0] == key { return toks[1] }
            }
            return def
        }
        s.powerNap = pmValue("powernap", "0")
        s.womp = pmValue("womp", "0")
        s.tcpKeepAlive = pmValue("tcpkeepalive", "0")
        s.hibernateMode = pmValue("hibernatemode", "3")
        var standbyDelay = pmValue("standbydelayhigh", "")
        if standbyDelay.isEmpty { standbyDelay = pmValue("standbydelay", "") }
        if !isAllDigits(standbyDelay) { standbyDelay = "4200" }
        s.standbyMin = (digitsToInt(standbyDelay) ?? 4200) / 60

        // --- USB external count (plugin: 300 s .usb_cache).
        let usbCache = (dash as NSString).appendingPathComponent(".usb_cache")
        if let age = fileAgeSeconds(usbCache), age < 300, let v = readFileStripped(usbCache) {
            s.usbExt = isAllDigits(v) ? v : "0"
        } else {
            let out = Shell.run("/usr/sbin/system_profiler", ["SPUSBDataType"]).stdout
            let n = out.components(separatedBy: "\n").filter { $0.contains("Wireless Device") }.count
            s.usbExt = String(n)
        }

        // --- Wake events (plugin: 600 s .wake_cache).
        let wakeCache = (dash as NSString).appendingPathComponent(".wake_cache")
        if let age = fileAgeSeconds(wakeCache), age < 600, let v = readFileStripped(wakeCache) {
            s.wakeCount = v.isEmpty ? "0" : v
        } else {
            let out = Shell.run("/usr/bin/pmset", ["-g", "log"]).stdout
            let n = out.components(separatedBy: "\n").filter {
                $0.range(of: "Wake from|DarkWake", options: .regularExpression) != nil
            }.count
            s.wakeCount = String(n)
        }

        // --- Sailing (limits from config, metadata from .sailing_state).
        if let sailText = readFile((dash as NSString).appendingPathComponent(".sailing_state")) {
            var transitions = "", lastTime = ""
            for line in sailText.components(separatedBy: "\n") {
                guard let kv = splitFirst(line, "=") else { continue }
                switch kv.head {
                case "TRANSITIONS": transitions = kv.tail
                case "LAST_TIME": lastTime = kv.tail
                default: break
                }
            }
            if let up = digitsToInt(s.upper), let lo = digitsToInt(s.lower) {
                var pos = "mid (\(s.pct.isEmpty ? "?" : s.pct)%)"
                var posColor = "#30D158"
                if let p = digitsToInt(s.pct), p >= up {
                    pos = "at upper (\(s.upper)%)"; posColor = "#FF9500"
                } else if let p = digitsToInt(s.pct), p <= lo {
                    pos = "at lower (\(s.lower)%)"; posColor = "#FF9500"
                }
                s.sailing = SailingInfo(transitions: transitions, lastTime: lastTime,
                                        position: pos, positionColor: posColor)
            }
        }

        // --- Auto cleanup block.
        s.autoCleanupOn = fm.fileExists(atPath: (dash as NSString).appendingPathComponent(".auto_cleanup"))
        let hid = Shell.run("/usr/sbin/ioreg", ["-c", "IOHIDSystem"]).stdout
        var idleNs = 0
        for line in hid.components(separatedBy: "\n") where line.contains("HIDIdleTime") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let last = toks.last, let v = digitsToInt(last) { idleNs = v }
            break
        }
        s.idleMin = idleNs / 1_000_000_000 / 60
        s.cleanupDone = fm.fileExists(atPath: (dash as NSString).appendingPathComponent(".pre_sleep_done"))

        // --- BC limit daemon liveness (from its own log, as the plugin).
        let daemonLogPath = (dash as NSString).appendingPathComponent("bc-limit-daemon.log")
        if fm.fileExists(atPath: daemonLogPath) {
            let log = readFile(daemonLogPath) ?? ""
            let stateLines = log.components(separatedBy: "\n").filter { $0.contains("state:") }
            if let last = stateLines.last {
                let ts = firstCapture("^\\[([0-9-]+ [0-9:]+)\\]", in: last) ?? ""
                let tsValid = ts.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$",
                                        options: .regularExpression) != nil
                var epoch = 0
                if tsValid {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    if let d = df.date(from: ts) { epoch = Int(d.timeIntervalSince1970) }
                }
                let age = Int(Date().timeIntervalSince1970) - epoch
                let dPct = firstCapture("pct=([0-9]+)", in: last) ?? ""
                let dBclm = firstCapture("BCLM=([0-9]+)", in: last) ?? ""
                let dChg = firstCapture("charging=([0-9]+)", in: last) ?? ""
                let dfDay = DateFormatter()
                dfDay.locale = Locale(identifier: "en_US_POSIX")
                dfDay.dateFormat = "yyyy-MM-dd"
                let today = dfDay.string(from: Date())
                let writes = log.components(separatedBy: "\n")
                    .filter { $0.contains(today) && $0.contains("WRITE:") }.count
                let dMode = dChg == "1" ? "charging" : (dBclm == "10" ? "holding" : "idle")
                if epoch > 0 && age <= 180 {
                    s.daemonLines = [
                        DaemonLine(text: "BC limit daemon: active — last tick \(ts) (\(age)s ago)", color: "#909090"),
                        DaemonLine(text: "Daemon state: \(dPct)% · BCLM=\(dBclm) · \(dMode) · writes today: \(writes)", color: "#909090"),
                    ]
                } else {
                    s.daemonLines = [
                        DaemonLine(text: "BC limit daemon: NO TICK since \(tsValid ? ts : "never") — check daemon", color: "#FF9500"),
                    ]
                }
            } else {
                s.daemonLines = [
                    DaemonLine(text: "BC limit daemon: NO TICK since never — check daemon", color: "#FF9500"),
                ]
            }
        } else {
            s.daemonLines = [
                DaemonLine(text: "BC limit daemon: log missing — cannot verify", color: "#FF9500"),
            ]
        }

        // --- Services count.
        let lc = Shell.run("/bin/launchctl", ["list"]).stdout
        s.agentCount = lc.components(separatedBy: "\n").filter { $0.contains("com.batterycommander") }.count

        // --- Stay Awake (On Battery) marker (final cleanup
        // 2026-11-18: dispatch's stay_awake_batt_toggle owns the
        // marker; the watchdog guard owns auto-revert at <=20%).
        s.stayAwakeBatt = fm.fileExists(atPath: (dash as NSString).appendingPathComponent(".stay_awake_batt"))

        // --- Tool footprint: this tool's OWN live CPU/RAM (final
        // cleanup 2026-11-18). One `ps` snapshot, classified by
        // command path: the app bundle, the bc-limit daemon binary,
        // and every process running out of the state dir (powerwatch,
        // watchdog + helper scripts, bc-status) or the installed
        // daemon binary (PrivilegedHelperTools on DMG installs).
        // RSS is summed per class; %CPU is ps's own instantaneous
        // figure summed the same way. Labelled as the tool's
        // footprint — nothing else on the machine is counted.
        let psOut = Shell.run("/bin/ps", ["-Axo", "pid,%cpu,rss,command"]).stdout
        var appCpu = 0.0, appRss = 0
        var bgCpu = 0.0, bgRss = 0
        for line in psOut.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("PID") { continue }
            // Split off pid, %cpu, rss; the remainder is the command.
            var rest = t
            func nextField() -> String {
                let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 { rest = String(parts[1]); return String(parts[0]) }
                let only = rest; rest = ""; return only
            }
            let pidStr = nextField()
            let cpuStr = nextField()
            let rssStr = nextField()
            if !isAllDigits(pidStr) { continue }
            let cpu = Double(cpuStr) ?? 0
            let rss = digitsToInt(rssStr) ?? 0
            let cmd = rest
            if cmd.contains("BatteryCommander.app/") {
                appCpu += cpu; appRss += rss
            } else if cmd.contains(".battery-commander/")
                        || cmd.contains("/PrivilegedHelperTools/bc-limit ") || cmd.hasSuffix("/PrivilegedHelperTools/bc-limit") {
                bgCpu += cpu; bgRss += rss
            }
        }
        func fmtCpu(_ v: Double) -> String { String(format: "%.1f", v) }
        func fmtRam(_ kb: Int) -> String {
            // The background set's resident total is often under
            // 1 MB (powerwatch is ~164 KB) — one decimal below
            // 10 MB so the footprint never reads a false "0 MB".
            let mb = Double(kb) / 1024.0
            return mb < 10 ? String(format: "%.1f", mb) : String(format: "%.0f", mb)
        }
        s.usageLines = [
            DaemonLine(text: "Tool footprint (live):", color: "#909090"),
            DaemonLine(text: "App: CPU \(fmtCpu(appCpu))% · RAM \(fmtRam(appRss)) MB", color: "#909090"),
            DaemonLine(text: "Daemon & agents: CPU \(fmtCpu(bgCpu))% · RAM \(fmtRam(bgRss)) MB", color: "#909090"),
            DaemonLine(text: "Tool total: CPU \(fmtCpu(appCpu + bgCpu))% · RAM \(fmtRam(appRss + bgRss)) MB", color: "#909090"),
        ]

        return s
    }
}
