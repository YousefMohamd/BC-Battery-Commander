# Battery Commander — Standalone App 48 h Soak Log (Stage B)

## Soak window

- **Soak start: 2026-11-14 21:10:27 EET** (installed native app launched;
  process up, first correct header `🔌 91% mode=hold` at 21:10:31 EET).
- **Soak end: 2026-11-16 21:10:27 EET** (start + 48 h, Monday).
- Installed bundle: `/Applications/BatteryCommander.app` (native Swift app,
  bundle id `com.batterycommander.launcher`, LSUIElement) — executable
  md5 `5739955e16cd06ab9c41aff09e3e5b38`; installed bundle is diff-identical
  to the repo bench build `src/app/build/BatteryCommander.app`.
- Running alongside: the SwiftBar plugin (untouched, md5
  `b286e9ccb886c900e6356a9fb74c0526`) — two BC icons for the soak, per the
  approved Stage B design.
- App process at start: PID 12066, RSS ~21 MB, 0.0 % CPU between ticks.
- Backend at start: bc-limit v1.3 holding (BCLM=10), config 86/85,
  watchdog heartbeat fresh, sentinel loaded. Gauge note: at soak start
  the gas gauge reads 90–91 % against the 86 % limit — the known gauge
  re-estimation drift at zero current with BCLM=10 (not charging); the
  app's launch housekeeping asserted `.active_mode=idle` for the
  watchdog, exactly as the old launcher did on overshoot launches.

## FR-006 merge outcome (summary; full checklist in app-stage-b-note.md)

The launcher applet's whole launch sequence now runs inside the native
app, once per launch (Housekeeping.swift): launch lock, flag clears,
plugin restore, enforcer/powerwatch/watchdog checks (never auto-load),
config read + validation, dispatch reapply_limit, ioreg reconciler,
BCLM read-back verify, overshoot → idle assertion, plugin touch,
SwiftBar launch-if-absent, plugin presence verify — same actions.log
lines as the applet era. Proven live at soak start (actions.log
21:10:31–21:10:37, "=== LAUNCH COMPLETE in 5s ==="). Applet `on idle`:
obsolete (app has its own 10 s timer). Applet `on quit` → dispatch
shutdown: DEFERRED to Stage C (amended FR-007), not dropped.

## First-hour proof (2026-11-14 evening)

- Launch: PID 12066 from the installed path; first correct header ≤ 4 s.
- Ticks: 10 s cadence in the app log (21:10:31 → 21:11:02 → …).
- Parity from the INSTALLED copy: `--dump-menu` vs fresh plugin render
  = PASS, 146/146 canonical lines.
- Crash reports: none for the bundle in ~/Library/Logs/DiagnosticReports.
- Plugin/backend re-verified after install: plugin md5 unchanged,
  daemon ticking (pct ~90, BCLM=10), watchdog heartbeat fresh (APG
  green), sentinel loaded, login item still → /Applications path.
- Known leftover: the old applet PROCESS (PID 21524, started 2026-11-13)
  is still alive, idling from its parked bundle — terminating processes
  via the File API is policy-blocked, and a graceful quit would fire
  the applet's old shutdown handler, so it is left alone. It does
  nothing (60 s idle handler), holds no locks, and disappears at the
  next logout/restart; from then on the login item starts only the
  native app. Do not script-quit it.

## Observation list for the soak window

1. **Interactive clicking (Yousef's eyes — automation cannot do this;**
   osascript assistive access is denied from the agent shell): click
   through the native app's menu during normal use; confirm items
   behave exactly like the plugin's (same dialogs, same results),
   especially dialogs (Custom Limit) and the Calibration/Verification
   sections. Note any item that disagrees.
2. **Crash watch:** any new file in ~/Library/Logs/DiagnosticReports
   naming BatteryCommander — none acceptable.
3. **Daily verification verdicts:** the 08:00 morning report now runs
   bc-verify; the menu's "Verified:" line must stay truthful
   (Phase C: VERIFIED Nov 13; daily hold/cycle verdicts accumulate).
4. **Sentinel alerts:** the watchdog sentinel must stay silent unless
   the watchdog heartbeat genuinely stalls while the Mac is awake.
5. **Header agreement:** app icon vs plugin icon — same glyph, same %,
   every tick (gauge drift moves both together; they share bc-status).
6. **Footprint:** app RSS should stay in the ~19–25 MB band, ~0 % CPU
   between ticks; no missed-tick drift over sleep/wake cycles.
7. **Sleep/wake:** after each wake, the app should resume ticking
   within seconds and the header must match the plugin's.
8. **Housekeeping on next login (if a logout/restart happens during
   the window):** a fresh "=== LAUNCH START ===" … "=== LAUNCH
   COMPLETE ===" block in actions.log, authored by the app.

## Soak entries

- 2026-11-14 21:10 EET — soak started (see above).
- 2026-11-14 21:11 EET — installed-copy parity PASS (146/146); daemon,
  watchdog, sentinel, plugin all re-verified healthy post-install;
  login item confirmed → /Applications path.
- 2026-11-14 21:18 EET — +8 min sample: app alive, ticks on cadence
  (`🔌 91% mode=hold`), RSS 26.7 MB, no crash reports, watchdog
  heartbeat fresh.
- 2026-11-14 21:30 EET — +20 min sample: app alive on cadence, RSS
  31.3 MB — the first-10-minutes climb (21.9 → 32.5 MB peak)
  flattened and turned down: warm-up, not a leak. No crash reports.
  First-hour proof complete; the soak is in steady state.

## Soak observation — 2026-11-14 21:35 EET (Yousef, interactive use of the NEW app)
- Yousef reported: gauge had drifted to 91%; he ran a "discharge to the percentage" from the NEW APP and "nothing was applied".
- Log truth: at 21:34:35 the app's Custom Limit dialog ran end-to-end (limit_custom → intent_apply 86/85, config written) — the FIRST proven interactive action invocation from the native app, working correctly. App source verified: Smart Discharge item maps to action smart_discharge, Custom Limit to limit_custom (MenuModel.swift:133-146) — no misrouting.
- Why nothing visibly happened: (1) Custom Limit with pct ABOVE target defers to natural drain by design — it creates NO active discharge session (discharge.log has no entry tonight; no session file). The active pull-down tool is Smart Discharge. (2) The watchdog's automatic corrective discharge was suppressed 21:19-21:34 by the APG thermal pause; APG went GREEN 21:35:31 and LAYER3a silent-hold correction fired immediately.
- The 91%: gauge re-estimation at BCLM=10 / zero current (same phenomenon as 2026-11-11 and the 19:13 drift); enforced limit stayed 86/85 throughout; no real charging occurred.
- Finding class: UX expectation gap (Custom Limit vs Smart Discharge semantics), identical in the plugin — not an app defect. Candidate polish for Stage C: none decided; record only.

## CORRECTION — 2026-11-14 ~22:15 EET (hardening package root cause)
- The 21:37 Smart Discharge session did NOT stay parked: the monitor REFUSED it at 21:43:38 (reason=no-second-signal). Gauge-drift overshoot claims on AC can never produce a second signal, so user sessions started in that state were guaranteed to die silently — a design bug, fixed same evening (WS1-A2 extended arming in hardening-fix-note.md). The earlier "parked, drains on unplug" reading is superseded.
- Also fixed: Custom Limit above target now starts a real pull-down session (WS1-A1); dispatch notifications no longer self-erase after 3 s (WS1-B).

## Evening scoreboard — 2026-11-14 (the three user sessions)
- 21:37 — user session TARGET=85 started; ARMED 21:38, parked on AC. REFUSED 21:43:38, reason=no-second-signal (pre-fix behaviour: a gauge-drift overshoot claim on AC in hold can never produce a second signal, so the session was guaranteed to die silently). Root cause + fix: see the CORRECTION section above (WS1-A2 extended arming, hardening package ~22:14).
- 22:34 — Custom Limit (86) with pct=90: config written + WS1-A1 pull-down session started (target=86) — the hardening fix working live. At 22:34:55 Yousef's Smart Discharge press CANCELLED that session (toggle semantics — a session already existed, and the item still read as a start label: the toggle trap).
- 22:35 — second press started a fresh session TARGET=85; ARMED 22:35:10, APG green, parked on AC. REFUSED 22:40:13, reason=apg, armed_ticks=6 — the APG sibling bug: APG flipped yellow at 22:36:10 (CPU load 4.18, temp 30.5 °C), `.apg_paused` appeared, and the armed-phase rule "budget counts, confirmation does not" burned all 6 ticks; extended arming never engaged (it intercepted only reason=no-second-signal).
- Scoreboard for the night: 3 user sessions started, 3 silently dead within ~6 minutes each. Final state 22:43: no session, config 86/85 untouched, daemon + watchdog healthy, gauge 90% at zero current, APG yellow from load. Yousef's "مش شغال لسه" was accurate for all three.
- (The hardening-package correction itself is recorded in the CORRECTION section above and in hardening-fix-note.md; this merge also syncs those sections to the Mac repo copy, which previously ended at the 21:30 entry.)

## 2026-11-15 evening — APG-fix deploy + LIVE PROOF PASS
- Tunnel was down from 2026-11-14 22:53 (Mac asleep) until Yousef restored it ~20:23 EET; the auto-deploy cron was removed and the deploy ran manually. Deployed (md5 + chmod +x + heartbeat verified): bc-watchdog.sh `980147e5…`, dispatch.sh `e8973652…`, pre_sleep_cleanup.sh `4279e035…`, plugin `0ef02649…`. Tests before deploy: test_discharge 29/29 (after an assertion-only fix to case I1 — the harness computed an expected timestamp with the post-tick clock; product code untouched), test_charge_persistence 51/51.
- LIVE PROOF PASS: user session TARGET=85 started through the real dispatch path under the exact conditions that killed the 22:35 session — APG yellow + `.apg_paused`, pct=99 overshoot claim, on AC. discharge.log: `20:34:18 SESSION_ARMED target=85 ... apg=yellow` + `ARMING_BLOCKED_APG`. Observed ≥8 armed ticks (12+ heartbeats): ARMED_TICKS stayed 0, APG_BLOCK=1, NO SESSION_REFUSED. Session left armed/parked. The soak itself was untouched throughout (app + plugin running; the daemon is independent of both).

## 2026-11-15 evening — Cancel-label gate failure + approved fix + render proof
- Post-deploy render check FAILED one item: the parked line rendered correctly, but the Smart Discharge item still read "★ Smart Discharge...", not "■ Cancel Discharge (to 85%)". Root cause (structural, pre-existing): the plugin's Cancel branch was gated on ACTIVE_MODE=discharge, but nothing in the architecture ever writes `.active_mode=discharge` (or `.active_token`) for a discharge session — the label code was correct but unreachable in the armed/parked state.
- Yousef approved the follow-up fix 2026-11-15 20:53 ("اعتمد إصلاح الليبل وكمّل الباقي"): the label now keys on the existence of `~/.battery-commander/.discharge_session`, N = the session file's TARGET (fallbacks: .sd_watch → configured upper). Deployed tonight: plugin md5 `5db2957e…` (repo == deployed, -rwxr-xr-x, backups `.pre-labelfix-20261115`); app sources MenuModel.swift `b564f576…` + StatusProvider.swift `b1078620…` carry the same session-file keying (repo-only — the installed app keeps the old gate until Stage C).
- Render proof (deployed plugin, live session TARGET=85 still armed/parked): 150 lines, no stderr — line 5 `Discharge to 85% — parked on AC (drains on battery)`, line 44 `■ Cancel Discharge (to 85%) | bash=… param1=smart_discharge …`. No-session fixture render (BC_DASH copy without the session file): 148 lines, no stderr — line 43 `★ Smart Discharge...`, no Cancel label. The label now toggles correctly both ways.

## 2026-11-15 evening — regression battery (final deployed code)
- PASS: test_bc_watchdog (exit 0) · test_discharge 29/29 · test_charge_persistence 51/51 · test_calibration 98/98 · sentinel 41/41 · sidecar+dispatch 15/15 · tracker equivalence PASS · bc-verify live PHASE_C=VERIFIED (exit 0) · verify-install 12/12 · project health PASS 17 / FAIL 0.
- FAILED on a documented live-baseline precondition (not a code regression): test_bc_limit_calibrate 1/15 and test_bc_limit_discharge 3/11. Both suites assume the live gauge sits at ~86–88% (≤94) so their scratch config 95/94 forces a resume decision; tonight the gauge reads 99% (re-estimation drift at zero current, BCLM=10 hold), so every case correctly decided "nothing to do" for the real reading and the expected WOULD-WRITE decisive lines never appeared. Both suites compiled bc-limit v1.3/v1.2 with zero warnings; the bc-limit binary and sources were not touched by tonight's work. The cases whose expectation matches a nothing-to-do outcome (R4; discharge cases 1, 4, 9) passed.
- Consequence (fail-stop rule): the redesign bench build (Step 2) was NOT started. It remains pending a re-run of the two bc-limit suites when the gauge sits ≤94% (or a suite-baseline review). Jobs 1–3 of tonight's sequence are complete; the proof session remains armed/parked at TARGET=85.

## 2026-11-15 evening (continued) — his clicks, the unplug non-event, full-audit fix session

### His clicks (from actions.log / discharge.log, verbatim times)
- 21:21:42 — Custom Limit intent superseded the 20:33 proof session (85→86): `SESSION_SUPERSEDED by=dispatch.limit-intent`; new session target=86 `origin=limit-intent`, ARMED 21:21:58, ARMING_BLOCKED_APG (yellow).
- 21:22:11 — Custom Limit dialog completed: `bc_apply_limit: config written 86/85 (pct=99 BCLM=10)`; pull-down session already targeted 86, left untouched. The button worked; the visible effect was nil (config already 86/85, gauge at 99).
- 21:23:25 — Smart Discharge press CANCELLED the target-86 session (toggle semantics, label now correctly shows Cancel).
- 21:23:29 — Second Smart Discharge press STARTED the session that is still armed now: MODE=user TARGET=85 STARTED=1794770609 STARTER=dispatch.
- 21:25:00–22:26:01 — APG yellow/red cycles (load 5.4–10.07 from the Min browser renderer at ~87% CPU; battery temp 30.6–30.9 °C throughout): ARMING_BLOCKED_APG / ARMING_RESUMED_APG episodes, then SESSION_ARMING_EXTENDED reason=no-second-signal at 21:35:09. The session never activated.
- ~21:35–22:35 — Yousef unplugged the charger and replugged it. NOTHING recorded it: `.discharge_state` at 22:36 showed FLIP_TIMES empty, PARKED_TOTAL_S=0, LAST_EXT=Yes; the watchdog log contains ZERO EXT=No lines in its retained window and the daemon log's last external=0 state line was 17:27:57. Neither 60 s sampler saw the unplug, and the armed phase kept no latch that could have caught it.
- 22:35 — Yousef's verdict: «فصلته ورجعته مافيش حاجه حصلت… الزر المفروض يفضل شغال» + the full-audit mandate. Product rule recorded: a user-initiated action whose effect waits invisibly, freezes behind heuristic guards, or misses real-world events is a BUG. User actions outrank load-based pauses; temperature is the legitimate hard gate.

### Why the session could never have worked tonight (audit findings, proven from code)
- The armed phase's only confirmation signal detects CHARGING evidence (IsCharging / positive amps / rising capacity). On battery the amperage normalises to −1 and capacity falls, so the signal can never exist while draining. With the overshoot claim set (pct 98–99 > UPPER+2=88), the session could activate only after the claim dissolved at pct ≤88 — ~11 points of untracked drain. CONFIRM_COUNT reached 36 with CONFIRM_SIGNAL=0 over 73+ minutes.
- EXT transitions were processed only in the ACTIVE phase; in the armed phase LAST_EXT was silently overwritten each tick — a sampled battery tick left no trace anywhere.
- The APG armed-phase budget pause (deployed 2026-11-14) froze confirmation counting entirely whenever `.apg_paused` existed — and APG was yellow/red all evening on CPU load alone at ~30.6 °C.

### Fixes deployed 2026-11-15 ~23:05 EET (full record: full-audit-fix-session-20261115.md)
- Drain-evidence confirmation for MODE=user sessions (on battery + discharge current or falling capacity/percent) — activation on the first sampled battery tick.
- Armed-phase EXT latch: SEEN_BATT persists per session; SESSION_ON_BATTERY / SESSION_BACK_ON_AC logged; bc-limit's phase-offset daemon log cross-checked as a second sampler.
- Temp gate: for user/calibrate sessions a load-only APG pause (temp <38 °C) no longer blocks arming, activation, suspension, intent resume, calibration waits/aborts, or the calibration start. Thermal pauses (≥38 °C or temp unreadable) keep full force. Corrective sessions unchanged. bc-limit and its `.apg_paused` resume suppression untouched.
- Menu honesty: display_state names a thermally blocked session ("waiting: battery hot") and a session that already saw battery power; dispatch About text corrected (Smart Discharge/Calibration shipped, not "not in v1"); dispatch's enforcer checks now query the system domain (the user-domain test could never see the daemon — the shutdown "limit still held" report was false since Phase C); sentinel integrity pairs 11 → 14 (state_guard.sh, bc-tracker-live.sh, bc-verify-run.sh added).
- Tests: test_discharge 29 → 36 cases (incl. N2, a fixture replay of tonight: unplug → SESSION_ON_BATTERY + SESSION_DRAIN_SIGNAL → ACTIVE on the first battery tick → drain → EPISODE completed); battery: discharge 36/36 · calibration 98/98 · charge 51/51 · watchdog PASS · sentinel 41/41 · sidecar 15/15 · tracker equivalence PASS · bc-verify VERIFIED exit 0 · verify-install 12/12 · health PASS 17 / FAIL 0. The two bc-limit suites remain gauge-precondition-blocked (1/15, 3/11 at gauge 98; assertions untouched).
- LIVE PROOF: the still-armed 21:23 session (TARGET=85) took its first tick under the new code at 23:05:59 — `ARMING_APG_LOAD_BYPASSED … apg=yellow temp=30.66`, ARMED_TICKS counting again (frozen at 0 all evening), APG_BLOCK=2. The session remains armed/parked; it drains on the next unplug a sampler sees. The real-world unplug proof is Yousef's next unplug.
- Redesign bench build COMPLETE (bench only, not launched/installed): zero errors/warnings; dump action coverage equal (48; the one dump delta is the state-conditional kill_discharge, rendered because a session is live); Sleep Mode subtree identical; colours: BLUE +2 (the two new group headers), GRAY +1 (Stop Discharge companion, state), GREEN +1 (live-state checklist line) — zero new colour values.

### REAL-WORLD PROOF — the unplug that worked (2026-11-15 23:17–23:56 EET)
- 23:17 — Yousef unplugged the charger (his next unplug after the fix deploy; the still-armed 21:23 session, TARGET=85, was live under the new code).
- 23:18:16 — `SESSION_ON_BATTERY source=watchdog` on the FIRST tick after the unplug — the new armed-phase EXT latch caught what the old code missed twice earlier the same evening. SEEN_BATT=1.
- 23:19:21 — `SESSION_DRAIN_SIGNAL` + `SESSION_ACTIVE` at pct=96 — the new drain-evidence confirmation fired on battery (the old charging-evidence signal could never have fired here).
- 23:33:30 — `SESSION_COMPLETE target=85` at pct=84; `EPISODE result=completed reason=target-reached start_pct=99 end_pct=84 depth_pct=15 duration_s=7801`. (Completion registered at 84: the gauge steps 1–2 points between 60 s ticks; the first tick at/below target read 84.)
- After completion Yousef kept using the Mac unplugged; natural drain continued 84→81 — post-completion consumption, not an overshoot (no tool can hold a percentage while on battery).
- ~23:5x — replugged. Daemon 23:56:05: pct=82, BCLM=100, charging=1 — charging back toward the 86 hold; APG green, no pause file.
- Verdict: END-TO-END LIVE PROOF of the discharge path under the full-fix code — press → arm → unplug latch → drain-evidence activation → drain → target completion → replug → charge back to hold. The exact scenario that failed at 21:37 and 22:35 the same evening now completes.
- Follow-on (2026-11-16 00:03 EET): the real discharge/charge cycle returned the gauge to real values (86%), clearing the ≤94 precondition — test_bc_limit_calibrate 15/15 and test_bc_limit_discharge 11/11 now PASS in full (they were 1/15 and 3/11 at the drifted 98% gauge; assertions untouched). Config md5 unchanged across the runs.

---

## 2026-11-16 ~00:26–00:49 EET — APG resume-gate fix DEPLOYED + LIVE-PROVEN (mid-soak)

Approved by Yousef 00:26 after his own 00:09 press exposed the bug: Charge to 100% wrote config 100/99, but bc-limit logged `APG paused: resume suppressed` and never wrote BCLM=100 — the pause was APG yellow/red on CPU load alone (loadavg 10.79→6.16) at temp 30.66 °C. Same class as the 2026-11-14 watchdog incident, one layer deeper (the daemon's own M6 gate, left unchanged by the 2026-11-15 full-fix for lack of evidence).

- **Fix:** the watchdog now records WHY it paused in `~/.battery-commander/.apg_pause_reason` (`thermal` ⟺ temp ≥38 °C or temp reading unavailable; else `load`; written atomically every tick while paused; removed when the pause clears). bc-limit **v1.4-apggate**: a `load` pause no longer suppresses the resume write (`APG load-pause: resume allowed (reason=load)`); `thermal`/missing/garbage still suppress (fail-safe). Discharge-session suppression branch unchanged.
- **Deploy order:** watchdog first (deployed md5 `382d2247…`; its first tick wrote reason=`load`), then daemon binary (md5 `a74e7022…`, kickstart reload; log shows `bc-limit 1.4-apggate starting`). Backups `.pre-apggate-20261116` for both. Full note: `apggate-fix-note.md`.
- **Live proof (the exact 00:09 scenario):** 00:37:44 `charge_full` → config 100/99 under APG yellow + reason=load + temp 30.62 °C → 00:38:08 daemon: `APG load-pause: resume allowed (reason=load)` + `WRITE OK: BCLM=100 verified by read-back`; ioreg IsCharging=Yes; gauge rose 86→87. Reverted via Custom Limit 86/85 (dispatch + osascript stub) → 00:42:09 `WRITE OK: BCLM=10 verified by read-back`; watchdog cleared `.charge_target`; heartbeat 00:42:55 mode=hold, IsChg=No.
- **Tests:** new test_bc_limit_apg 9/9; bc-limit matrices 15/15 + 11/11 (pinned sources AND with the v1.4 source substituted); test_bc_watchdog PASS incl. new Phase F (reason write/flip/remove, unknown-temp fail-safe); discharge 36/36; charge 51/51; calibration 98/98; sentinel 41/41; sidecar 15/15; tracker equivalence PASS; bc-verify live PHASE_C=VERIFIED exit 0; verify-install 12/12; health PASS 17 / FAIL 0; plugin↔app parity 45/46 (+open_app structural).
- **Final state 00:48:** config 86/85 (values canonical; byte md5 `07be808a…` — the watchdog's ladder reapply rewrote the file with its trailing-newline format at 00:41:54, a pre-existing two-writer formatting difference, values identical); daemon v1.4-apggate holding (BCLM=10, charging=0); APG back to green and both pause files absent (reason cleanup also proven live); `.active_mode`=hold; no sessions. Soak continues undisturbed — app, plugin, login item untouched.

## 2026-11-16 13:33–14:57 — Button/jump repair session (Yousef-approved 13:33)

- **RE finding:** the original tool's on-AC discharge is NOT an SMC write — `Center::discharge(bool)` calls the AppleSmartBatteryManager user client (IOConnectCallMethod selector 0, scalar 1/0); ACEN is its read-back (never written); BATP/CHGC are effects. Identified on the exact v1.2.7 build that ran on this Mac (symbol addresses match the 2026-11-07 RE table). Full record: `button-jump-fix-session-20261116.md`.
- **Deploys:** bc-limit v1.5-gauge 14:10 (confirm-before-write + second-signal gate; binary `28e76f4b…`, backup `bc-limit.pre-gauge-20261116`) → v1.6-ac (actuator; final binary `b97ef61f…`, backups `bc-limit.pre-ac-20261116` / `bc-limit.pre-acgate-20261116`); watchdog `ac3166df…` (marker-aware AC-flip exemption, guardian corrective sessions from LAYER2 + the ladder gate, AC_EVER parked completion, LAYER3 session guard; backups `.pre-ac-20261116` / `.pre-acfix2-20261116`); display_state `63a80dd4…` ("draining on AC (discharge mode)"); dispatch `98db478c…` (dialog text). All md5-verified in both copies, exec bits set, heartbeats live after each deploy.
- **Live proof:** minimal experiment, target 84 (14:17–14:25): ENGAGED 14:18:24 → ExternalConnected No, ≈−2.2 A, NCR=8 → DISENGAGED at target 14:21:24 → restore flip exempted (flips=0). The experiment exposed a parked-completion gap (a drained session ends parked on AC and the old counter never ran); fixed via AC_EVER, suite-verified, deployed; the experiment session itself was ended cleanly through the dispatch cancel toggle (EPISODE depth 3), charge-back `WRITE OK: BCLM=100` 14:25:24. **Full proof (14:35–14:57):** Custom Limit 80/79 via the real dispatch path → ENGAGED 14:37:26 → drained ON AC 86→80 (display: "draining on AC (discharge mode)") → DISENGAGED 14:44:26 → SESSION_COMPLETE 14:46:25 (EPISODE completed, depth 6, duration 636 s) → held at 80 (BCLM=10) → restored 86/85 via the same path → `WRITE OK: BCLM=100` 14:47:28 → `WRITE OK: BCLM=10` 14:57:29 at 86% — holding.
- **Tests (final deployed code):** bc-limit matrices on the v1.6 source 15/15 + 11/11 + apg 9/9; gauge suite green in both live states (7+1 skip charging, 6+2 skips at hold); new ac suite 12/12 (+1 opportunistic skip); discharge 36/36; watchdog suite PASS (new Phase A/A2 guardian contract); charge 51/51; calibration 98/98; sentinel 41/41; sidecar 15/15; tracker equivalence PASS; bc-verify VERIFIED exit 0; verify-install 12/12; health HEALTHY; plugin↔app parity PASS (146 canonical lines, fresh renders).
- **Final state 14:57:** config 86/85 (md5 `69c6c438…`), daemon v1.6-ac holding (pct=86, BCLM=10, charging=0), APG green, no session, no engage marker. Soak continues undisturbed — app, plugin, login item untouched.

## 2026-11-16 15:32–15:47 — bc-limit v1.6.1-ac + icon-classification fix deployed mid-soak (approved by Yousef 15:10)

- **Fix A (engagement latency):** Yousef's 15:06 Smart Discharge press took 77 s to engage (daemon 2-sighting rule). v1.6.1-ac (binary `7ec16c8d…`, backup `bc-limit.pre-aclat-20261116`): user sessions engage on the FIRST daemon tick after the watchdog monitor arms them (two-component confirmation via `.discharge_state`); unarmed user sessions never engage; corrective sessions keep 2 sightings. Live proof: press 15:35:24 → WAITING tick 15:35:42 → ARMED 15:36:15 → ENGAGED 15:36:42 (first tick after armed) → complete 15:41:22 → hold restored 15:46:46. His own 15:06 session completed on v1.6 at 15:12:54 (target 82 reached) before the deploy — undisturbed.
- **Fix B (icon classification):** during AC discharge the adapter flip (ExternalConnected=No) made the menu symbol render 🔴 (plain battery use) instead of 🔋 (discharge mode). display_state.sh (`f8ba2fed…`, state dir + repo) and the plugin (`86c718e5…`, SwiftBar + repo) now classify a draining session (engage-marker match, or monitor armed/active on battery) as 🔋/#8A9AAB; genuine battery use keeps 🔴, parked-on-AC keeps 🔌 — fixture-verified both states, and live-verified during the proof drain (title `🔋 87%`). App source fixed too (StatusProvider.swift `f1a78470…`, bench build verified) — installed app NOT rebuilt; Stage C owns that.
- **Regression on final code:** ac suite 14/0 (+1 skip), matrices on v1.6.1 (calibrate 15/15, discharge 11/11, apg 9/9), gauge 6+2 skip, discharge 36/36, watchdog PASS, charge 51/51, calibration 98/98, sentinel 41/41 (incl. post-deploy re-run), sidecar 15/15, equivalence PASS, bc-verify VERIFIED, verify-install 12/12, health HEALTHY, parity PASS 146/146 fresh renders.
- Soak impact: one daemon kickstart (15:32:42, v1.6.1-ac starting, clean hold tick); display_state + plugin files replaced in place with exec bits verified; app bundle, login item and the stray applet untouched; config 86/85 throughout.

## 2026-11-16 18:38 EET — PLUGIN PARKED (Yousef order, path 2)
- Old SwiftBar plugin retired early by Yousef: file moved ~/SwiftBar/battery-commander.10s.sh -> ~/.battery-commander/backups/battery-commander.10s.sh.parked-20261116 (49,749 B, exec bit intact). SwiftBar folder now empty; plugin icon gone.
- NOT via disabled/ (self_healing restores from there); self_healing run manually after the move — plugin NOT restored, park holds.
- Sentinel plugin integrity pair removed in BOTH copies (14 -> 13 pairs, md5 0fb09d9b both, backups .pre-park-20261116); sentinel manual run clean, no missing:plugin drift.
- Everything else untouched and verified 18:37-18:38: bc-limit ticking, pct=86 BCLM=10 hold; config 86/85 SAILING=false; watchdog heartbeat APG=green; Stage B app PID 12066 alive. Soak continues on the APP leg only; verdict should score the plugin leg as ended-by-owner-order at 18:38, not as a failure.

## 2026-11-16 21:09-21:15 EET — GAUGE JUMP 86->92 + CORRECTIVE REFUSED (protection working)
- Gauge jumped to 92% in hold (BCLM=10, amp=0, cap=4578 mAh = normal 86% band). LAYER2 armed a corrective session 21:09:25 (92 > UPPER+2=88); APG went yellow on LOAD (T=30.54, L=5.12); arming blocked; SESSION_REFUSED no-second-signal 21:14:43 after 6 armed ticks -> user notification (the screenshot Yousef sent 21:15).
- Verdict for the soak record: CORRECT behaviour — no energy ever flowed in (amp=0 throughout); the second-signal gate refused to discharge a phantom overshoot. Daemon kept holding (21:15:18 tick: pct=92 BCLM=10, nothing to do).
- Two findings logged for the test catalog: (1) the refusal notification wording does not distinguish an automatic corrective refusal from a user-action failure; (2) watchdog LAYER2 still logs load-pause as thermal pause and corrective arming still burns its window under load-only APG (user sessions were fixed 2026-11-14/15; corrective was not).

## SOAK COMPLETION — evaluation 2026-11-16 21:52 EET (verdict: PASS WITH NOTES)

**Verdict: PASS WITH NOTES — the native app was stable for the full 48 h; Stage C cutover is supported.**

Live evidence at evaluation (all read while the tunnel was up, 21:52–21:57 EET; tunnel dropped ~22:00 with HTTP 502 then 530 — two end-of-run confirmations, parked-plugin md5 and Mac-copy md5 sync, could not be re-run; both were already established earlier in the day — see notes):

- **App process:** PID 12066, started Sat Nov 14 21:10:27 — the same PID as soak start, no restart in 48 h. RSS 28,632 KB (~28 MB; hour-one warm-up peaked 32.5 MB then flattened — no leak), CPU 0.3% between ticks. Console log: status ticks at ~10 s cadence, header `🔌 93% mode=hold` at 21:55–21:56 (93% = gauge drift, see below).
- **Crash reports:** none for the BatteryCommander bundle in `~/Library/Logs/DiagnosticReports` across the window. (SwiftBar crashed once 16:26:28 — its own libswiftCore String-trim SIGSEGV, not the app; watchdog relaunched it 16:27:44–48, ~77 s; the app kept ticking through it. Mac Mouse Fix Helper also crashed 13:57 — unrelated.)
- **Daemon:** bc-limit v1.6.1-ac ticking, config 86/85 untouched, BCLM=10, charging=0, hold. Gauge 92–93% at zero current is the known re-estimation drift, judged by the verification system's amended rule — not an app failure (capacity 4578 mAh = 86%).
- **Watchdog:** heartbeat fresh (21:53:35, mode=hold, APG=yellow load-only, temp 30.6 °C). **Sentinel:** no staleness alert all window (ALERTED=0); one integrity incident 15:22–15:34 during the icon-fix deploy (drift: display_state.sh, plugin), single notification, cleared 15:34 — expected during a deploy.
- **Verification:** morning runs Nov 15 09:52 and Nov 16 09:12 — both FULL confidence, 0 fails 24h/7d, PHASE_C=VERIFIED (latest 15:22 run same). Today's episodes all PASS: discharge 15:53 (target 82 reached), cycle, charge. Menu "Verified:" line truthful.
- **Interactive use (Yousef's eyes):** clicks worked all window — Custom Limit dialogs completed (Nov 14 21:34 first proven app action; Nov 15 21:21/21:22), Smart Discharge presses armed/started sessions, label fix live-verified (Cancel label toggles both ways). Every mid-window fix (APG gate v1.4, AC discharge v1.6, latency v1.6.1, icon classification) was deployed and live-proven inside the window — cited as soak evidence, not failures.
- **Plugin leg:** ended 18:38 by Yousef's order (parked, see above) — soak finished app-only for the last ~2.5 h. SwiftBar folder empty is expected, not an anomaly.
- **Stray applet:** PID 21524 still inert (started Nov 13 19:33:53, 0.0% CPU, ~5.2 MB) — Stage C closes it by design; untouched.
- **Deferred, NOT in the verdict (Yousef's call):** the two parked issues — slow response; last values he writes are not saved — wait for a concrete case from his natural testing.
- **Stage C note:** the 16:35 dry-run review found one real FR-007 v1.7 defect — quitting while a discharge session is engaged would leave the charger path closed (release branch returns before discharge cleanup). The fix (release branch clears discharge mode first and logs it) is written in the Stage C package and must be part of the v1.7 build and its tests. FR-007 is NOT presented as already complete. Quit test protocol: ≥3 full quit/relaunch cycles (hold / charging / discharge-engaged); sleep-entry policy Option C adopted (status quo, no hook).
- **Mac-copy sync pending:** this completion section is in the local copy; the Mac repo copy (`battopt-project/bc-build/app-soak-log.md`) could not be synced at evaluation time — tunnel down (HTTP 530) after 22:00 EET. Sync on next tunnel-up run; local md5 at write time recorded in the 2026-11-16 memory log.

## STAGE C — COMPLETE (2026-11-16 23:43 → 2026-11-17 00:05 EET)

- Approved by Yousef 22:29 (after the PASS-WITH-NOTES verdict above). Daemon v1.7-stagec was already live from the build phase; this window covered the bundle swap + the FR-007 proof.
- **Swap:** Stage B bundle parked to /tmp; Stage C build installed at /Applications/BatteryCommander.app (exe `2974efa3…`, diff -r vs bench CLEAN, codesign rc=0). First launch 23:43:43, LAUNCH COMPLETE in 5 s, housekeeping clean, no flag left behind.
- **FR-007 cycles — ALL PASS:** (i) quit at hold → 23:46:04 RELEASE OK BCLM=100 read-back, stock charging observed, relaunch re-applied hold ≤1 tick; (ii) quit while charging to 100/99 → 23:51:05 "limit already released (BCLM=100)", charging continued as stock, relaunch resumed ≤1 tick, config restored 86/85 via Custom Limit (canonical md5); (iii) quit while discharge mode engaged (ENGAGED 23:59:07, ExternalConnected=No) → 00:00:07 `DISCHARGE MODE DISENGAGED: FR-007 tool-closed release` + RELEASE OK, ExternalConnected restored — the v1.7 gap fix proven live (bench case C9 closed).
- **Close-out:** sentinel clean (13 pairs), bc-verify PHASE_C=VERIFIED (FULL), verify-install 12/12, health PASS 17 / FAIL 0 — HEALTHY. Config 86/85 canonical throughout (except the intentional 100/99 window in cycle ii).
- **One annotated FAIL episode:** hold-1794837951 scored FAIL (`bclm-left-10`) — the trigger window 23:46–23:49 is cycle i's deliberate release; the episode's own record shows charging_ticks=0 + 1 gauge event (the 21:09 drift). Not an enforcement failure; see stage-c-completion-note.md.
- **Observation:** config rewrites by the tool's own actors (watchdog ladder reapply; app launch reapply) supersede live discharge sessions — seen twice tonight; pre-existing monitor rule, not a Stage C regression.
- Full evidence: `stage-c-completion-note.md`.
