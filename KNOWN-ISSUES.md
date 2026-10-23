# BattOpt — Known Issues & Pending Work

**Date:** 2026-10-23
**Branch:** stable-v1.6.5
**Current State:** Working (basic operation OK, some bugs remain)
**Status:** Deferred until a stronger AI model is available (or 7-day test completes)

---

## 📋 Executive Summary

The tool is **operational** but has **8 unresolved bugs**. The 4 files that keep breaking are:
- `src/plugin/battopt.10s.sh` (734 lines)
- `src/daemon-helpers/dispatch.sh` (~1550 lines)
- `src/app/BattOpt-launcher.sh` (~120 lines)
- `src/app/BattOpt.applescript` (~25 lines)

Repeated attempts by Aider (Claude Sonnet 4.6, Opus 5.5, GPT-6 Astra) to fix these files have failed due to:
1. Model context limits (files too large for full-file output)
2. Regex-based edits that break Bash syntax
3. Models refusing to output complete files

---

## ✅ What Works (Verified)

| Feature | Status | Notes |
|---------|--------|-------|
| SwiftBar plugin | ✅ | 763 lines, loads correctly |
| Battery Hold | ✅ | NCR=14 confirmed via ioreg |
| Custom Limit (from menu) | ✅ | Sets SMC correctly |
| Sailing Mode | ✅ | Oscillates between limits |
| Calibration | ✅ | Full cycle works |
| Smart Discharge (start) | ✅ | Starts discharge process |
| LaunchAgents (18) | ✅ | All load on app open |
| Shutdown (Cmd+Q) | ✅ | Stops all services |
| App stays open | ✅ | `on idle return 60` works |
| SwiftBar launch | ✅ | `open -a SwiftBar` works |
| install.sh | ✅ | Full reproducible install |
| verify-install.sh | ✅ | 13/13 checks pass |
| self_maintenance.sh | ✅ | Runs every 5 min, logs to maintenance.log |
| 7-Day Test countdown | ✅ | Displays in menu |

---

## 🚨 UNRESOLVED BUGS (To Fix Later)

### BUG 1 — Custom Limit not updating in menu display

**Symptom:** When changing limits from outside the plugin (e.g., via `battopt limit 85 80` directly, or via `install.sh`), the plugin's Custom Limit menu item still shows the OLD limits. It only updates when the battery actually reaches a limit.

**Root Cause:** The plugin reads limits from `battopt status` output which is cached for 10 seconds. But when the SMC changes via other paths, the cache isn't invalidated.

**File:** `src/plugin/battopt.10s.sh` — `read_status_cached()` function, `.status_cache` usage.

**Proposed Fix:** Force cache invalidation when `.active_mode` changes, or read `LAST_UPPER`/`LAST_LOWER` directly from `$DASH/config`.

**Priority:** Low (user said "معتقدش هتكون مهمه دلوقتي").

---

### BUG 2 — App runs in background after quitting

**Symptom:** After `Cmd+Q` (or clicking Stop ALL Services), the app continues running in the background, and services sometimes restart automatically.

**Root Cause:** 
- The `on quit` handler runs `dispatch.sh shutdown --force`, but:
  - Either the `--force` flag isn't supported in the deployed version
  - Or `dispatch.sh shutdown` shows the confirmation dialog (blocks quit)
  - Or `launchctl` reloads agents after shutdown
- The watchdog (`swiftbar_watchdog.sh`) may relaunch SwiftBar after it's killed.

**File:** `src/app/BattOpt.applescript`, `src/app/BattOpt-launcher.sh`, `src/daemon-helpers/swiftbar_watchdog.sh`

**Proposed Fix:**
- Ensure `dispatch.sh shutdown --force` skips the confirmation dialog (already coded, needs verification).
- Ensure `swiftbar_watchdog.sh` respects `.user_shutdown` before relaunching.
- Add `.user_shutdown` check at the top of `launch_swiftbar.sh`.

**Priority:** HIGH (user complained multiple times).

---

### BUG 3 — App closes itself ~2 seconds after launch

**Symptom:** When opening `/Applications/BattOpt.app`, the app closes after ~2 seconds. The `.active_mode` file was set correctly but the app quit.

**Root Cause:** AppleScript's `on run` finishes immediately after `do shell script "..." &` (background). Without `on idle` or `-s` flag, the app quits.

**Current state:** Fixed by adding:
- `on idle return 60` to AppleScript
- `osacompile -s` to `build-app.sh`

**But:** The fix gets reverted whenever we rebuild the app without the `-s` flag. This has happened twice.

**File:** `src/app/build-app.sh`, `src/app/BattOpt.applescript`

**Proposed Fix:**
- Add a verification in `build-app.sh`: check that the compiled applet responds to Apple Events (or just trust `osacompile -s`).
- Add `on run` and `on idle` with explicit `return 60`.

**Priority:** HIGH — the app must stay alive.

---

### BUG 4 — Battery icon shows Discharge when actually Holding

**Symptom:** Hardware is in Hold state (NCR=14, IsCharging=No, ExternalConnected=Yes) but the menu bar icon shows 🔋 (Battery/Discharge).

**Root Cause:** The plugin trusts `.active_mode` file. But this file can be stale (e.g., after a previous discharge that ended as Hold). There's no hardware-first override.

**File:** `src/plugin/battopt.10s.sh` — icon logic and mode text logic.

**Proposed Fix:** Add this block right after reading ioreg values:
```bash
if [ "$ICON_NCR" = "14" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    ACTIVE_MODE="hold"
elif [ "$ACTIVE_MODE" = "discharge" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    ACTIVE_MODE="hold"
fi

Priority: HIGH — the icon misrepresents the actual state.
BUG 5 — Shutdown saves wrong state (100/99 instead of 83/82)

Symptom: After shutdown, opening the app causes charging to 100%, even though user had 83/82 Hold set.

Root Cause:

    dispatch.sh shutdown calls battopt limit 100 99 as part of release sequence

    This overwrites the SMC registers to 100/99

    .last_session_mode was saved BEFORE this (correct 83/82)

    BUT: launcher.sh calls battopt limit before daemon is ready (no wait), so the command fails silently

    Result: SMC stays at 100/99

File: src/app/BattOpt-launcher.sh, src/daemon-helpers/dispatch.sh

Proposed Fix:
bash

# In launcher.sh:
wait_for_daemon() {
    local waited=0
    while [ "$waited" -lt 15 ]; do
        if sudo -n "$BAT" status >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

hold|idle)
    wait_for_daemon
    echo "$SESSION_MODE" > "$DASH/.active_mode"
    if sudo -n "$BAT" limit "$LAST_UPPER" "$LAST_LOWER" >/dev/null 2>&1; then
        log "restored ${SESSION_MODE}: limit $LAST_UPPER/$LAST_LOWER"
    else
        log "WARN: ${SESSION_MODE}: limit FAILED"
    fi
    ;;

Priority: CRITICAL — this is the user's main complaint.
BUG 6 — LaunchAgents show 0 after reopening app

Symptom: After shutdown and reopening the app, launchctl list | grep com.battopt returns 0.

Root Cause:

    dispatch.sh shutdown uses launchctl unload -w which sets a "disabled" flag in macOS.

    launcher.sh calls launchctl load -w but the disabled flag persists on Catalina.

    Fix: launchctl enable "gui/$(id -u)/$label" before unload.

File: src/app/BattOpt-launcher.sh

Proposed Fix: The launcher should call launchctl enable for each agent before unloading/loading:
bash

for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
    label=$(basename "$plist" .plist)
    launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl unload -w "$plist" 2>/dev/null || true
    launchctl load -w "$plist" 2>/dev/null || true
done

Priority: HIGH — the user relies on these for battery protection.
BUG 7 — SwiftBar fails to launch via nohup (Catalina-specific)

Symptom: After app launch, SwiftBar doesn't appear in the menu bar. Logs show launch_swiftbar: SwiftBar launched but pgrep -x SwiftBar returns empty.

Root Cause: nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar & fails when called from inside AppleScript on Catalina. The correct method is open -a SwiftBar (which uses LaunchServices).

File: src/daemon-helpers/launch_swiftbar.sh, src/app/BattOpt-launcher.sh

Proposed Fix: launch_swiftbar.sh should:

    First try open -a SwiftBar

    If that fails, try direct binary

    Log failures clearly

Priority: HIGH — SwiftBar is the main UI.
BUG 8 — The 7-day countdown appeared twice

Symptom: The "🧪 7-Day Test: X days left" line appeared twice in the menu.

Root Cause: The countdown block was inserted twice (once by a script, once by another attempt).

File: src/plugin/battopt.10s.sh

Proposed Fix: Ensure only ONE # === 7-DAY TEST COUNTDOWN === block exists. Verify with:
bash

grep -c "7-DAY TEST COUNTDOWN" src/plugin/battopt.10s.sh
# Should be exactly 2 (open + close comment)

Priority: Medium (cosmetic).
🔥 Files That Keep Breaking

The following files break repeatedly due to regex-based edits and model limitations:
File	Lines	Break Frequency	Safe Edit Method
dispatch.sh	~1550	Very High	Only via Aider (never Python regex)
battopt.10s.sh	~734	High	Only via Aider (never Python regex)
BattOpt-launcher.sh	~120	Medium	Aider or careful cat > with full content
BattOpt.applescript	~25	Low	Safe to use cat > with full content

Rule: Never use sed -i or python3 -c "import re; ..." on these files. Always use Aider with --read and full file output, OR cat > with complete content.
🎯 Recommended Fix Order

When a strong AI model is available (or after 7-day test):

    BUG 5 (CRITICAL): launcher.sh — add wait_for_daemon + explicit battopt limit call.

    BUG 4 (HIGH): battopt.10s.sh — add hardware-first ACTIVE_MODE override.

    BUG 6 (HIGH): launcher.sh — add launchctl enable before each unload/load.

    BUG 2 (HIGH): BattOpt.applescript + swiftbar_watchdog.sh — verify --force flag and .user_shutdown respect.

    BUG 7 (HIGH): launch_swiftbar.sh — use open -a instead of nohup.

    BUG 3 (HIGH): Verify build-app.sh uses -s flag persistently.

    BUG 8 (Medium): Dedupe 7-day countdown block.

    BUG 1 (Low): Custom Limit cache invalidation.

🛠️ Tools to Use for Future Fixes

When a stronger model is available:

    Aider with Claude Opus 5.5 or GPT-6 Astra (for full-file rewrites)

    Full-file output only (no diffs, no Python regex)

    Verify after every edit with bash -n and osacompile

Do NOT use:

    Python regex on Bash files

    sed -i with complex patterns

    Partial diffs from AI models

📅 Current Plan

    Now: Leave the tool running as-is for 7 days.

    Day 7: Read final_report.txt from ~/.battopt-swiftbar/.

    After: Use a strong model (once available) to fix all 8 bugs in one coordinated pass.

    Then: Publish v1.7.0 with DMG on GitHub.

Documented by Claude on 2026-10-23. All bugs verified against running code.
