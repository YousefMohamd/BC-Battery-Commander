# Final Re-Test + Delivery Report Plan — 2026-11-16 (refreshed)

**When this runs:** after Stage C lands (redesigned app as the
only UI, bc-limit **v1.7** with the FR-007 Quit contract) and
after the live calibration run (its own approved day). It is
the last gate before the local commit → DMG → publish
sequence. Written against today's code (bc-limit **v1.6.1-ac**
+ the 2026-11-16 latency/icon fixes); every count below is
today's measured baseline — the re-test must meet or explain
each one.

**Deliberately excluded:** Yousef's two 2026-11-16 reports
(end-to-end slowness; last-written values not saved) are
**parked by his instruction** — they are not re-tested,
investigated or "verified fixed" here. They re-enter only if
they reproduce during his organic use, as their own item.

**Execution-day refresh (do first):** the Stage C readiness
package's step-0 md5 expectations were written against v1.3 /
plugin `5db2957e…`; re-record the then-live md5s before
starting (today: daemon `7ec16c8d…`, watchdog `ac3166df…`,
display_state `f8ba2fed…`, plugin `86c718e5…`, dispatch
`98db478c…`; v1.7 will supersede the daemon again).

## 1. Automated suites — run all, in this order

Run against the final deployed code (post-Stage C binaries),
from the repo bc-build, and record PASS/FAIL/SKIP verbatim.

| # | Suite | Today's baseline (v1.6.1-ac) | Post-Stage C expectation |
|---|---|---|---|
| 1 | `test_bc_limit_calibrate.sh` | 15/15 | 15/15 against the v1.7 source |
| 2 | `test_bc_limit_discharge.sh` | 11/11 | 11/11 |
| 3 | `test_bc_limit_apg.sh` | 9/9 | 9/9 **plus** the readiness addendum case: `.tool_closed` + load-pause → release still wins |
| 4 | `test_bc_limit_gauge.sh` | 6 PASS / 2 SKIP | PASS with both halves exercised — needs one charging window and one hold window; schedule the run across a natural charge, don't force it |
| 5 | `test_bc_limit_ac.sh` | 14 PASS / 0 FAIL / 1 SKIP | ≥ today's; A9 (orphan) stays opportunistic |
| 6 | FR-007 flag cases (Stage C sandbox set) | dry-run proven on the draft | Re-run against rebased v1.7: flag → release line; no flag → v1.6.1 behaviour identical; matrices 1–2 above are the regression half |
| 7 | `test_discharge.sh` (monitor) | 36/36 | 36/36 |
| 8 | `test_charge_persistence.sh` | 51/51 | 51/51 |
| 9 | `test_calibration.sh` | 98/98 | 98/98 |
| 10 | `test_bc_watchdog.sh` | PASS | PASS |
| 11 | Sentinel suite | 41/41 | PASS on the **post-Stage C pair set (13 pairs** — plugin pair removed at cutover); the count may differ, the verdict may not |
| 12 | Sidecar + dispatch suites | 15/15 | 15/15 |
| 13 | Tracker equivalence | PASS | PASS |
| 14 | `bc-verify.py` (live store) | PHASE_C=VERIFIED, exit 0 | VERIFIED, exit 0, on the re-test morning's 08:00 run or a manual run |
| 15 | `verify-install.sh` | 12/12 | 12/12 with post-Stage C expectations (app present; plugin absence is now correct) |
| 16 | `project_health.sh` | 17 PASS / 0 FAIL (HEALTHY) | FAIL 0 with the Stage C check swap (app-exe check replaces the plugin-presence check) |
| 17 | App coverage | plugin↔app parity 146/146 (soak era) | **Post-Stage C form:** app `--dump-menu` action coverage **48/48 both directions** vs the final action set; Smart Discharge item + Sleep Mode subtree byte-identical to `app-redesign/menu-design.md` (the frozen shapes) |

Any FAIL stops the re-test; fix-forward or roll back per the
Stage C plan, then restart this section from suite 1.

## 2. Live behaviours — re-prove each, in this order

Safe order: every proof ends back at the **86/85 hold**;
the Quit test is last because it releases the limit.

1. **Hold.** On AC at 86/85: daemon state lines show
   pct=86, BCLM=10, charging=0 across ≥ 30 min; watchdog
   heartbeat fresh; no session files. *Evidence:* daemon log
   excerpt + the verification tracker's hold episode.
2. **Charge resume under load.** With APG yellow/red from CPU
   load only (temp < 38 °C, reason file = `load`): set
   100/99 via Charge to 100% → daemon logs
   `APG load-pause: resume allowed (reason=load)` +
   `WRITE OK: BCLM=100 verified by read-back`; charging
   starts. Revert to 86/85; hold re-engages.
   *Pattern:* the 2026-11-16 00:38 proof. *Thermal half:*
   fixture-only (suite 3) — never heat the battery for a test.
3. **On-AC discharge to a lower limit.** At the 86 hold, set
   Custom Limit 80/79 via the real menu path → session arms →
   `DISCHARGE MODE ENGAGED` on the first daemon tick after
   arming → drains on AC (ExternalConnected flips, negative
   current) → `DISCHARGE MODE DISENGAGED: target reached` →
   `SESSION_COMPLETE … reason=target-reached`; cable attached
   throughout. Restore 86/85; charge-back; hold.
   *Pattern:* the 2026-11-16 14:37–14:57 proof.
4. **On-battery discharge.** Start Smart Discharge and unplug
   (or start unplugged): session goes ACTIVE on battery,
   drains to target, completes; replug → normal charge to
   the hold. *Pattern:* the 2026-11-15 23:17–23:33 proof.
   Yousef's hands do the unplug/replug — a user action, not a
   forced test.
5. **Gauge-jump refusal.** Cannot be summoned on demand and
   must not be forced. Re-proof = suite 4's fixture cases
   (a ≥5-point unconfirmed move produces no write;
   `HOLD DEFERRED` without a second signal) **plus** the
   verification system's §3 scoring of any natural jump in
   the re-test window (drift at zero current with BCLM=10
   throughout scores as gauge drift, not overshoot). If no
   natural jump occurs in the window, the suite evidence
   stands alone and the report says so.
6. **Quit release (FR-007 — the Stage C proof).** Yousef
   clicks Quit in the app → icon disappears → ≤ ~70 s the
   daemon logs the release ending `RELEASE OK: BCLM=100
   verified by read-back` → plugged in below 100%, the
   battery visibly charges past 86% (stock) → config
   byte-unchanged (86/85) → he relaunches the app →
   housekeeping clears `.tool_closed` → enforcement resumes
   ≤ ~70 s. Pass = both directions in logs **and** menu bar.
7. **Calibration (by reference).** The live run happened on
   its own day: cite its episode (result, floor behaviour,
   gauge before/after) from `calibration.log` + the tracker.
   Not re-run here.

## 3. User-eyes items (Yousef, one short session)

Automation cannot click the menu or judge pixels — these are
his, batched into one sitting:

- [ ] Exactly **one** BC menu-bar icon (the app's); the
      plugin icon is gone.
- [ ] Icon state map correct in each state he can reach:
      🔌 on charger · ⚡ charging · 🔴 on battery ·
      🔋 during a discharge session (the 2026-11-16
      classification fix).
- [ ] Menu colours match the sampled palette
      (`app-redesign/palette.md`) — headers and live-state
      lines; grouped structure as designed; Smart Discharge
      and Sleep Mode shapes unchanged (frozen).
- [ ] Header correct ≤ ~4 s after launch; menu opens with no
      visible lag he finds objectionable (his call, not a
      benchmark).
- [ ] Login item present, resolving to
      `/Applications/BatteryCommander.app`; app relaunches
      cleanly at login (or Launch at Login toggle state as
      he set it).
- [ ] Launchpad shows the app with the correct icon (the
      standing `killall Dock` cache item, if still needed).
- [ ] About text correct; notifications (session complete,
      overshoot) arrive and read correctly.
- [ ] The stray Stage B-era applet is gone from the menu
      bar after his next natural logout/restart (it exits on
      its own; nobody kills it).

## 4. Delivery report — table of contents

The re-test produces one delivery report with exactly this
shape:

1. **Verdict** — one paragraph: ship / don't ship, and why.
2. **What shipped** — component/version/md5 table (daemon
   v1.7, watchdog, dispatch, display_state, app build,
   sentinel set), config of record (86/85).
3. **Automated evidence** — §1's table with the re-test's
   actual counts beside today's baselines; every SKIP named
   with its reason.
4. **Live proofs** — §2's six behaviours, each with its
   verbatim log lines and timestamps.
5. **Calibration episode** — the live run's record (§2.7).
6. **Stage C + FR-007** — cutover record and the Quit proof.
7. **Verification-system verdicts** — bc-verify output,
   episode counts, FAILS 0/0 expectation.
8. **User-eyes checklist** — §3 as Yousef marked it.
9. **Known limitations, stated plainly** — sleep-entry BCLM
   behaviour (status quo, Option C unless he later decides
   otherwise); per-family support honesty (Intel/BCLM
   verified; other mechanisms probe-dependent); the two
   parked 2026-11-16 reports and their status.
10. **Remaining gated steps** — local commit (inventory
    ready: `commit-inventory-20261116.md`), DMG (spec ready:
    `dmg-packaging-spec-20261116.md`), GitHub connection +
    publish LAST — each awaiting its own approval.
11. **Rollback inventory** — every backup created across
    Stage C and the re-test, with paths, so any step can be
    undone in minutes.
