// Housekeeping.swift — Battery Commander (BC) standalone app, Stage C.
//
// FR-006 launcher merge (design §8.1 / §11 step 4): the launch-time
// housekeeping the AppleScript applet used to perform by running
// BatteryCommander-launcher.sh, ported 1:1 into the app. The sequence
// runs ONCE per app launch, on a background queue, and writes the same
// lines to the same actions.log in the same format
// ("[HH:MM:SS] Battery Commander (BC): …"), so the launch evidence in
// the log is indistinguishable from the applet era.
//
// Behaviour checklist (launcher line refs are to
// src/app/BatteryCommander-launcher.sh as of 2026-11-14):
//   L25   mkdir -p state dir + SwiftBar dir — ADAPTED: the app never
//         creates the state dir (design §9 / FR-009: missing state dir
//         is the degraded state, never a creation trigger). The
//         SwiftBar plugin dir is still created if missing.
//   L27   log() → actions.log — ported verbatim (hkLog).
//   L31   notify() — originally the launcher's external-notifier
//         fallback chain, ported verbatim at Stage C; REPLACED in
//         the final cleanup (2026-11-18, owner order) with the
//         app-native queue transport (hkNotify appends to
//         .notify_queue; the app's Notifier posts it itself).
//   L46   read_config: KEY=value parse, never sourced, canonical
//         defaults 86/85/false/1 — ported verbatim.
//   L64   valid_limit: digits, 15…100 — ported verbatim.
//   L72   daemon_loaded: launchctl list <label> (user domain) —
//         ported (read-only; the launcher NEVER loads anything and
//         neither does the app).
//   L82   daemon_running_system: enforcer freshness = daemon-log
//         mtime < 180 s — ported verbatim.
//   L92   read_bclm via bc-status — ported verbatim.
//   L100  launch lock (.launch.lock.dir + pid file, stale takeover,
//         release at sequence end = the script's EXIT trap) — ported.
//         A live lock held by another process ends the sequence and
//         the duplicate app instance exits (the script exited 0; the
//         applet then idled invisibly — a second menu-bar icon would
//         be wrong, so the app terminates instead).
//   L120  "=== LAUNCH START ===" + elapsed timing — ported.
//   L124  Step 1: force-clear .user_shutdown/.disabled/.paused —
//         ported (files only; the script's rm -f could not remove the
//         disabled/ DIRECTORY either). Stage C: Step 1 also clears
//         .tool_closed — this is the FR-007 resume (flag cleared
//         BEFORE Step 7's reapply, so enforcement returns ≤ 1 tick).
//   L127  Step 2: restore plugin from $DASH/disabled/ → ~/SwiftBar,
//         chmod 755 — RETIRED at Stage C (the plugin is retired;
//         nothing may resurrect it into ~/SwiftBar).
//   L136  Step 3: enforcer check (fresh + tail-20 ERROR scan, or
//         not-running WARN + notify). NEVER auto-loads — ported.
//   L150  Step 4: powerwatch loaded check — ported.
//   L157  Step 5: watchdog loaded check — ported.
//   L164  Step 6: config + .last_session_mode read, limits validated
//         (invalid → canonical; lower >= upper → lower = upper-1) —
//         ported.
//   L178  Step 7: reconciler — battery % from ioreg; dispatch
//         reapply_limit; .charge_target/.active_mode per the three
//         branches; sleep 2; BCLM read-back verify + mismatch
//         notifications; post-shutdown overshoot → assert idle;
//         sleep 2; touch plugin file — ported.
//   L254  Step 8: launch SwiftBar if not running — RETIRED at
//         Stage C (the app renders its own menu; SwiftBar is no
//         longer part of the tool).
//   L265  Step 9: plugin presence verify — REPLACED at Stage C by a
//         self-check of the app's own bundle.
//   L273  "=== LAUNCH COMPLETE in Ns ===" — ported.
//
// NOT ported, by design/stage (see app-stage-b-note.md):
//   - Applet `on idle` (60 s): applet-runtime artifact; the app is a
//     real NSApplication with its own 10 s timer. Obsolete.
//   - Applet `on quit` → dispatch shutdown --force: replaced at
//     Stage C by the FR-007 closed-flag contract (AppDelegate
//     writes .tool_closed on Quit; the daemon releases the limit
//     itself, read-back verified). No shell teardown, no sudo.
//
// The launcher's own rules hold here too: no battopt binary, no sudo,
// no launchctl load, no trial-renew helpers, config parsed as data.

import Foundation

enum Housekeeping {

    enum Outcome {
        case completed          // sequence ran (lock released at end)
        case duplicateInstance  // a live launcher/app already holds the lock
        case noStateDir         // degraded state governs; nothing to do
    }

    private static let queue = DispatchQueue(label: "bc.housekeeping", qos: .utility)

    /// Run the launch sequence once, off the calling thread.
    static func runOnce(completion: @escaping (Outcome) -> Void) {
        queue.async {
            let outcome = LaunchSequence().run()
            completion(outcome)
        }
    }
}

private final class LaunchSequence {

    // Constants mirroring the launcher script.
    private let daemonLabel = "com.batterycommander.bclimit"
    private let watchdogLabel = "com.batterycommander.watchdog"
    private let powerwatchLabel = "com.batterycommander.powerwatch"
    private let pluginName = "battery-commander.10s.sh"

    private let fm = FileManager.default
    private var dash: String = ""
    private var pluginDir: String = ""
    private var lockDir: String = ""
    private var lockHeld = false

    // MARK: Logging / notification (launcher L27/L31)

    private func hkLog(_ msg: String) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] Battery Commander (BC): \(msg)\n"
        let path = (dash as NSString).appendingPathComponent("actions.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func hkNotify(_ title: String, _ msg: String) {
        // App-native transport (final cleanup 2026-11-18, owner
        // order): append one title<TAB>body line to .notify_queue;
        // the app's own Notifier drains the queue on the refresh
        // cadence and posts it via UNUserNotificationCenter. No
        // external notifier is a product dependency. (Pre-cleanup
        // this launched an external notifier binary with an
        // osascript fallback, ported from the old launcher.)
        let t = title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let b = msg.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let path = (dash as NSString).appendingPathComponent(".notify_queue")
        if let data = "\(t)\t\(b)\n".data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        hkLog("NOTIFY: \(title) - \(msg)")
    }

    // MARK: Config (launcher L46/L64)

    private struct Config {
        var upper = "86"
        var lower = "85"
        var sailing = "false"
        var sailGap = "1"
    }

    private func readConfig() -> Config {
        var cfg = Config()
        guard let text = readFile((dash as NSString).appendingPathComponent("config")) else { return cfg }
        for rawLine in text.components(separatedBy: "\n") {
            guard let kv = splitFirst(rawLine, "=") else { continue }
            switch kv.head {
            case "LAST_UPPER": cfg.upper = kv.tail
            case "LAST_LOWER": cfg.lower = kv.tail
            case "SAILING": cfg.sailing = kv.tail
            case "SAIL_GAP": cfg.sailGap = kv.tail
            default: break
            }
        }
        return cfg
    }

    private func validLimit(_ s: String) -> Bool {
        guard let v = digitsToInt(s) else { return false }
        return v >= 15 && v <= 100
    }

    // MARK: Checks (launcher L72/L82/L92)

    private func daemonLoaded(_ label: String) -> Bool {
        return Shell.run("/bin/launchctl", ["list", label]).status == 0
    }

    private func enforcerRunning() -> Bool {
        guard let age = fileAgeSeconds((dash as NSString).appendingPathComponent("bc-limit-daemon.log")) else { return false }
        return age < 180
    }

    private func readBCLM() -> String? {
        let bcStatus = (dash as NSString).appendingPathComponent("bc-status")
        guard fm.isExecutableFile(atPath: bcStatus) else { return nil }
        let out = Shell.run(bcStatus).stdout
        for line in out.components(separatedBy: "\n") where line.hasPrefix("BCLM:") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 { return String(fields[1]) }
            return nil
        }
        return nil
    }

    // MARK: Small file helpers mirroring shell idioms

    private func writeText(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func removeFileIfPresent(_ path: String) {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: The sequence

    func run() -> Housekeeping.Outcome {
        guard let resolved = StatusProvider.dashPath else { return .noStateDir }
        dash = resolved
        let home = fm.homeDirectoryForCurrentUser.path
        pluginDir = (home as NSString).appendingPathComponent("SwiftBar")
        // Launcher L25, adapted: create the SwiftBar plugin dir if
        // missing; the state dir itself is never created by the app.
        try? fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

        // --- Launch lock (L100-118) ---
        lockDir = (dash as NSString).appendingPathComponent(".launch.lock.dir")
        if acquireLock() == .heldByOther {
            return .duplicateInstance
        }
        defer { releaseLock() }

        hkLog("=== LAUNCH START ===")
        let start = Date()

        // --- Step 1 (L124): force-clear shutdown flags ---
        // Stage C: .tool_closed joins the list (FR-007 resume).
        for flag in [".user_shutdown", ".disabled", ".paused", ".tool_closed"] {
            removeFileIfPresent((dash as NSString).appendingPathComponent(flag))
        }

        // --- Step 2: plugin retired (Stage C) ---
        // The SwiftBar plugin retired at Stage C; the app is the
        // only UI. The launcher-era restore from disabled/ is gone:
        // nothing may resurrect the plugin into ~/SwiftBar.
        hkLog("plugin retired (Stage C) - no plugin restore; the app is the only UI")

        // --- Step 3 (L136-146): enforcer check; NEVER auto-load ---
        if enforcerRunning() {
            let logText = readFile((dash as NSString).appendingPathComponent("bc-limit-daemon.log")) ?? ""
            let tail = logText.components(separatedBy: "\n").suffix(20).joined(separator: "\n")
            if tail.contains("ERROR") {
                hkLog("WARN: enforcer \(daemonLabel) log is fresh but shows ERRORs - enforcement may be failing (check \(dash)/bc-limit-daemon.log)")
                hkNotify("Battery Commander (BC)", "Enforcer is reporting errors - charge limit may not be enforcing. Check bc-limit-daemon.log.")
            } else {
                hkLog("enforcer \(daemonLabel) is running (daemon log fresh)")
            }
        } else {
            hkLog("WARN: enforcer \(daemonLabel) is NOT running (Phase C gate - hold will not enforce)")
            hkNotify("Battery Commander (BC)", "Enforcer not running - charge limit will not enforce until the daemon is loaded (Phase C).")
        }

        // --- Step 4 (L150-154): powerwatch check ---
        if daemonLoaded(powerwatchLabel) {
            hkLog("powerwatch \(powerwatchLabel) is loaded")
        } else {
            hkLog("WARN: powerwatch \(powerwatchLabel) is NOT loaded (sleep/wake events will not fire)")
        }

        // --- Step 5 (L157-161): watchdog check ---
        if daemonLoaded(watchdogLabel) {
            hkLog("watchdog \(watchdogLabel) is loaded")
        } else {
            hkLog("watchdog \(watchdogLabel) is not loaded (expected before deploy)")
        }

        // --- Step 6 (L164-175): config + session state, validated ---
        var cfg = readConfig()
        if !validLimit(cfg.upper) { cfg.upper = "86" }
        if !validLimit(cfg.lower) { cfg.lower = "85" }
        let upper = Int(cfg.upper) ?? 86
        var lower = Int(cfg.lower) ?? 85
        if lower >= upper { lower = upper - 1 }
        cfg.upper = String(upper)
        cfg.lower = String(lower)

        var sessionMode = "idle"
        if let session = readFile((dash as NSString).appendingPathComponent(".last_session_mode")) {
            for line in session.components(separatedBy: "\n") where line.hasPrefix("ACTIVE_MODE=") {
                let value = String(line.dropFirst("ACTIVE_MODE=".count))
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                if !value.isEmpty { sessionMode = value }
            }
        }
        hkLog("config limits: \(upper)/\(lower) (authoritative); last_session mode: \(sessionMode)")

        // --- Step 7 (L178-247): reconciler ---
        let ioreg = Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]).stdout
        var currentPct: Int? = nil
        if let curS = firstCapture("\"CurrentCapacity\" = ([0-9]+)", in: ioreg),
           let maxS = firstCapture("\"MaxCapacity\" = ([0-9]+)", in: ioreg),
           let cur = Int(curS), let max = Int(maxS), max > 0 {
            currentPct = (cur * 100 + max / 2) / max
        }

        let dispatch = (dash as NSString).appendingPathComponent("dispatch.sh")
        if fm.isExecutableFile(atPath: dispatch) {
            _ = Shell.run(dispatch, ["reapply_limit"])
            hkLog("reapplied configured limit \(upper)/\(lower) via dispatch")
        } else {
            hkLog("WARN: dispatch.sh not found in \(dash) - cannot reapply limit")
        }

        let chargeTargetPath = (dash as NSString).appendingPathComponent(".charge_target")
        let activeModePath = (dash as NSString).appendingPathComponent(".active_mode")
        if let pct = currentPct {
            if pct < lower {
                writeText("\(upper)\n", to: chargeTargetPath)
                writeText("charge_full\n", to: activeModePath)
                hkLog("Reconciler: PCT=\(pct)% < LOWER=\(lower)% - starting charge to \(upper)%")
            } else {
                removeFileIfPresent(chargeTargetPath)
                writeText("hold\n", to: activeModePath)
                hkLog("Reconciler: PCT=\(pct)% >= LOWER=\(lower)% - holding (no discharge)")
            }
        } else {
            hkLog("WARN: could not read battery %; applying limits only")
            removeFileIfPresent(chargeTargetPath)
            writeText("hold\n", to: activeModePath)
        }

        // BCLM read-back verify (L224-237).
        Thread.sleep(forTimeInterval: 2)
        if let bclm = readBCLM() {
            hkLog("BCLM read-back: \(bclm) (expected 10 when holding, 100 when charging)")
            if let pct = currentPct, pct >= upper, bclm != "10" {
                hkLog("WARN: BCLM=\(bclm) but PCT=\(pct)% >= UPPER=\(upper)% (charging not held - enforcer will correct on its next run)")
                hkNotify("Battery Commander (BC)", "Battery \(pct)% is above the \(upper)% limit but charging is not held (BCLM=\(bclm)).")
            } else if let pct = currentPct, pct < lower, bclm != "100" {
                hkLog("WARN: BCLM=\(bclm) but PCT=\(pct)% < LOWER=\(lower)% (charging not enabled - enforcer will correct on its next run)")
                hkNotify("Battery Commander (BC)", "Battery \(pct)% is below the \(lower)% limit but charging is not enabled (BCLM=\(bclm)).")
            }
        } else {
            hkLog("WARN: BCLM unreadable (bc-status not found) - enforcer state unverified")
        }

        // Post-shutdown overshoot reconciliation (L243-247).
        if let pct = currentPct, pct > upper {
            hkLog("Reconciler: PCT=\(pct)% > UPPER=\(upper)% post-launch - asserting idle for watchdog")
            removeFileIfPresent(chargeTargetPath)
            writeText("idle\n", to: activeModePath)
        }

        // Refresh UI after applying limits (L250-251).
        Thread.sleep(forTimeInterval: 2)
        let pluginPath = (pluginDir as NSString).appendingPathComponent(pluginName)
        if fm.fileExists(atPath: pluginPath) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: pluginPath)
        }

        // --- Step 8: RETIRED at Stage C ---
        // The app no longer launches SwiftBar: the plugin is
        // retired and the app renders its own menu.

        // --- Step 9 (Stage C): self-check of the app's own bundle ---
        let ownExe = Bundle.main.executablePath ?? ""
        if !ownExe.isEmpty && fm.isExecutableFile(atPath: ownExe) {
            hkLog("app bundle self-check OK: \(ownExe)")
        } else {
            hkLog("WARN: app bundle self-check failed (executable not found: \(ownExe))")
        }

        hkLog("=== LAUNCH COMPLETE in \(Int(Date().timeIntervalSince(start)))s ===")
        return .completed
    }

    // MARK: Lock (launcher L100-118)

    private enum LockResult { case acquired, heldByOther, unavailable }

    private func acquireLock() -> LockResult {
        do {
            try fm.createDirectory(atPath: lockDir, withIntermediateDirectories: false)
            writeText("\(ProcessInfo.processInfo.processIdentifier)", to: (lockDir as NSString).appendingPathComponent("pid"))
            lockHeld = true
            return .acquired
        } catch {
            // Lock dir already exists: live holder, or stale?
            let pidText = readFileStripped((lockDir as NSString).appendingPathComponent("pid")) ?? ""
            let pid = Int32(pidText) ?? 0
            if pid > 0 && pidAlive(pid) {
                hkLog("another launcher (PID \(pid)) is already running - exiting")
                return .heldByOther
            }
            hkLog("WARN: stale launch lock (PID \(pidText.isEmpty ? "unknown" : pidText) not running) - taking over")
            try? fm.removeItem(atPath: lockDir)
            do {
                try fm.createDirectory(atPath: lockDir, withIntermediateDirectories: false)
                writeText("\(ProcessInfo.processInfo.processIdentifier)", to: (lockDir as NSString).appendingPathComponent("pid"))
                lockHeld = true
                return .acquired
            } catch {
                hkLog("WARN: could not take launch lock - continuing without it")
                return .unavailable
            }
        }
    }

    private func releaseLock() {
        if lockHeld {
            try? fm.removeItem(atPath: lockDir)
            lockHeld = false
        }
    }

    /// kill(pid, 0) liveness probe (the script's `kill -0`): alive on
    /// success or EPERM (exists, owned by someone else).
    private func pidAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
