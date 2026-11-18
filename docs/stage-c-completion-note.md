# Battery Commander — Stage C Completion Note

**Executed:** 2026-11-16 23:43 → 2026-11-17 00:05 EET (build phase
earlier the same evening; approval: Yousef, 2026-11-16 22:29 EET).
**Package:** stage-c-readiness-20261116.md (FR-007 contract §1,
cutover §2, rollback §3, dry-verification + decisions addenda).
**Verdict: STAGE C COMPLETE — all three FR-007 quit/relaunch cycles
PASS. No rollback needed.**

## End state (live, 2026-11-17 ~00:05 EET)

- **App:** the Stage C build is the installed app —
  `/Applications/BatteryCommander.app`, exe md5 `2974efa3…`,
  bundle id `com.batterycommander.launcher` (unchanged), grouped
  menu, FR-007 app side live. Final running PID at close-out:
  62227 (presence matters, not the number).
- **Daemon:** bc-limit **v1.7-stagec** (source `c8ae7ee4…`, binary
  `b0651e89…`) ticking every minute; FR-007 branch rebased onto
  v1.6.1.c with the discharge-clear gap fix inside the branch.
- **Limit:** config 86/85, md5 `69c6c438…` (canonical form),
  SAILING=false, SAIL_GAP=1; BCLM=10 hold at close-out.
- **Plugin:** retired (parked 18:38 by Yousef's order at
  `~/.battery-commander/backups/battery-commander.10s.sh.parked-20261116`);
  exactly one BC menu-bar icon (the app's) by construction — one
  app process, plugin file absent from ~/SwiftBar.
- **Stray applet PID 21524:** untouched throughout (never signalled,
  never quit; all quits were PID-addressed AppleEvents to the app's
  own PID via a purpose-built helper, `stagec-test/quit-by-pid`).

## Bundle swap (cutover §2 step 4)

- Stage B bundle parked: `mv /Applications/BatteryCommander.app`
  → `/tmp/BatteryCommander-stageb-live-20261116.app`; new build
  installed by `ditto` from `app-redesign-src/build/`.
- Verified after install: exe md5 `2974efa3…`; `diff -r` vs the
  bench build CLEAN; `codesign --verify` rc=0.
- Backups (all verified before the swap): Stage B bundle ×2
  (state-dir backups + repo `app/`, exe `5739955e…`), daemon
  `bc-limit.pre-stagec-20261116` (`7ec16c8d…` = v1.6.1), plugin
  copy `86c718e5…`.
- First launch 23:43:43 → LAUNCH COMPLETE in 5 s; housekeeping
  sequence in actions.log; no `.tool_closed` left behind; daemon
  holding 86/85 throughout.

## FR-007 proof — the three cycles (addendum B protocol, binding)

Quits were driven as genuine AppleEvent quits of the primary app
(the exact path `applicationWillTerminate`'s guarded flag write was
built for); the menu-Quit path writes the same flag first (code
verified in the build phase).

### Cycle i — Quit at hold (86/85, BCLM=10) — PASS
- 23:45 quit (app PID 49440): `.tool_closed` written by the app
  (`BY=BatteryCommander.app (Quit)`); app process gone; applet
  untouched.
- 23:46:04 daemon: `tool closed (.tool_closed): releasing limit —
  WRITE BCLM=100` → `RELEASE OK: BCLM=100 verified by read-back
  (FR-007); enforcement idle while .tool_closed stands`.
- Stock behaviour confirmed: ioreg IsCharging=Yes — the battery
  charged unimpeded; next tick logged `limit already released;
  enforcement idle`. Config md5 unchanged (`69c6c438…`).
- Relaunch 23:47:36 (PID 51897): housekeeping cleared the flag
  (LAUNCH COMPLETE 5 s); first daemon tick after (23:48:05):
  `WRITE: BCLM=10 (pct=91%)` → `WRITE OK … verified by read-back`;
  IsCharging=No. Enforcement resumed ≤ 1 tick; one icon.

### Cycle ii — Quit while charging toward a limit — PASS
- Setup via the menu's own path: `dispatch.sh charge_full` →
  config 100/99; 23:50:05 daemon `APG load-pause: resume allowed
  (reason=load)` + `WRITE: BCLM=100 (pct=92%)` verified;
  IsCharging=Yes (charging toward the limit).
- 23:50 quit (PID 51897): flag written; 23:51:05 daemon:
  `tool closed (.tool_closed): limit already released (BCLM=100);
  enforcement idle` — BCLM stayed 100 by read-back; charging
  continued as stock (capacity rising 4578 → 4582+).
- Relaunch 23:51:51 (PID 54822): flag cleared in housekeeping;
  23:52:05 tick resumed enforcement under 100/99 (`nothing to do`,
  charging=1) ≤ 1 tick.
- Config restored to 86/85 through the real Custom Limit path
  (`limit_custom`, dialog-stub technique: "86/85" + "Hold") →
  config md5 back to canonical `69c6c438…`; 23:55:07 daemon
  `WRITE: BCLM=10` verified — hold re-applied.

### Cycle iii — Quit while discharge mode engaged — PASS (= bench suite case C9, live proof)
- Setup: Smart Discharge via the real dispatch path (dialog stub,
  target 85 — the configured lower). 23:58:07 daemon
  `DISCHARGE MODE WAITING` (v1.6.1 two-component confirmation);
  23:59:02 SESSION_ARMED; 23:59:07 `DISCHARGE MODE ENGAGED:
  manager call ok (target=85 pct=94%)`; marker
  `.bc-limit-acengage` present; ioreg ExternalConnected=No —
  discharge mode genuinely engaged on AC.
- 23:59 quit (PID 54822): flag written; 00:00:07 daemon:
  `DISCHARGE MODE DISENGAGED: FR-007 tool-closed release (Quit
  while discharge mode was engaged)` — the gap fix working live
  (discharge(0) issued inside the flag branch, marker removed) —
  then `tool closed (.tool_closed): releasing limit — WRITE
  BCLM=100` → `RELEASE OK: BCLM=100 verified by read-back
  (FR-007)`.
- Adapter path restored: ioreg ExternalConnected=Yes,
  IsCharging=Yes (stock charging) — the Mac was stock with the
  adapter live again, exactly as the protocol requires.
- Relaunch 00:01:17 (PID 62227): flag cleared in housekeeping
  Step 1 (LAUNCH COMPLETE 6 s). First tick (00:02:10) closed out
  the session bookkeeping (`DISCHARGE MODE DISENGAGED: conditions
  changed`); the monitor ended the session (reason=superseded —
  see observation 1). 00:03:10 tick: `WRITE: BCLM=10 (pct=94%)`
  verified — 86/85 hold re-applied. No session file, no marker,
  no flag at the end; exactly one actor (the daemon) throughout.

## Close-out checks (2026-11-17 ~00:04–00:05 EET)

- **Sentinel:** manual run rc=0; state clean (LAST_RUN fresh,
  INT_FP empty, all alert counters 0) — no integrity drift with
  the 13-pair set.
- **bc-verify:** `PHASE_C=VERIFIED Nov 16`, CONFIDENCE=FULL
  (see the FAIL-episode annotation below — it does not touch the
  Phase C verdict).
- **verify-install:** ALL CHECKS PASSED (12/12).
- **Health:** PASS 17 | FAIL 0 | WARN 2 — Project is HEALTHY.

## Annotation — the one FAIL episode tonight (expected, explained)

The 00:04 scoring run recorded `FAILS_24H=1`: episode
`hold-1794837951` (16:05:51 → 23:49:55, upper 86, verdict FAIL,
note `bclm-left-10`). Dissection from the episode record itself:
`charging_ticks: 0`, `gauge_events: 1` — the 86 → 92 rise inside
the episode was pure gauge drift at zero current (the 21:09 jump;
under amended §3 that alone passes with a note). The FAIL trigger
is BCLM leaving 10 at 23:46–23:49 — **which was cycle i's
deliberate FR-007 release**: the tool was intentionally closed
(flag standing, stock charging) as the test protocol requires.
Not an enforcement failure: while `.tool_closed` stands,
non-enforcement is the correct state, verified by read-back at
every step. The morning report's "Hold ⚠" traces to this window.

## Observations (recorded, not blockers)

1. **Config rewrites supersede live discharge sessions** — seen
   twice tonight: (a) the watchdog's violation-ladder reapply
   (23:54:58, same-values rewrite) superseded the pull-down
   session started by the 86/85 restore before it could engage;
   (b) the app's launch housekeeping reapply (00:01–00:02)
   superseded the Smart Discharge session after cycle iii's
   relaunch, so the session did not resume. Both are the monitor's
   pre-existing config-signature rule meeting the tool's own
   reapply writers — not Stage C regressions. Side effect worth
   knowing: Quit + relaunch also ends any live session, which is
   consistent with the "Quit closes the tool completely" contract
   (FR-007 as amended 2026-11-13).
2. **R1 (least-change, per Yousef's "follow your recommendations"
   + no recorded recommendation):** the "Sailing Range" name is
   KEPT — the audit calls it the tool's long-standing name; the
   values were correct either way. No code changed.
3. **R2 (least-change):** power/sleep layering confirmed as-is —
   power profiles own sleep/display times; the sleep layer owns
   standby/hibernatemode; menu display already truthful. No code
   changed.
4. **applicationWillTerminate guard (build-phase refinement,
   restated for the record):** the flag is written on the menu-Quit
   path unconditionally, and in `applicationWillTerminate` only by
   the primary instance — a duplicate instance
   (`.duplicateInstance`) never writes it, so a transient second
   instance cannot release the limit under the still-running
   primary. The FR-007 contract is intact for every real close
   path of the primary (menu Quit, logout, AppleEvent quit — the
   last is what tonight's cycles exercised).
5. **Battery level after the cycles:** ~94–95% in hold. The
   release windows deliberately let the pack charge as stock
   (that is the proof), so it sits above the 86 upper in a normal
   hold; return toward the limit is governed by the tool's own
   guardian rules (the corrective path was APG-suppressed at last
   check). No manual drain was forced.

## Rollback status

Not needed. All rollback artifacts remain in place (Stage B bundle
×2 + /tmp parking copy, `bc-limit.pre-stagec-20261116`, plugin
parked copy, sentinel/health pre-stagec backups) should Yousef
ever ask for a revert.
