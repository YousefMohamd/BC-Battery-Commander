# Notification Fix — Completion Note
**Date:** 2026-11-11 (built + tested ~17:35–17:42 EET). **Task:** Yousef complained
17:26 EET (with a screenshot) that notifications arrive frequently (spammy) and he
does not understand why; he wants notifications ONLY for the cases he originally
set up, not spam. **Status: DONE and TESTED.**

## The spam (evidence, live state files 2026-11-11)
- **APG "Warm"** fired at 16:21 EET (`.notify_apg` = 1794406878), then again at
  17:31 EET (1794411099) — ~once per hour (3600s cooldown). The APG state flips
  GREEN/YELLOW/RED every few minutes (Recent Actions 15:25–16:07) because the
  classification is load-driven (load >= 4 → YELLOW, load > 6 → RED) while the
  battery temp is ~30.5C (cool). The message "Warm (30.80C)" is misleading —
  30.8C is not warm; it is a load spike.
- **"Battery at Limit" (hold_reached)** fired 3 times today: 15:56, 16:56, 17:56
  (`.notify/.daily_20261111` = 1794398199, 1794401799, 1794405400) — exactly
  once per hour (3600s cooldown), hitting the daily cap of 3. The battery holds
  at 86% for hours, so the condition is true continuously and re-fires hourly.
- **Root cause:** both use a TIME-based cooldown (3600s) on a STEADY-STATE
  condition. A cooldown re-fires whenever it expires and the condition is still
  true. The correct dedup for a steady-state condition is SESSION-based
  (notify once per episode/transition), not time-based.

## What was changed (2 fixes)
### 1. Plugin hold_reached → once per hold session (src/plugin/battery-commander.10s.sh)
- New session file `$DASH/.notify/hold_reached_session` (content = the limit,
  e.g. "86/85").
- Notify only when a NEW hold session begins (session file absent or limit
  differs). While it keeps holding, no repeat. When the hold ends (mode !=
  hold) or the limit changes, the session clears so the next hold notifies
  once. notify_proactive_v2's cooldown (3600s) + daily cap (3/day) remain as
  backstops. The session is recorded unconditionally after the call (if the
  announcement was suppressed by cooldown/cap, the user was already notified
  recently — that is why it was blocked — so marking the episode as handled
  is correct and is the spam-reduction goal).
- The session file was pre-seeded with "86/85" on deploy, so the CURRENT hold
  (which Yousef already knows about) does not re-notify.
- Final plugin md5: `1c3c525bb1d16495df56cef741c1324f` (repo = installed
  ~/SwiftBar/battery-commander.10s.sh).

### 2. Watchdog APG → log only (src/daemon-helpers/bc-watchdog.sh)
- Removed the three `notify_ratelimited "apg" ...` calls (green "System cooled",
  yellow "Warm", red "Hot"). Kept the log lines and the state-file updates.
  The APG guard itself is untouched (it still touches .apg_paused and logs).
- Rationale: APG notifications were NOT in the original policy in practice —
  the old APG guard was frozen "green" since Oct 10, so it never flipped and
  never notified. The guard is automatic; YELLOW/RED are protective states,
  not user-actionable. The thermal case is covered by the plugin's
  temp_critical (original policy).
- Final watchdog md5: `0db30993b39fb43ec2837c532b7c7cbd` (repo = deployed
  ~/.battery-commander/bc-watchdog.sh).

## New policy (what notifies, what does not)
| Event | Notify? | Rule |
|---|---|---|
| User action (button) | YES | Once per action (dispatch.sh notify) — unchanged |
| Morning report (8 AM) | YES | Once per day — unchanged |
| Prepare warning (sleep) | YES | Once per sleep prep — unchanged |
| Launcher warning (login) | YES | Once per login — unchanged |
| battery_critical / temp_critical / enforce_critical / daemon_recovery / load_heat_override / sd_complete | YES | Existing cooldowns + daily cap — unchanged |
| Drift (BCLM != config >300s) | YES | Existing 3600s cooldown — unchanged (rare) |
| Daemon not loaded | YES | Once (first time) / on drift ladder — unchanged |
| **Battery at Limit (hold_reached)** | **YES, once per hold session** | **Session file (new). One notification when a new hold begins; none while it keeps holding.** |
| **APG Warm / Hot / Cooled** | **NO** | **Log only. Removed.** |

## Test results
- **Hold-session unit test** (`test_hold_session.sh`, extracts the ACTUAL hold
  block lines 413–440 from the deployed plugin and evals it against a stub
  notify in a temp DASH — no real notification sent): **17/17 PASS**.
  Cases: new hold notifies once + session written; repeat renders do not
  re-notify; leave-hold clears the session; re-enter notifies once; limit
  change starts a new session; suppressed send still records the session (no
  duplicate later); DIFF>1 while holding keeps the session (no re-notify).
- **Watchdog regression test** (`test_bc_watchdog.sh`, sandboxed): **PASS**.
  Phase A (notifier cap, hold-wait, drift, consolidated), B (healthy-tick
  cleanup), C (APG suppression OK, apg_suppress=10), D (charge_target
  cleanup), E (daemon not-loaded log). Log: /tmp/bc-watchdog-test-20261111.log.
- **Live verification (2026-11-11 ~17:41 EET):**
  - Installed plugin run (exit 0, renders "Overnight:" correctly) with
    mode=hold, PCT=86, UPPER=86: type file UNCHANGED (1794405400), daily
    file UNCHANGED (3 lines), session file UNCHANGED ("86/85") — NO repeat
    "Battery at Limit" notification. Session dedup works live.
  - Watchdog manual run (exit 0) + scheduled ticks (heartbeats 17:39:42,
    17:40:42, APG=yellow, PCT=86, BCLM=10, hold): `.notify_apg` UNCHANGED
    (1794411099) — NO APG notification despite APG=yellow. APG fix works live.
  - bash -n OK on both files. deploy-populate.sh FAIL=0. Repo = deployed =
    installed (md5-verified).

## Bugs found during testing (both fixed and re-tested)
1. **Session "was it sent" check too loose (absolute time):** the first
   version compared the type-file epoch to NOW_TS. Two renders in the same
   second made a stale epoch equal NOW_TS, so the session was recorded even
   though the notification was suppressed. Replaced with a before/after
   comparison.
2. **Before/after comparison also fragile to same-second renders:** the
   type-file epoch does not increase within a second, so a fast test still
   failed. Simplified to the correct design: record the session
   unconditionally (the user was already notified recently if the
   cooldown/cap blocked it). This is simpler, robust to any render timing,
   and matches the spam-reduction goal.

## How Yousef will see fewer notifications
- **No more hourly "Warm/Hot" APG notifications.** The APG guard still works
  (it logs and suppresses corrective discharge), but it no longer notifies.
  He will only get a thermal alert if the battery is genuinely hot (plugin
  temp_critical — the original case).
- **"Battery at Limit" now fires ONCE per hold** (when the battery first
  reaches the limit and holds), not every hour. While it keeps holding at
  86% for hours, no repeat. A new hold (after discharging, or after a limit
  change) notifies once.
- Everything else is unchanged: button confirmations, the 8 AM morning
  summary, Prepare warning, launcher warnings, and the real critical alerts
  (low battery, hot battery, drift, enforcer problems) still notify.

## Backups & files
- Backups on the Mac (`battopt-project/bc-build/`):
  `battery-commander.10s.sh.pre-notification-fix` (42,985 B),
  `bc-watchdog.sh.pre-notification-fix` (50,258 B).
- Design note: `notification-policy-design.md` (local + Mac).
- Edit scripts: `notification_fix.py`, `notification_fix2.py`,
  `notification_fix3.py` (local + Mac, in `battopt-project/bc-build/`).
- Test: `test_hold_session.sh` (local + Mac, in `battopt-project/bc-build/`).
- This note: `notification-fix-note.md` (local + Mac).

## Constraints kept
No sudo. No launchctl load/unload. No Phase C (bc-limit daemon still
installed, NOT loaded). No commit/push. No live battery tests. No SMC writes.
No pmset changes. No /etc/sudoers.d touch. No agent-plist or login-item touch.
GET /info first. Read before writing.
