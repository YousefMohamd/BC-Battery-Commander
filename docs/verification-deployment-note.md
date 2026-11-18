# Verification System — DEPLOYMENT Note

Deployed: 2026-11-14 ~19:58–20:12 EET. Approved by Yousef
2026-11-14 19:50 EET ("ابدأ نشر نظام التحقق") — the 6 gated steps
of `verification-v1-sandbox-note.md` §6 / design §9 v1, plus the
bundled watchdog-liveness hardening. **Result: the deployed system
scores Phase C VERIFIED from the deployed store, exit 0.**

Spec: `natural-verification-design.md` (incl. the 2026-11-14 §3
amendment). Sandbox record: `verification-v1-sandbox-note.md`,
`verification-amendment-note.md`.

---

## Step 1 — Tracker in the live pipeline + verification store

**Form (one documented deviation, see below):** the tracker's state
machines were NOT re-written in shell inside `bc-watchdog.sh`. The
deployed `bc-episode-tracker.py` is **byte-identical to the amended
sandbox module (md5 `e18f08fc…`)** and a new driver,
`bc-tracker-live.py`, imports it unmodified and feeds it the
watchdog's heartbeat ticks incrementally (resumable state in
`verification/.tracker_state.json`: cursor, prev tick, serialized
open episode, last closed discharge; crash-safe dedup by episode id
against `episodes.jsonl`; single-instance lock). `bc-watchdog.sh`
gained exactly one additive block at the end of the tick (after the
heartbeat write + log trim): a guarded, `|| true`-wrapped call to
`bc-tracker-live.sh`. It cannot fail or delay the tick, and the
enforcer path is untouched.

**Equivalence proof** (`verify-deploy-test/test_tracker_live_equiv.py`):
the sandbox watchdog log (461 real heartbeats, 2026-11-13) was fed
to a sandbox state dir **one tick per driver invocation**, exactly
as the live watchdog invokes it. The accumulated `episodes.jsonl`
is **identical** to the batch sandbox run (6/6 records, canonical
JSON set compare — including the gauge-drift PASS note verbatim),
`.episode_open` is identical, and `bc-verify --since-phase-c` over
the live-produced store returns **VERIFIED, exit 0**.

**Store:** `~/.battery-commander/verification/` created with
`episodes.jsonl` (rotation per §4 is the tracker's own
`rotate_if_needed`, inherited from the module) and `phase-c.env`
(step 5).

**Backfill** (genuine history, through the deployed driver):
merged input = sandbox input copy of the watchdog log (2026-11-13
15:29→23:12 — the live `.watchdog.log` is tail-trimmed and no
longer holds those ticks) + the live `.watchdog.log`
(2026-11-14 16:13→now); daemon + discharge logs are complete live
originals. The 2026-11-14 15:03–16:13 ticks were trimmed away
before this deployment and are a genuine telemetry gap (the
gap-close rule handles it; §7.1's window is fully inside the
preserved 2026-11-13 copy). Two sleep sidecars were transcribed as
labelled fixtures: the S3 night (the sandbox fixture itself) and
the 2026-11-13→14 night from `reports/morning-20261114.txt`
(02:00:07 86% → 13:42:22 70%, 16 pts, 1.4 %/h, 0 DarkWakes; that
report's own determinations — a 19 s RTC/Alarm wake at 05:14 and
"BC involved: unknown" — are carried faithfully:
`WAKE_REASONS=user`, `DATA_INCOMPLETE=true`, so bc-verify judges it
`verdict_sleep=INTERRUPTED`, `verdict_bc=UNVERIFIED`). The fixture
`.sleep_episode` was removed after ingestion; the first genuine
sidecar arrives with tomorrow's 08:00 run.

**Backfill diff vs sandbox reference: exact** — all 6 sandbox
records reproduced byte-identically (canonical compare), 0 missing,
0 differing. 2 additional records, both expected:
`hold-1794603124` (the 2026-11-13 post-charge hold, closed by the
17 h gap at its last tick 23:12:11, verdict **PASS** —
`close_reason=gap`) and `sleep-1794614407` (the transcribed
2026-11-14 night). Store total: **8 records**; today's hold
(16:13→) is open in `.episode_open` and being accumulated tick by
tick (tracker cursor == latest heartbeat, verified 20:11:32).

Race note: the 20:04 watchdog tick had already started the tracker
on the trimmed live log before the backfill; the backfill held the
hook (wrapper renamed aside), wiped the partial tracker state, ran
the catch-up, then restored the wrapper (+x verified). No partial
or duplicate records resulted (dedup + the diff above).

## Step 2 — Morning-report `.sleep_episode` sidecar

`morning_report.sh` gained one block after the `.overnight_summary`
write: it formats the **already-computed** endpoint values
(`FIRST_DT/PCT`, `LAST_DT/PCT`, `DRAIN`, `RATE`, `DW_COUNT`,
`REASONS`, `NIGHT_WAKES`, `FIRST_PWR`, `BC_INVOLVED`) into the
KEY=value sidecar (atomic tmp+mv). The fixed endpoint logic is
untouched (pure addition after its results). Mapping rules:
report "no" → `BC_INVOLVED=false, DATA_INCOMPLETE=false`;
"check"/"unknown" → `BC_INVOLVED=false, DATA_INCOMPLETE=true`
(bc-verify: verdict_bc UNVERIFIED — not proof of involvement, not
silently clean); mid-night user wakes append `user` to
`WAKE_REASONS`; **no sidecar at all** when endpoints are missing or
non-numeric (honest absence). `EXTERNAL_NOTES` is emitted empty in
v1 (the report computes no cadence pattern; bc-verify only uses it
to soften a >2.5 %/h sleep FAIL).

Tests (`verify-deploy-test/test_sidecar_dispatch.sh`, Part A):
clean night → all fields correct; night-wake + "check" night →
`user` appended, `DATA_INCOMPLETE=true`; no-endpoint night → no
file; the produced sidecar parses through the deployed tracker
machinery into the expected record. **11/11 PASS** (with Part B:
15/15).

## Step 3 — bc-verify hosting + dispatch actions

Installed into the state dir: `bc-verify.py` (md5 `b4125e31…`,
byte-identical to sandbox), `bc-verify.sh`, plus the new runner
`bc-verify-run.sh`. The runner: tracker catch-up → `bc-verify.py
--write-state --report` with the recorded Phase C timestamp →
§6 notification policy (below). **Hosting:** `morning_report.sh`
calls the runner as its final step — the existing
`com.batterycommander.morning-report` agent (08:00) is unchanged
as an agent; no new morning agent. Dispatch gained two actions
following the house patterns (acquire/release, notify):

- `verify_now` — runs the runner, then notifies the one-line verdict.
- `verification_report` — opens today's
  `reports/verification-YYYYMMDD.txt`, generating it via the runner
  first if missing (mirrors `overnight_report`).

Tests (Part B of the same suite): both actions exercised against a
sandbox state dir with the real verify stack — **PASS** (VERIFIED
state produced, report written, `open` called with today's report).

## Step 4 — Plugin surface

Header: after the Overnight line, the plugin prints
`.verification_summary` verbatim (its text carries the "Verified:"
prefix), same style. A **Verification** submenu (after the reports
group) renders `.verification_state` read-only: last full cycle +
verdict, holds 24 h pass count, sleep 7 d (nights · median %/h ·
BC involved), limit changes 7 d + slowest enforcement, overshoot
max 7 d, Phase C status — plus the two dispatch items above.
Headless render proof (2026-11-14 20:08):

```
Verified: Hold ✓ · Cycle ✓ Nov 13 · Overshoot +0% (7d)
-- Last full cycle: Nov 13 — PASS
-- Holds (24h): 2/2 PASS
-- Sleep (7d): 2 nights · median 1.30%/h · BC involved: never
-- Limit changes (7d): 0 · slowest enforcement: —
-- Overshoot max (7d): 86
-- Phase C: VERIFIED Nov 13
```

## Step 5 — Phase C activation + one-time notification

`verification/phase-c.env` records the real swap timestamp
**2026-11-13 17:34:28** (the daemon's own first-run line). The
first deployed scoring run (via `bc-verify-run.sh manual`,
2026-11-14 20:06) evaluated §7.1 from the deployed store:

```
PHASE_C=VERIFIED Nov 13 · CONFIDENCE=FULL · FAILS_24H=0 · FAILS_7D=0
Verified: Hold ✓ · Cycle ✓ Nov 13 · Overshoot +0% (7d)
```
`bc-verify --since-phase-c` against the deployed store: **exit 0**
(all five conditions OK — same evidence as the sandbox: 318 daemon
state lines, max gap 65 s, write pair read-back verified). The
§6 one-time certification notification fired on that run and the
marker `~/.battery-commander/.notify/verify_phase_c_done` was set;
a second runner run did **not** re-fire it (marker count check = 1).
FAIL-episode notifications (once per episode, marker
`.notify/verify_<episode_id>`, sleep axis suppressed) are armed in
the same runner; there are currently no FAIL episodes to fire on.

## Step 6 — §3 amendment confirmation

The deployed tracker is the amended module itself: md5
`e18f08fc97ee1bfa7bf840823dd1fd4d` in repo bc-build AND in the
state dir; all three amendment hunks verified present
(`max_pct_clean_ts` attribute, clean-max timestamping in
`accumulate`, the `gauge-drift` PASS branch in `judge_hold`).
`bc-verify.py` unchanged (`b4125e31…`), as the amendment note
prescribed. The deployed store's 2026-11-13 hold carries the
amendment's PASS + gauge-drift note.

## Step 7 — Watchdog-liveness sentinel

New user LaunchAgent **`com.batterycommander.watchdogsentinel`**
(plist source in `src/agents/`, installed to
`~/Library/LaunchAgents/`, loaded — `launchctl list` shows it,
exit 0; first run wrote clean state). Script
`bc-watchdog-sentinel.sh` (state dir), 180 s interval, ~40 lines of
logic, dependency-free:

- stale = `.watchdog.log` mtime older than 240 s (4 missed ticks);
- alert only after **≥ 300 s of sentinel-observed staleness across
  its own consecutive runs**;
- **wake honesty:** if the gap since the sentinel's own previous
  run exceeds 600 s, the Mac was asleep/off — the observation
  resets, so pre-sleep staleness can never alert;
- **once per incident** (state file `.watchdog_sentinel_state`);
  heartbeat resumption is logged as incident-clearing and re-arms;
- read-only toward BC: it never touches BCLM/config/agents; its
  only writes are its own state + `.watchdog_sentinel.log`.

Synthetic tests (`verify-deploy-test/test_sentinel.sh`,
`BC_SENTINEL_NOW/HB/NOTIFY` hooks, fake heartbeat file): fresh →
silent; first stale observation → silent; 180 s observed → silent;
360 s observed → alert; still stale → no re-alert; resume →
cleared + logged; ancient heartbeat after a 1 h sleep gap → silent;
observation in progress across a sleep → reset + silent (the sharp
false-alert case); post-wake persistent staleness → alert earned;
sleep-then-fresh → never alerts. **20/20 PASS.**

## Regressions (final deployed code, repo suites)

| Suite | Result |
|---|---|
| test_bc_watchdog.sh | PASS |
| test_discharge.sh | 16/16 PASS |
| test_charge_persistence.sh | 20/20 PASS (incl. live-config md5 guard) |
| test_calibration.sh | 98/98 PASS |
| test_bc_limit_calibrate.sh | 15/15 PASS |
| test_tracker_live_equiv.py (new) | PASS (episodes ≡ batch, bc-verify VERIFIED) |
| test_sentinel.sh (new) | 20/20 PASS |
| test_sidecar_dispatch.sh (new) | 15/15 PASS |

## Deploy discipline

Backups of the four edited live files in
`~/.battery-commander/backups/*.pre-verifydeploy-20261114`
(watchdog, dispatch, morning_report, plugin — nothing left in
~/SwiftBar). Repo == deployed md5 for every touched file;
`chmod +x` verified on every deployed script (all `-rwxr-xr-x`);
post-deploy proofs: plugin render (above), watchdog heartbeat
fresh (20:11:32, APG green), daemon state `86% BCLM=10 charging=0
external=1`, sentinel loaded, tracker cursor == latest tick.
**Config untouched: LAST_UPPER=86, LAST_LOWER=85, SAILING=false.**

## Deployed md5s

| File | md5 |
|---|---|
| bc-watchdog.sh (repo + state dir) | `3ba136a302119bc4be7990684f5b4df8` |
| dispatch.sh | `3885ca23815e652b9157cf4b12ac838d` |
| morning_report.sh | `938a29ceac1ef9e85779f42de300646c` |
| battery-commander.10s.sh | `b286e9ccb886c900e6356a9fb74c0526` |
| bc-episode-tracker.py | `e18f08fc97ee1bfa7bf840823dd1fd4d` (amended) |
| bc-verify.py | `b4125e315d5b9a033ac2b01c7cf6b731` |
| bc-tracker-live.py (new) | `424af2b7ced42d58ea7458cfed23c968` |
| bc-tracker-live.sh (new) | `f3049ef66d2793d6afb59fbb4773fea6` |
| bc-verify-run.sh (new) | `eb890d0d7f1c38c1d85db9de9ec58d0e` |
| bc-watchdog-sentinel.sh (new) | `f7f210d2e74f6d138c1a789fd5051bd7` |
| com.batterycommander.watchdogsentinel.plist (new) | `044807645490b11a46d5e99e926fdd3a` |

## Deviations from the design/sandbox note (with reasons)

1. **Tracker form:** the sandbox note's step-1 phrasing said "port
   the state machines into bc-watchdog.sh". Instead the watchdog
   gained one guarded call to a Python driver that imports the
   proven module byte-identically. Re-writing judging logic in
   shell would have put the Phase C evidence path through a second,
   unproven implementation for zero functional gain; the design's
   observable contract (tracker consumes the tick stream at
   watchdog cadence, `.episode_open` maintained, episodes appended
   at close, §4 storage) is met exactly, and equivalence to the
   batch implementation is test-proven rather than asserted.
2. **`verdicts.jsonl` location:** bc-verify (byte-identical to
   sandbox) writes it to the state-dir root, not
   `verification/` as §4's diagram shows. Kept — the sandbox code
   was not going to be edited for a cosmetic path difference; it
   sits next to `.verification_state`, which §4 also places at root.
3. **Sleep `EXTERNAL_NOTES`** emitted empty in v1 (see step 2).

## Left for later (unchanged gates)

- The first genuine (non-transcribed) sleep sidecar + hosted
  bc-verify run happen tomorrow at the 08:00 agent run.
- Design v2 items remain v2: LIMIT-CHANGE judging (events are
  recorded with `judging-is-v2`), sleep JSONL two-axis surfacing
  beyond the state fields, 30-day field-confidence summary.
- `verify-install.sh` does not yet check the verification files
  (its 12/12 predates this system) — candidate follow-up.
