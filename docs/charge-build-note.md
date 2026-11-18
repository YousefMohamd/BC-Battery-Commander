# Charge Build Note — 2026-11-14 (last-state-wins)

Approved by Yousef 2026-11-14 18:34 EET. Rule (his words, 2026-11-14):
every button sets a PERSISTENT state; the last state he sets is enforced
indefinitely until he changes it; this applies to all buttons.

## Supersession

`charge-design.md` (2026-11-13) designed a charge *session* with a
`.charge_session` file, PREV_UPPER/PREV_LOWER bookkeeping, watchdog
supervision and unconditional restore. **That machinery is superseded by
the last-state-wins rule and was NOT implemented.** Under the rule, the
"Charge to 100% & Hold permanently rewrites the config to 100/99 and
nothing restores 86/85" finding of the charge-design audit is intended
behaviour, not a defect: 100/99 is the state the user set, and it stays
until he sets another. The pre-charge "overhang" is likewise simply the
persisting 100/99 state. bc-limit was not touched (per the design's own
conclusion, the plain charge-to-limit path was already proven live).

## Audit map (all reads verified in the deployed sources)

The single config writer is `bc_apply_limit` (dispatch.sh): validate
(upper 15–100, lower 15–99, lower<upper) → read %/BCLM (fail BEFORE any
write if unreadable) → `save_cfg` → read-back verify. `save_cfg` writes
exactly four keys, atomically: LAST_UPPER, LAST_LOWER, SAILING, SAIL_GAP.
The enforcer (bc-limit) reads the config on its 60 s loop; the limit %
lives only in the config, never in the SMC.

| Action (menu) | Intent | Config write (via bc_apply_limit) | Marker writes |
|---|---|---|---|
| Charge to 100% & Hold (`charge_full`) | charge_full | 100/99, SAILING=false, GAP=1 | `.active_mode`=charge_full, `.charge_target`="100", guard token |
| Disable All Limits (`disable_limit`) | disable_limit | 100/99, SAILING=false, GAP=1 | `.active_mode`=idle, `.charge_target` removed |
| Custom Limit (`limit_custom`) | limit | dialog U/L validated; the written lower is mode-derived (Hold → SAILING=false, GAP=1, lower=U−1; Sailing → SAILING=true, lower=U−gap; both clamped ≥15) | `.active_mode`=idle on success; also `.last_inputs` (dialog-default memory ONLY — never read by enforcement) |
| Stop Charging Now (`stop_now`) | hold_current | CUR/(CUR−1) at current %, SAILING=false, GAP=1 | `.active_mode`=hold, `.hold_since` stamped, `.charge_target` removed |
| Remove Hold (`remove_limit_hold`) | clear_hold | LAST_UPPER/LAST_LOWER re-applied (the *configured* limit — after charge_full that is 100/99, per the approved wrapper decision) | `.active_mode`=idle, `.hold_since` removed |
| Charge to Upper (`charge_to_upper`) | — (direct) | re-applies configured LAST pair only if verify fails | removes stale `.charge_upper_token` |

Other config writers, all persistence-consistent (reapply of the
configured state, never invented values):
- Watchdog `bc_reapply_limit` (its own in-sync copy): called from LAYER3,
  the daemon-check (L8) and the steady-hold ladder — always with the
  config-read `$LAST_UPPER/$LAST_LOWER`.
- dispatch `reapply_limit` and the login reapply path: config-read pair.
- dispatch `reset_defaults`: canonical 86/85 (an explicit user reset).
- dispatch `shutdown` (Quit, FR-007 as amended): 100/99 = stock release.
- `self_healing.sh` canonical reset fires only on a missing/corrupt
  config (recovery default, consolidation M5) — never overrides a valid
  user state.

### `.charge_target` — verdict: LEAVE (marker, enforcer-blind)

Writers: dispatch charge_full (="100"); removed by hold_current,
disable_limit, charge_full failure paths, `kill_charge`, `ensure_clean`
(only when mode=idle), the shutdown purge list, and the watchdog section.
Readers (exhaustive grep over the state dir + plugin + enforcer source):
- **bc-limit v1.2 source: 0 references** to `charge_target`, 0 to
  `active_mode`, 0 to `hold_since` (grep -c, this build). The enforcer's
  whole file contract is: config + `.apg_paused` + `.discharge_session`.
  The flag can never reach enforcement.
- Watchdog `section_charge_target` (existence only): at PCT≥100 it
  removes the flag and, if mode=charge_full, flips `.active_mode`→hold
  and stamps `.hold_since`; if mode≠charge_full it removes the flag as
  stale. It never writes the config.
- Plugin (content, display only): gates the ✓ on the "Charge to 100%
  & Hold" item while mode=charge_full (checked when flag empty or "100").

Why leaving it is correct: the persistent state (config) is complete and
independent of the flag; the watchdog flip is what makes the Mode line
and the Custom Limit ✓ honest after a completed charge (display_state's
BCLM rule is a second, independent guard). Removing the mechanism would
regress display honesty and permanently block `charge_to_upper` (it
cancels while mode=charge_full). The flag-clearing alters only
supervision bookkeeping and display — both converge on the same
persistent config state.

## The one code change (dispatch.sh only)

Race found by the audit: charge_full wrote `.charge_target` BEFORE
`.active_mode`. A watchdog tick landing between the two writes sees
flag-present + mode≠charge_full and stale-clears the flag of a live
intent; the 100% completion flip would then never fire (mode stuck at
charge_full; enforcement unaffected, display/supervision degraded).

Fix: the two writes are swapped — `.active_mode` first, then
`.charge_target` — with an explanatory comment. Every interleaving is
now safe (a tick sees either no flag → no-op, or the flag+mode pair →
correct). Nothing else changed; diff is exactly the swap + comment
(6 added lines, 1 moved line).

- dispatch.sh: `25d75697aaab90ed6710017f04b7874f` → `d3e46993791365ea3d3d3b320e7e0653`
  (repo `src/daemon-helpers/dispatch.sh` == deployed `~/.battery-commander/dispatch.sh`)
- Backups: `~/.battery-commander/backups/dispatch.sh.pre-chargebuild-20261114`
  and `src/daemon-helpers/dispatch.sh.pre-chargebuild-20261114` (both
  `25d75697…`). No backup inside ~/SwiftBar (the duplicate-icon lesson).
- bc-watchdog.sh and the plugin were NOT changed by this build
  (watchdog `a58399b6…`, plugin `d41d5790…`, display_state `431dc3b2…`).
- Patch script kept: `battopt-project/bc-build/patch_chargebuild.py`.

## Display honesty (scope 4) — verified, no change needed

The plugin re-reads the config on every render (defaults 86/85 sanitized
by the live file). The Charge Limits lines interpolate the live values:
"✓ Custom Limit — ${LAST_UPPER}% / ${LAST_LOWER}%", "Remove Hold (return
to ${LAST_UPPER}%/${LAST_LOWER}%)". After a charge_full the next refresh
therefore reads 100/99 — it cannot go stale. The header Mode line is
derived via display_state (authoritative hold: BCLM=10 + AC + not
charging → hold), with LIMIT_IN taken from the same live config read.

## Tests (sandbox only — live config never used as a test target)

New suite `battopt-project/bc-build/test_charge_persistence.sh`
(BC_DASH/BC_BUILD_DIR sandboxes, stubbed ioreg/osascript/launchctl,
control-file battery at 72%):
**20/20 PASS** — run against the repo copy AND again against the
deployed copy. Cases: C0 source-order invariant (mode line 739 < flag
line 740; fails on the pre-patch file by construction), C1 charge_full →
exact 100/99 + mode + flag, C2 disable_limit → 100/99 + idle + no flag,
C3 stop_now → 72/71 + hold + `.hold_since`, C4 remove_limit_hold after
charge_full → stays 100/99 (configured limit), C5 limit_custom 90/89
Hold → exact config, C6 enforcer-source grep evidence (0/0), plus a
live-config md5 guard (unchanged across the suite).

Regressions: `test_discharge.sh` PASS (exit 0), `test_bc_watchdog.sh`
PASS (exit 0) — run detached on the Mac (they exceed the 30 s /run cap).

## Post-deploy proof (2026-11-14 ~18:42 EET)

- Plugin render: `🔌 86%`, `Mode: Holding at 86%`,
  `✓ Custom Limit — 86% / 85%`, `Remove Hold (return to 86%/85%)`,
  `BC limit daemon: active — last tick 2026-11-14 18:42:55`,
  `Daemon state: 86% · BCLM=10 · holding · writes today: 2`.
- Watchdog heartbeat fresh: 18:40:47 / 18:41:55 (PCT=86, mode=hold).
- Daemon state lines 18:40:55 / 18:41:55: pct=86% BCLM=10 charging=0
  external=1, config 86/85.
- Deployed dispatch `-rwxr-xr-x`, md5 == repo.
- **Final live config: LAST_UPPER=86, LAST_LOWER=85, SAILING=false,
  SAIL_GAP=1 — unchanged throughout the build.**

## Observations (recorded, deliberately NOT changed — outside scope)

1. The watchdog's `bc_reapply_limit` validates upper 50–100 / lower
   20–99 (dispatch: 15–100 / 15–99). A user-set limit below 50 (e.g.
   40/39 via Custom Limit) would make the watchdog's reapply refuse and
   log — it never overrides the state, and bc-limit (15–100) still
   enforces it. Parity wart only.
2. `force_reset.sh` carries its own apply implementation (its
   bc_apply_limit mentions are comments + a local copy); recovery path,
   untouched.
3. charge_full and disable_limit converge on the same config (100/99)
   and differ only in `.active_mode` — under last-state-wins the state
   IS 100/99 in both cases; the distinction is intent display only.
