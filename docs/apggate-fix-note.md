# APG Resume-Gate Fix — bc-limit v1.4-apggate + watchdog pause-reason

**Date:** 2026-11-16 00:27–00:49 EET · **Approved:** Yousef, 2026-11-16 00:26 ("اعتمد إصلاح بوابة APG في الديمن وكمّل")
**Status:** DEPLOYED + LIVE-PROVEN. No rollback needed.

## The bug (live evidence, 2026-11-16 00:09)

Yousef pressed **Charge to 100%**. dispatch applied it, bc-limit refused to act:

```
[2026-11-16 00:08:48] charge_full: START
[2026-11-16 00:08:48] bc_apply_limit: config written 100/99 (pct=86 BCLM=10)
[2026-11-16 00:09:08] bc-limit 1.3-calibrate starting (dry_run=0)
[2026-11-16 00:09:08] state: backend=bclm upper=100 lower=99 pct=86% BCLM=10 charging=0 external=1
[2026-11-16 00:09:08] APG paused: resume suppressed        ← the bug
```

The `.apg_paused` behind it was raised by APG on **CPU load alone**
(loadavg 10.79 → 6.16, Min browser renderer) at battery temp **30.66 °C**.
bc-limit's M6 gate treated every APG pause as thermal, so a user-initiated
resume could be frozen invisibly by load — the same user-visible class as
the 2026-11-14 ~15 h incident. The 2026-11-15 full-fix temp-gated the
watchdog's discharge/calibration paths but explicitly left this daemon
gate unchanged for lack of evidence; this press was the evidence.
Product rule (Yousef, 2026-11-15 22:35): the button must keep working
when pressed; temperature is the legitimate hard gate.

## Fix Part 1 — the watchdog records WHY it paused

`bc-watchdog.sh` `apg_classify` now maintains a companion file
`~/.battery-commander/.apg_pause_reason` next to `.apg_paused`:

- Written **atomically (tmp+mv) on every tick while the pause exists**,
  containing exactly `thermal` or `load`.
- **`thermal` ⟺ current battery temp ≥ 38 °C** (APG's own yellow temp
  threshold) **OR the temperature reading is unavailable** (fail-safe);
  otherwise `load`. A hysteresis-held pause at temp 37.x therefore reads
  `load`; a pause at temp 30 with load 9 reads `load`; temp 39 at any
  load reads `thermal`.
- **Removed whenever the pause clears**, on every path (green transition
  and the `.apg_off` path included).
- Implementation: one helper (`_apg_reason_sync`) fed from apg_classify's
  three exits (`.apg_off`, missing-temp, normal), called every tick —
  so the reason tracks the *current* temperature even when the APG state
  itself does not change (hysteresis). `.apg_paused` is untouched:
  still a pure existence flag with byte-identical semantics.
- Consumer audit before the change (grep over the repo + state dir):
  `dispatch.sh`, `ac_watcher.sh`, `ensure_limit.sh` read `.apg_paused`
  by existence only; the sentinel mentions it in a comment; the tracker
  counts pauses from logs; bc-limit is the only other reader (Part 2).
  Only the watchdog creates/removes it. The companion file breaks
  nothing.

## Fix Part 2 — bc-limit v1.4-apggate

Base: live v1.3-calibrate source. Single delta in the M6 APG branch of
the resume decision (the branch reached only when pct ≤ lower and
BCLM ≠ 100):

- `.apg_paused` exists → read `.apg_pause_reason`:
  - exactly `load` → **do not suppress**; proceed with the resume write;
    log `APG load-pause: resume allowed (reason=load)`.
  - `thermal` → suppress as before; log
    `APG paused: resume suppressed (reason=thermal)`.
  - missing / unreadable / empty / anything else → suppress; log
    `APG paused: resume suppressed (reason=unknown)` (fail-safe: a pause
    of unknown origin is treated as thermal).
- The **discharge-session suppression branch is a separate, earlier
  branch and is behaviour-identical** (proven by suite case 8 and by
  discharge-matrix case 10 against the v1.4 binary). Everything else in
  the daemon is unchanged; the diff vs v1.3 contains only the version
  string (`1.4-apggate`), the reason-reader helper, the M6 branch, and
  comments.

## Tests (all on the final code; verdicts are the suites' own)

| Suite | Result |
|---|---|
| **test_bc_limit_apg.sh (NEW, 9 cases, dry-run vs v1.4)** | **9/9** — load→allowed+WOULD WRITE; thermal→suppressed; missing→suppressed (unknown); garbage→suppressed (unknown); empty→suppressed (unknown); no pause→normal; stale reason w/o pause→normal, no APG line; session+pause+load→session suppression only; load+real 86/85 config→"nothing to do" |
| test_bc_limit_calibrate (pinned v1.3) | 15/15 |
| test_bc_limit_calibrate (**v1.4 source substituted**) | 15/15 |
| test_bc_limit_discharge (pinned v1.2) | 11/11 |
| test_bc_limit_discharge (**v1.4 source substituted**) | 11/11 |
| test_bc_watchdog (extended, new Phase F) | PASS — F1 temp 45→`thermal`; F2 temp 30 + load 9→reason flips to `load` with **no APG state change**; F3 green→pause + reason removed; F4 temp reading lost mid-pause→reason `thermal`, pause untouched; F5 `.apg_off`→pause + reason removed |
| test_discharge | 36/36 |
| test_charge_persistence | 51/51 |
| test_calibration | 98/98 |
| sentinel | 41/41 |
| sidecar + dispatch | 15/15 |
| tracker equivalence | PASS (0 failures) |
| bc-verify live | PHASE_C=VERIFIED, exit 0, fails 0/0, confidence FULL |
| verify-install | 12/12 (incl. daemon plist → new binary executable) |
| project health | PASS 17 / FAIL 0 (WARN 2) |
| plugin ↔ app parity | 45/46 actions shared; the one plugin-only action is `open_app` (launches the app — structurally absent from the app's own menu) |

Method note: the first detached batch runner was written with an
unquoted heredoc, which baked its `EXIT=` echoes and silently skipped
the two v1.4-substituted matrix runs. This was caught from the suites'
own output (missing summary lines), and both matrices were re-run
directly — the 15/15 and 11/11 above are from those direct runs. Every
other count in the table is the suite's own printed verdict.

## Deploy (watchdog first, then daemon)

Backups (md5-verified before deploy):
- `bc-build/bc-limit.pre-apggate-20261116` = v1.3 binary `c9ddf76a…`
- `src/daemon-helpers/bc-watchdog.sh.pre-apggate-20261116` = `cfc52ba1…`
- `~/.battery-commander/backups/bc-watchdog.sh.pre-apggate-20261116` = `cfc52ba1…`
- `bc-build/test_bc_watchdog.sh.pre-apggate-20261116` = `cfdee23f…`

Deployed:
- Watchdog `src/daemon-helpers/bc-watchdog.sh` → `~/.battery-commander/bc-watchdog.sh`,
  md5 **`382d22476d6161e216a082fb51b65d0d`**, chmod +x, heartbeat verified.
  Its first live tick (00:36:51) created `.apg_pause_reason` = `load`
  (pause present, temp ~30 °C) — before the new daemon existed.
- Daemon: `bc-limit-v1.4.c` (md5 `2f317a2bad75cc7b13db3e46c9afb44d`)
  compiled with `clang -Wall -Wextra`, **zero warnings**; binary md5
  **`a74e70220b2da881386b820aa3966245`** moved onto the daemon path
  `bc-build/bc-limit`; `sudo -n launchctl kickstart -k
  system/com.batterycommander.bclimit` (exit 0). First tick:
  `[00:37:08] bc-limit 1.4-apggate starting (dry_run=0)` → normal
  86/85 hold tick ("nothing to do", BCLM=10).

## Live proof — the exact 00:09 scenario, replayed

Pre-state (00:37:43): `.apg_paused` present, APG yellow, reason `load`,
TempBatteryPack **30.62 °C** — identical conditions to the failure.

```
[2026-11-16 00:37:44] bc_apply_limit: config written 100/99 (pct=86 BCLM=10)   (dispatch.sh charge_full, the menu's own path)
[2026-11-16 00:38:08] bc-limit 1.4-apggate starting (dry_run=0)
[2026-11-16 00:38:08] state: backend=bclm upper=100 lower=99 pct=86% BCLM=10 charging=0 external=1
[2026-11-16 00:38:08] APG load-pause: resume allowed (reason=load)
[2026-11-16 00:38:08] WRITE: BCLM=100 (pct=86%)
[2026-11-16 00:38:08] WRITE OK: BCLM=100 verified by read-back
```

Charging confirmed: ioreg `IsCharging = Yes`; by the revert the gauge
had risen 86 → 87. Revert through the menu's own path (Custom Limit
86/85 via dispatch `limit_custom`, dialog answered by the project's
osascript-stub technique: "86/85" + "Hold"):

```
[2026-11-16 00:41:50] bc_apply_limit: config written 86/85 (pct=87 BCLM=100)
[2026-11-16 00:42:09] state: backend=bclm upper=86 lower=85 pct=87% BCLM=100 charging=1 external=1
[2026-11-16 00:42:09] WRITE: BCLM=10 (pct=87%)
[2026-11-16 00:42:09] WRITE OK: BCLM=10 verified by read-back
[2026-11-16 00:42:55] heartbeat: PCT=88 BCLM=10 cfg=86/85 NCR=14 EXT=Yes IsChg=No mode=hold APG=yellow backend=bclm
```

The watchdog cleared the stale `.charge_target` as before. (The 88 in
the heartbeat is gauge re-estimation at zero current — IsChg=No,
BCLM=10 — the known drift behaviour, not charging.) Two stub attempts
before the successful revert were no-ops: the first stub file had been
mangled by shell expansion at creation time and answered empty, so
dispatch exited at its "Empty input" guard with config still 100/99;
the corrected (base64-transferred) stub then drove the real dialog
flow. No state was affected by the failed attempts.

## Final live state (00:48 EET)

- Config: LAST_UPPER=86, LAST_LOWER=85, SAILING=false, SAIL_GAP=1.
  Byte note: md5 currently `07be808a…` (53 B, trailing newline) rather
  than `69c6c438…` (52 B) — at 00:41:54 the watchdog's own ladder
  reapply (`bc_reapply_limit: config written 86/85`) rewrote the file
  in its byte format 4 s after the revert; dispatch's writer omits the
  final newline. Same four lines, same values — the md5 flips with
  whichever of the tool's own two writers wrote last. This is
  pre-existing system behaviour, not a state deviation.
- Daemon: bc-limit **1.4-apggate** ticking; latest tick pct=88 (gauge),
  BCLM=10, charging=0, "nothing to do" — clean hold.
- APG: **green** (load subsided); `.apg_paused` and `.apg_pause_reason`
  both absent — the reason file's cleanup path proven live as well.
- `.active_mode` = hold; no discharge session; no calibration run;
  `.charge_target` cleared.
- Untouched per limits: /Applications app + login item, plugin,
  stray applet PID 21524, pmset, git (no commit).

## Stage C impact

The FR-007 draft (`bc-limit-v1.4-stagec-DRAFT.c`) now rebases onto
v1.4-apggate and becomes **v1.5** at Stage C — see the addendum appended
to `stage-c-readiness-20261116.md`. The draft's dry-run results carry
over in substance (its delta is disjoint from the M6 gate), but its
matrices must be re-run against the rebased source during Stage C.
