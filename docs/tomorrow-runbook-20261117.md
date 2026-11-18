# Tomorrow Runbook — 2026-11-17: Calibration Day + Finish Day

**Yousef's word (2026-11-17 00:25):** tomorrow is BOTH the
calibration day AND the project finish day — "prepare
everything so we finish tomorrow." This runbook stages the
day as execution-only: every decision is already made, every
gate is named in advance.

## Tonight vs tomorrow — the split

**Tonight (2026-11-17 00:19–…, the finish-preparation
package — DONE before this runbook is used):**
- WS1 identity package built inside the project
  (`BatteryCommander-Identity/`) from the tool's own colours.
- WS2 icon fixed: genuinely transparent logo; new .icns live
  in the app, in `assets/icons/`, and in the state icons.
- WS3 menu cleanup built + deployed: "Stop ALL Services"
  removed, Quit red, decorative emoji out of items/submenus
  (header state icons untouched), SwiftBar line removed;
  FR-007 re-proven on the new binary; sentinel / bc-verify /
  verify-install / health all green after deploy.
- WS4 comprehensive-test catalog written
  (`test-catalog-20261117.md`).
- WS5 this runbook.

**Tomorrow starts at the calibration start-check below.**
Nothing from tonight is re-decided tomorrow.

---

## Part 1 — Calibration (the morning's first job)

### 1.1 Start checks (verify all, in order, before L0)

1. Mac awake and reachable; battery on AC.
2. Daemon = bc-limit **v1.7-stagec**, ticking every 60 s,
   holding: state lines show BCLM=10 at the 86/85 config.
3. Config values: **86/85**, SAILING=false, SAIL_GAP=1
   (values are the invariant — the file has two canonical
   byte forms; do not judge by md5 alone).
4. App = the cleaned finish-prep build (exe `b0e7a35c…`,
   icon `27c1f43c…`), one menu-bar icon, menu opens in the
   cleaned layout (no Stop ALL Services; Quit red).
5. Sentinel clean (no open drift incident); bc-verify
   PHASE_C=VERIFIED; project health HEALTHY.
6. **Health-band re-read (live, at start):** read Health %
   and Cycles from the menu / ioreg. Last reading
   (2026-11-17 00:16): **73% · 569 cycles** → expected band:
   **middle (60–80%)** → **floor 10%, emergency abort 8%,
   supervision line 30%**. Confirm the band from the live
   reading and record both numbers — they are also the
   "before" half of the before/after pair (§1.4).
   If the live reading lands in a different band, the run
   uses THAT band's numbers (high: floor 10 / abort 8 / no
   supervision line; low: floor 15 / abort 12 / supervision
   35) — no other change.
7. No discharge/calibration session files left over; no
   `.tool_closed` flag standing.

Any check fails → stop, fix, re-check. The run does not
start on a dirty baseline.

### 1.2 The legs — expected wall-clock shape

From `calibrate-design.md` (the run is a chain of bounded
segments under one run file; every abort lands on the same
safe state: session removed, config restored to 86/85,
posture restored, one notification with the reason):

| Leg | What happens | Shape |
|---|---|---|
| **L0** Preflight | Snapshot (health, cycles, capacity), band confirmed, run file created | minutes |
| **L1** Charge to verified full | Temporary limit 100/99; full = **two signals**: 100% on 2 consecutive ticks **and** charge actually ended (not charging + cable in, or current → 0) | from ~86%: roughly an hour-scale leg |
| **L1r** Rest at full | 60 min on AC, held at full — the gauge learns the rested top endpoint | 60 min, no attention |
| **L2** Discharge leg | On battery, natural drain only (his real load; on AC the leg parks by design). Checkpoints logged at 50% / 20%; a real notification at **30%** — below 30% he stays nearby. Floor = **two signals**: % ≤ floor on 2 ticks **and** pack voltage ≤ 10.9 V; if voltage disagrees, the leg continues toward the emergency bound and the discrepancy is logged as a finding, never a fake floor | the long leg — a 6900 mAh-design pack at realistic loads takes **hours** (plan the day around it; segments chain automatically across the 240-min session bound) |
| **L3** Low rest | At floor confirmation he is notified to **plug in now** (the run's one time-sensitive moment). On AC a parked session holds the bottom endpoint — neither draining nor charging — for 30 min | 30 min |
| **L4** Recharge to verified full | Temporary limit still 100/99; same two-signal full endpoint as L1; bound 8 h; sleep is harmless in this leg | hour-scale |
| **L5** Close-out | Rest 30 min at full → config restored to **86/85** (read-back verified) → run file closed → post-run snapshot (Cycle will have advanced by 1) → run report written, one notification | 30 min + minutes |

Honest total: **most of the day**, dominated by L2. The
battery ends the run at 100% under the restored 86/85 limit
and settles back by ordinary use over the following days —
the design deliberately does not force it down.

### 1.3 Yousef's checklist — everything asked of him, in one place

- **≈ 5 taps total** across the day (start the run from the
  menu; plug/unplug at the leg turns; the L3 plug-in).
- **~20 minutes of scattered attention** — the rest is
  waiting he can work through.
- **Unplug when L2 starts; stay nearby below 30%** (the run
  notifies at 30%).
- **Charger in reach** from 30% down — the L3 plug-in is the
  one moment that matters.
- **NO lid close during the low leg** (L2 below ~35% and
  L3): sessions end at sleep by design; a sleep in the deep
  leg breaks the run's continuity.
- **No restarts, nothing closes** — his standing supervision
  rule for the drain (he supervises it himself).
- He may use the Mac normally otherwise — natural load is
  what the leg is designed for.

### 1.4 Abort path — always safe

**Plug in, or stop the run from the menu — at any moment, in
any leg.** The run lands on its safe state (session removed,
config restored 86/85 and verified, one notification with
the reason) and ordinary enforcement resumes. Aborting is
never a failure of the day: a partial run still yields its
log, and the finish sequence (Part 2) proceeds — the
delivery report records the calibration as aborted-with-
reason instead of completed.

### 1.5 End verification (mine, at run close)

1. Both endpoints were two-signal (L1/L4 full: % + charge
   end; L2 floor: % + voltage) — from `calibration.log`,
   quoted in the day report.
2. Floor behaviour: lowest % reached, emergency bound never
   crossed (≥ 8% at all times in the mid band).
3. **Health/cycles before-after**: start pair (§1.1.6) vs
   the L5 post-run snapshot. Stated plainly in the report:
   calibration buys gauge **honesty**, not capacity — the
   health number may read **lower** after, and that is the
   procedure working, not damage.
4. Config restored to 86/85 (read-back), daemon holding,
   tracker episode for the run present.
5. Gauge behaviour note: jumps may still occur afterwards;
   expectation is smaller/less frequent, not zero (bc-limit
   v1.5+ read-safety stays the protection either way).

---

## Part 2 — The finish sequence (after calibration, in order)

Each step has its gate. **The hard gate stands (Yousef,
2026-11-16 16:58): no publishing before the comprehensive
test of the tool AND the UI design** — the test is step 1,
and the UI design is judged inside it (catalog Parts C + D).

### Step 1 — Comprehensive test (gate: catalog green)
Run `test-catalog-20261117.md` بند بند: Part A suites →
Part B live proofs → Part C user-eyes (his sitting) →
Part D finish-prep checks → Part E only if a parked issue
produces a concrete live case during the day.
**Gate:** any FAIL stops the sequence — fix forward or roll
back and restart the catalog's Part A. The finish does not
proceed on a red catalog.

### Step 2 — Delivery report (gate: report complete)
One report, the catalog's closing shape: verdict → what
shipped (md5 table) → automated evidence → live proofs
(verbatim log lines) → **calibration episode** (Part 1's
record, incl. health/cycles before-after) → Stage C +
FR-007 record → verification verdicts → user-eyes checklist
as he marked it → known limitations stated plainly →
remaining gated steps → rollback inventory.

### Step 3 — Local commit (gate: his go on the report)
Per the adopted recommendations (2026-11-16, "اتبع توصياتك
كلها") and `commit-inventory-20261116.md`: promote the
bc-build core to a top-level home; **6 logical commits**;
app committed **sources-only**. Local only — nothing leaves
the machine at this step.

### Step 4 — DMG (gate: commit done + his go)
Per `dmg-packaging-spec-20261116.md`: **unsigned v1,
Intel-only claim, app-only DMG**. At install the daemon
relocates to `/Library/PrivilegedHelperTools` +
`/Library/LaunchDaemons`; the uninstaller verifies the
BCLM=100 release **before** removing anything.

### Step 5 — GitHub + publish (LAST; gate: his hands + his final go)
He connects GitHub himself; the push and the publish happen
only on his final explicit go, after steps 1–4 are green.
**NO purchase ever** — the unsigned-v1 decision stands; no
developer-account step exists in this sequence.

---

## Day shape, honestly

Calibration is hours (L2 dominates). The finish sequence
runs after it the same day, per his word — test and report
are the long poles; commit and DMG are mechanical once
green. If the calibration leg runs long, the sequence
compresses from the report side, never by skipping catalog
entries: بند بند, nothing omitted, or the day reports
exactly where it stopped.
