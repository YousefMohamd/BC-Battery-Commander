# Overnight Sleep/Drain Report — Completion Note
**Date:** 2026-11-11 (built + tested 16:16 EET). **Task:** Yousef asked (15:46 EET) for a report system that clarifies the overnight sleep/drain, because he cannot determine the numbers himself. **Status: DONE and TESTED.**

## What Yousef sees (how he reaches the report)
1. **Menu header line** (SwiftBar plugin, right under "Backend: bclm"): `Overnight: Last night (Nov 10 -> Nov 11): 85% -> 60% (-25%, 1.6%/h)` — the answer at a glance, every time he opens the menu.
2. **Menu item "Overnight Report"** (next to "Sleep & Battery Report") — opens today's full morning report in TextEdit. If today's report is missing (Mac was off at 8 AM), it regenerates it first so the numbers are fresh.
3. **Morning notification at 8 AM** — the notification message IS the one-line summary, so the answer is visible even if only seen later in Notification Center. (The 8 AM agent run was deferred to the next DarkWake before; the report for 2026-11-11 was written at 09:54.)

## What was built (3 files, all read-only — no settings changes, no SMC writes)
- **`src/daemon-helpers/morning_report.sh`** (rewritten, 60 → 275 lines, 11,778 B, md5 `e702903e…`): computes the overnight summary from `pmset -g log` (DarkWake series) + `bc-status` (current %/BCLM/hold) + config. Overnight window = yesterday 18:00 → now. FIRST = first DarkWake after 18:00 yesterday (sleep-start %, time); LAST = last DarkWake before now. Total drain, duration (h), rate (%/h), DarkWake count, power (battery / AC / mixed), slept-normally check, BC-involvement check (distinct DarkWake reasons; all system maintenance = BC not involved), morning wake (LidOpen), current % + hold status, gauge-jump note (recency-gated, see below). Writes the full report to `reports/morning-YYYYMMDD.txt` AND the one-line summary to `$DASH/.overnight_summary` (read by the plugin). Replaces the old empty sections: Battery Now now uses `bc-status` directly (was empty — status cache unavailable); Baseline replaced by the Overnight Summary; "Current Wakes" (whole-log total, meaningless) replaced by the overnight DarkWake count; wake reasons now limited to the overnight window.
- **`src/plugin/battery-commander.10s.sh`** (2 edits, 42,717 → 42,985 B, md5 `e47c0385…`): "Overnight:" header line after Backend (reads `$DASH/.overnight_summary`, shown only if the file exists); "Overnight Report" menu item next to "Sleep & Battery Report".
- **`src/daemon-helpers/dispatch.sh`** (1 edit, 76,953 → 77,492 B, md5 `f66a647c…`): new `overnight_report` action — find today's morning report, regenerate if missing, open with `open -e`, else notify "not available yet".

## Test results (2026-11-11 16:16 EET, live run — all PASS)
Ran the deployed `morning_report.sh` once (exit 0). Report `reports/morning-20261111.txt`:
- **Summary line:** `Last night (Nov 10 -> Nov 11): 85% -> 60% (-25%, 1.6%/h)` — matches the known values exactly (closed ~20:30 at 85%; 70% at 06:54; 60% at 13:00; rate 1.6%/h, within the known baseline 1.2–1.7%/h).
- **Sleep start:** 2026-11-10 21:08:55 — 85% (BATT). **Last reading:** 2026-11-11 13:00:24 — 60% (AC). **Total drain:** -25% over 15.9 h. **Rate:** 1.6%/h. **Maintenance wakes:** 16 (DarkWake). **Power:** mixed (battery + AC). **Slept normally:** yes. **BC involved:** no — all wakes were system maintenance (EC.ACAttach/Maintenance RTC/Maintenance). **Morning wake:** 2026-11-11 13:15:11 — 60%. **Current:** 86% — holding (BCLM=10) (Health 75%).
- **Plugin render:** ran the installed plugin; line 8 = `Overnight: Last night (Nov 10 -> Nov 11): 85% -> 60% (-25%, 1.6%/h)`; line 78 = `Overnight Report` menu item. Both render.
- **Dispatch action:** `dispatch.sh overnight_report` exit 0 (report found, opened with `open -e`).
- **Notification:** the script fires terminal-notifier (fallback osascript) with the summary as the message; ran twice during testing (exit 0). On-screen appearance not directly observed (no GUI access from the agent).

## Bugs found during testing (all FIXED and re-tested)
1. **User-wake list contaminated (wrong "Slept normally: no — woken 15 times"):** `grep "Wake from Standby"` also matches "DarkWake from Standby", so UW contained all 16 DarkWake lines + the LidOpen line. Fixed by filtering on the event field (`$4 == "Wake" && /Wake from Standby/`). Now: "Slept normally: yes" and the User Wakes section lists ONLY the LidOpen line (13:15:11).
2. **Gauge-jump note fired hours after waking (misleading):** it compared the wake % (60%) with the current % (86%) 3 h later — the difference was charging, not a gauge jump. Fixed with a recency gate (< 60 min). The note now appears only when the report is generated within an hour of lid-open.
3. **Summary line corrupted (missing "Nov 10", broken arrow):** a multibyte arrow directly after a `$VAR` (`"$YEST_SHORT→"`) is mangled by the shell — the variable value AND the arrow's first byte are dropped (verified by a minimal repro; the second arrow, after a space, was intact). Fixed by using ASCII arrows (`->`) in the one-line summary. Documented in the script comment.

## Tunnel outage during this task
- Tunnel was up at ~13:55 UTC, then flapped: HTTP 502 at 13:57:48, HTTP 530 / Error 1033 at 13:58:59 (Mac unreachable). Backed off, retried once (still down), then ran the background poller (`overnight-report-poller.sh`, 12-min intervals). Tunnel came back at 14:15:37 UTC (attempt 2); the poller ran the backup step and exited 0. No work was lost; nothing was written while the tunnel was down.

## Backups (Mac, `battopt-project/bc-build/`)
- `morning_report.sh.pre-overnight-report` (2,315 B, md5 `cf285214…` — the old 60-line version).
- `battery-commander.10s.sh.pre-overnight-report` (42,717 B).
- `dispatch.sh.pre-overnight-report` (76,953 B).
- Edit scripts + design note in `battopt-project/bc-build/`: `overnight_plugin_fix.py`, `overnight_dispatch_fix.py`, `overnight-report-design.md` (also local in `~/workspace/bc-build/`).

## Deployment (all md5-verified, FAIL=0)
- `deploy-populate.sh` (dispatch.sh) + `repoint-populate.sh` (morning_report.sh) + plugin copied to `~/SwiftBar/battery-commander.10s.sh` (chmod +x). Repo = deployed = installed for all three files. bash -n OK on all three.

## Constraints kept
No sudo. No launchctl load/unload. No Phase C (bc-limit daemon still installed, NOT loaded). No commit/push. No live battery tests. No SMC writes. No pmset changes. No /etc/sudoers.d touch. No agent-plist or login-item touch. GET /info first. Read before writing.

## Open / notes
- The 8 AM agent run is deferred to the next DarkWake when the Mac is asleep at 8 AM (2026-11-11's report was written at 09:54) — the summary still covers the full overnight window, so this is fine.
- The gauge-jump note only appears when the report is generated within 60 min of lid-open (morning report at 8 AM runs before lid-open, so it normally will NOT show the gauge jump; the on-demand "Overnight Report" menu item, run after waking, WILL show it if the jump is >5%).
- The old morning report's `.sleep_baseline` file does not exist (never created) — the new report does not depend on it.
