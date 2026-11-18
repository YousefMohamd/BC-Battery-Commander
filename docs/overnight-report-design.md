# Overnight Sleep/Drain Report — Design

## Problem
Yousef reported (2026-11-11 13:18 EET) that last night's drain was very big, and
(15:46 EET) that he cannot determine the numbers himself — "there should be a
report system that clarifies the overnight sleep/drain". A morning report already
exists (morning_report.sh → reports/morning-YYYYMMDD.txt) but Yousef never sees
it: it is a file in the state dir, its "Battery Now" and "Baseline" sections are
empty (status cache unavailable during DarkWake; `.sleep_baseline` does not
exist), and its "Total: 112" wakes count is meaningless (whole log history).
The raw DarkWake lines ARE in it, but there is no summary (no sleep start/end,
no total drain, no rate).

## What the report must answer
- When did the Mac sleep (time + %)? When did it wake / last reading (time + %)?
- Total drain (%) and rate (%/h), vs the known baseline (1.2–1.7%/h).
- Did the Mac sleep normally (standby + maintenance DarkWakes only, no user wake)?
- Was BC involved (any BC-caused wake or discharge)?
- Current % + hold status (from bc-status).
- The gauge-jump caveat (the % shown at lid-open can understate the true charge).

## Data sources (read-only)
- `pmset -g log` — Sleep/Wake/DarkWake lines with timestamps + Charge % + BATT/AC.
  The DarkWake series is the overnight % timeline.
- `$DASH/bc-status` — current % + BCLM + hold status (read-only; works during
  DarkWake — the watchdog logs during DarkWakes).
- `$DASH/config` — limits 86/85.
- No new files, no settings changes, no SMC writes.

## Computation (in morning_report.sh)
- Overnight window: yesterday 18:00 → now.
- DarkWake series in that window (grep "DarkWake", filter by date/time).
- FIRST = first DarkWake after 18:00 yesterday (sleep-start %, time).
- LAST = last DarkWake before now (wake/current %, time).
- Total drain = FIRST% - LAST%. Duration = LAST time - FIRST time (hours).
  Rate = drain / duration.
- DarkWake count = number of DarkWake lines in the window.
- Power: "on battery" if all DarkWakes say "Using BATT"; "on AC" if any say
  "Using AC".
- Slept normally: YES if >=1 DarkWake AND no "Wake from Standby" (user wake)
  in the window. Otherwise note the user wake time(s).
- BC involvement: distinct DarkWake reasons; if all are RTC/Maintenance (or
  EC.ACAttach/ACDetach), BC was not involved (BC schedules no wakes).
- Gauge jump: if a "Wake from Standby" (LidOpen) exists in the window, compare
  its % with the current bc-status %; a jump >5% in <10 min is noted. (For the
  8 AM run the user has not woken yet, so this is noted only when present.)
- Write the full report to reports/morning-YYYYMMDD.txt (summary at the top,
  then the existing sections, improved) AND a one-line summary to
  $DASH/.overnight_summary (e.g. "Last night (Nov 10→11): 85% → 65%
  (-20%, 1.6%/h)").
- Notification: message = the one-line summary (so the notification itself
  carries the answer, even if seen later in Notification Center).

## How Yousef sees it
1. Menu (SwiftBar plugin): a top-level "Overnight:" line (from
   .overnight_summary, after the Backend line) + a menu item "Overnight
   Report" (dispatch `overnight_report`) next to "Sleep & Battery Report"
   that regenerates the report on demand and opens it.
2. Morning notification: the one-line summary (from morning_report.sh,
   8 AM agent run).
3. The full report file: reports/morning-YYYYMMDD.txt (also reachable via
   the existing "Open Reports Folder").

## Dispatch action `overnight_report` (new)
- Find today's morning-YYYYMMDD.txt; if missing, run morning_report.sh to
  regenerate; then open it with `open -e`. (Regenerating on demand keeps the
  numbers fresh, including the wake % after lid-open.)

## Files changed
- src/daemon-helpers/morning_report.sh (rewrite the summary computation; keep
  the DASH fallback block, the report path, and the notification mechanism).
- src/daemon-helpers/dispatch.sh (add `overnight_report` action).
- src/plugin/battery-commander.10s.sh (add the "Overnight:" header line +
  the "Overnight Report" menu item).
- Backups: *.pre-overnight-report in battopt-project/bc-build/.

## Testing
- Run morning_report.sh once on the Mac; verify the report contains the
  overnight summary with correct numbers for last night (closed ~20:30 at
  85%, 70% at 06:54, 60% at 13:00, gauge jump to 72%).
- Verify the plugin renders the "Overnight:" line and the "Overnight Report"
  item opens the report.
- No fake sleep/drain test. No pmset changes.
