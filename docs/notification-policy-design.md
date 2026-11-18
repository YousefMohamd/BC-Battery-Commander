# Notification Policy — Battery Commander

**Date:** 2026-11-11. **Status:** DESIGN (fix to be implemented).
**Problem:** Yousef (2026-11-11 17:26 EET, with screenshot) gets notifications
frequently (spammy) and does not understand why. He wants notifications ONLY for
the cases he originally set up, not spam.

## Evidence (live state files, 2026-11-11)
- APG "Warm" notification fired at 16:21 EET (`.notify_apg` = 1794406878).
  The APG state flips GREEN/YELLOW/RED every few minutes (Recent Actions
  15:25–16:07) because the classification is load-driven (load >= 4 → YELLOW,
  load > 6 → RED) while the battery temp is ~30.5C (cool). The message
  "Warm (30.80C)" is misleading — 30.8C is not warm; it is a load spike.
- "Battery at Limit" (hold_reached) fired 3 times today: 15:56, 16:56, 17:56
  (`.notify/.daily_20261111` = 1794398199, 1794401799, 1794405400) — exactly
  once per hour (3600s cooldown), hitting the daily cap of 3. The battery
  holds at 86% for hours, so the condition is true continuously and re-fires
  every hour.
- The daily cap (3/day) limits the plugin, but the watchdog APG has NO daily
  cap (only the 3600s cooldown), so it can fire ~once per hour all day.

## Root cause
Both spam sources use a TIME-based cooldown (3600s) on a STEADY-STATE
condition. A cooldown re-fires whenever it expires and the condition is
still true. The correct dedup for a steady-state condition is SESSION-based
(notify once per episode/transition), not time-based.

## Original policy (what Yousef had before — preserved)
From the old battopt plugin (battopt.10s.sh.installed-backup-20261110) +
dispatch.sh:
- User-action confirmations (dispatch.sh notify() — one per button press). KEEP.
- Critical alerts (plugin): battery_critical (low %), temp_critical (hot
  battery), enforce_critical, daemon_recovery, load_heat_override,
  sd_complete. KEEP (rare, real problems).
- Prepare warning (arm_sleep.sh — AC attached + PCT < UPPER before sleep).
  KEEP (once per sleep prep).
- Launcher warnings (once per login: enforcer not running, SwiftBar/plugin
  missing). KEEP.
- Morning report summary (8 AM, once/day). KEEP (he asked for it).
- Drift alert (watchdog LAYER3 — BCLM does not match config >300s). KEEP
  (real problem, rare).
- Daemon-not-loaded (watchdog L8a — once, first time only; L8b — only on
  drift ladder COUNT 4). KEEP (one-time / rare).
- "Battery at Limit" (hold_reached) — WAS in the original policy, but as a
  once-per-event notification. KEEP the case, FIX the frequency (once per
  hold session).
- APG "Warm/Hot/Cooled" — was NOT in the original policy in practice (the
  old APG guard was frozen "green" since Oct 10, so it never flipped and
  never notified). REMOVE (log only). The thermal case is covered by plugin
  temp_critical.

## New policy
| Event | Notify? | Rule |
|---|---|---|
| User action (button) | YES | Once per action (dispatch.sh notify) — unchanged |
| Morning report (8 AM) | YES | Once per day — unchanged |
| Prepare warning (sleep) | YES | Once per sleep prep — unchanged |
| Launcher warning (login) | YES | Once per login — unchanged |
| battery_critical / temp_critical / enforce_critical / daemon_recovery / load_heat_override / sd_complete | YES | Existing cooldowns + daily cap — unchanged |
| Drift (BCLM != config >300s) | YES | Existing 3600s cooldown — unchanged (rare) |
| Daemon not loaded | YES | Once (first time) / on drift ladder — unchanged |
| **Battery at Limit (hold_reached)** | **YES, once per hold session** | **NEW: session file. Notify only when a NEW hold session begins (mode transitions to hold at the limit). While it keeps holding, no repeat. When the hold ends or the limit changes, the session clears so the next hold notifies once.** |
| **APG Warm / Hot / Cooled** | **NO** | **Log only. The APG guard is automatic; YELLOW/RED are protective states, not user-actionable. The old system never notified on APG. Thermal is covered by temp_critical.** |

## Implementation
### 1. Plugin hold_reached → session-based (src/plugin/battery-commander.10s.sh)
- Add a session file `$DASH/.notify/hold_reached_session` (in the existing
  .notify dir).
- Before the notify_proactive_v2 "hold_reached" call: check if the session
  file exists AND its content equals "$UPPER/$LOWER" (the current limit).
  If yes → skip (already notified for this hold). If no/different → call
  notify_proactive_v2 (which still applies its cooldown + daily cap as a
  backstop) and write the session file with "$UPPER/$LOWER" (atomic via
  _atomic_write).
- When the hold condition is false (mode != hold OR |PCT-UPPER| > 1):
  remove the session file (so the next hold notifies once).
- Note: the plugin runs every 10s; the session file is the dedup. The
  existing notify_proactive_v2 cooldown (3600s) + daily cap (3/day) remain
  as backstops.

### 2. Watchdog APG → log only (src/daemon-helpers/bc-watchdog.sh)
- Remove the three `notify_ratelimited "apg" ...` calls (lines 550, 556, 561).
  Keep the log lines and the state-file updates. Add a comment explaining
  APG notifications are disabled (log only) per the notification policy —
  the guard is automatic and the old system never notified on APG.
- The `.notify_apg` state file will go stale (harmless — it is only read by
  notify_ratelimited, which is no longer called for apg). Leave it (do not
  delete state files).

## Testing
- Simulate APG flips (green→yellow→red→yellow→green) by running the
  watchdog's APG classification in a test harness (or by invoking the
  watchdog with a mocked bc-status) and confirm ZERO notifications are
  sent (but the log lines appear).
- Simulate a hold: set mode=hold, PCT=86, UPPER=86, run the plugin render
  3 times (10s apart) and confirm exactly ONE "Battery at Limit"
  notification (the session file prevents repeats). Then set mode=idle
  (leave hold) and re-enter hold, and confirm it notifies once more (new
  session).
- Verify the morning summary notification still works (it uses a different
  path — morning_report.sh, unchanged).
- Verify no other notification behavior changed (run the existing
  test_bc_watchdog.sh — it should still PASS; the APG log lines are still
  emitted).
