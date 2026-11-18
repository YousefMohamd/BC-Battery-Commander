# Full-Tool Audit + Fix Session — 2026-11-15 night

**Mandate (Yousef, 2026-11-15 22:35 EET):** «فصلته ورجعته مافيش حاجه حصلت وده اصلا مش مفروض يحصل السلوك العادي الزر المفروض يفضل شغال افحص الاداه كلها جلسه كامله بتحل فيها البجز والثغرات وبعدين نكمل المشروع» — examine the whole tool in one complete session, fix the bugs and gaps, then continue the project.

**Product rule (his words, treated as spec):** «السلوك العادي الزر المفروض يفضل شغال» — the normal behaviour is that the button keeps working when pressed. A user-initiated action whose effect waits invisibly, freezes behind heuristic guards, or misses real-world events (a short unplug between 60 s ticks) is a BUG, not an explanation. User-initiated actions outrank load-based heuristic pauses. Temperature is the legitimate hard safety gate; CPU load by itself is not a thermal emergency.

**Trigger evidence:** a MODE=user discharge session (TARGET=85, started 21:23:29 by Yousef's own Smart Discharge press) sat in PHASE=armed for over an hour. Yousef unplugged and replugged (~21:35–22:35) and nothing happened or was recorded. APG was yellow/red all evening on CPU load alone (Min renderer ~87% CPU, loadavg 5.4–10.07) at battery temp 30.6–30.9 °C. Gauge 99→98% (zero current, BCLM=10 hold, config 86/85 untouched).

---

## The unplug diagnosis (exact mechanisms)

Three independent defects combined; each alone was sufficient to make the button look dead:

1. **The confirmation signal points the wrong way (F1).** The armed phase's only second signal (`_disch_second_signal`) detects *charging* evidence: IsCharging=Yes, positive amperage, or rising capacity. On battery, `read_snapshot` normalises the wrapped negative amperage to −1 and capacity *falls*, so the signal can never exist while the battery is draining. The session carried an overshoot claim (pct 98–99 > UPPER+2=88), and a claimed session activates only with that signal — or after the claim dissolves at pct ≤88, i.e. after ~11 points of untracked drain. Proof: `.discharge_state` at 22:36 — CONFIRM_COUNT=36, CONFIRM_SIGNAL=0, OVERSHOOT_CLAIM=1, 73+ minutes. (The 2026-11-13 T3 session activated only because its pct 85 never set the claim.)
2. **No EXT observation exists in the armed phase (F2).** AC→battery flip accounting lives only in the active phase. In the armed phase `_disch_tick_update` silently overwrote LAST_EXT every tick: a sampled battery tick left no trace in any log or state field. Proof: FLIP_TIMES empty, PARKED_TOTAL_S=0, LAST_EXT=Yes at 22:36; zero `EXT=No` lines in the watchdog log's whole retained window.
3. **The APG budget pause froze observation-coupled progression (F3).** The 2026-11-14 armed-phase fix paused the refusal budget while `.apg_paused` exists — but the same branch also skipped confirmation counting and signal evaluation. With APG yellow/red all evening on load alone, the session was frozen behind a heuristic guard the user never asked for.

And the sampling fact underneath all three (F4): two 60 s pollers (watchdog, daemon) both missed the unplug — the daemon log's last `external=0` state line was 17:27:57. Polling cannot see a sub-interval unplug; the fix therefore *latches* observations from both samplers instead of pretending otherwise.

---

## Findings table

| # | Severity | Finding (evidence) | Fix | Test |
|---|---|---|---|---|
| F1 | CRITICAL | Armed user session with an overshoot claim can never activate on battery — the only confirmation signal detects charging evidence (bc-watchdog.sh `_disch_second_signal`; live state CONFIRM_SIGNAL=0 for 73+ min) | New `_disch_drain_evidence` (EXT=No + discharge current (AMP=−1) or falling capacity/percent) sets the confirmation signal for MODE=user sessions; activation fires on the first sampled battery tick | N2 (unplug → SESSION_DRAIN_SIGNAL → ACTIVE first battery tick → drain → completed) |
| F2 | CRITICAL | No EXT latch in the armed phase; transitions unrecorded (FLIP_TIMES empty, PARKED_TOTAL_S=0 after a real unplug) | Armed-phase latch block before gauge/APG branches: persisted SEEN_BATT/BATT_SINCE, SESSION_ON_BATTERY / SESSION_BACK_ON_AC logs, plus `_disch_daemon_seen_batt` cross-latch from bc-limit's phase-offset state lines (external=0 at/after session start) | N3 (one-tick unplug latched), N4 (daemon-log-only unplug latched) |
| F3 | HIGH | Load-only APG pauses froze user-initiated work everywhere temp was normal: armed budget+confirmation, active suspend + 15-min abort, intent-resume gate, calibration charge-leg abort clock, calibration L0/L2 waits, calibration start refusal in dispatch | Temp gate (`_disch_apg_thermal` / `_cal_apg_thermal`, threshold = APG's own 38 °C yellow temp; unreadable temp = thermal, fail-safe): for MODE=user and MODE=calibrate, a pause with temp <38 °C is bypassed (armed: DS_APG_BLOCK=2 + ARMING_APG_LOAD_BYPASSED once per episode; active: no suspend/abort; intent: no block; calibration: no abort clock, no waits; dispatch: start allowed + logged). Thermal pauses keep full force everywhere. MODE=corrective unchanged in both phases. `.apg_paused` semantics for bc-limit's resume suppression UNCHANGED (audit found no evidence to change it; bc-limit untouched) | N1 (tonight's replay: load 9, temp 30, pct 99 → bypass, counting, extended arming, never refused), N5 (active drain under load pause), N6 (temp exactly 38 still blocks), I9 (intent resume under load pause); R4/R4b/R4c/R4e/R4f/I2 reworked to thermal setups with all original assertions preserved; calibration A5 reworked to thermal (pack_temp 43) |
| F4 | MEDIUM | Two offset 60 s pollers both missed the real unplug; no record existed anywhere | F2's latch + daemon-log cross-latch (doubles phase coverage). Residual honesty: an unplug shorter than ~30 s that no sampler lands on remains undetectable by polling — stated, not hidden | N3, N4 |
| F5 | MEDIUM | display_state rendered an armed, APG-blocked, never-activated session identically to a healthy parked one ("parked on AC (drains on battery)") | Reads `.discharge_state` (PHASE/APG_BLOCK/SEEN_BATT) + session MODE: thermally blocked → "… (waiting: battery hot)" (AC and battery variants); armed + SEEN_BATT → "… (was on battery; unplug to drain)"; other lines byte-identical | Live render proof post-deploy (below); WS1-C fixture lineage |
| F6 | LOW | dispatch `about` dialog: "Smart Discharge / Calibration: Arrive in later phases — not in v1" — false since 2026-11-13/14 | Text corrected to describe both shipped features | Visual (source) |
| F7 | MEDIUM | dispatch `shutdown` + `_bc_ready` tested the enforcer with `launchctl list` in the USER domain — a system-domain LaunchDaemon never matches (same bug class fixed in the plugin 2026-11-14). A shutdown would report the release as "pending-phase-c / limit still held at 86%" — false since Phase C (2026-11-13); nothing enforces 86/85 if the daemon is down | New `_daemon_loaded()` (`launchctl print system/com.batterycommander.bclimit`, the watchdog's pattern) used by both; honest wording ("release saved in config; enforcer not loaded"). Shutdown NOT redesigned (FR-007 Quit semantics belong to Stage C) and NOT tested live | Source + suite regressions green |
| F8 | LOW | Sentinel integrity pairs (11) omitted three files whose silent death is a proven failure class: bc-tracker-live.sh (watchdog invokes it behind an `-x` guard — exec-bit loss freezes verification silently), bc-verify-run.sh, state_guard.sh (sourced by dispatch + watchdog) | 3 pairs added (14 total) + test_sentinel fixture extended with the files | Sentinel suite 41/41 |
| F9 | INFO | bc-limit daemon: no defect found (ticks correct all evening; external=0 logged correctly during the day; session/calibrate/APG contract re-verified by grep) | Binary and sources untouched, per the mandate's gate | Live hold verified post-deploy (daemon ticking, BCLM=10, pct=98) |
| F10 | INFO | Watchdog LAYER2 never actually creates MODE=corrective sessions in v1 (hold-and-wait by design); monitor corrective paths are vestigial | Not changed (designed behaviour; conservative paths kept byte-identical per mandate) | R2-corrective, R4d unchanged and passing |
| F11 | LOW | Calibration `_cal_wait` for the L0-APG and L2-issue waits passed AWAIT="" — the menu could not say why a run waited | AWAIT="apg" at both waits (now thermal-gated) + display_state line "Calibration: waiting — battery too hot" (checkpoint WAITING=1 branch keeps precedence) | Calibration suite 98/98 |
| F12 | INFO | Calibration abort notifications said "hot or loaded" while the abort is now thermal-only | Texts corrected to "battery stayed too hot" (L1 + L4) | A5 assertion (RUN_ABORT reason=apg leg=L4) preserved |

**Audited CLEAN (no change):** apg_classify + hysteresis (working as designed; it also gates corrective initiation and bc-limit resume suppression — both kept conservative); pre_sleep_cleanup intent-save (user-only, ORIGINAL_STARTED chaining, +12 h expiry); state_guard (mkdir lock with dead-owner steal, read_effective_session); cleanup_logs rotation (incl. verdicts.jsonl + the calibration supervisor's whole-file fallback); verification chain (tracker driver locking/dedup, honest DATA_INCOMPLETE markers, exit-0 discipline); sentinel core (observed-staleness discipline, sleep-safe); project_health; plugin (Cancel label + Stop Discharge submenu correct post-labelfix; the legacy `.sd_watch` completion notifier is dead-but-harmless — nothing writes it); dispatch sleep-mode actions (Sleep Mode subtree FROZEN per the redesign order; pmset out of scope); calibration supervisor core (legs, two-signal endpoints, checkpoint funnel). App sources needed no Swift change for the monitor fixes (the app executes the same display_state.sh; the label session-keying was already in MenuModel/StatusProvider).

---

## What was deployed (2026-11-15 ~23:05 EET)

Backups `.pre-fullfix-20261115` for every changed file: repo in-place + `~/.battery-commander/backups/` (never inside ~/SwiftBar/).

| File | Repo path | Deployed md5 |
|---|---|---|
| bc-watchdog.sh | src/daemon-helpers/ | `cfc52ba149e1cf213f1d2efc80ec8c97` |
| dispatch.sh | src/daemon-helpers/ | `4f87201a9cbc80d37b2ff509c56fbaaa` |
| display_state.sh | src/plugin/ | `408db43bada1549c8580d6bb8b7ac5da` |
| bc-watchdog-sentinel.sh | battopt-project/bc-build/ | `2698d4c53726bdad368bc7d611db8ade` |
| test_discharge.sh (repo only) | battopt-project/bc-build/ | `c9d87a893c9ad05b9aefae10a973556f` |
| test_calibration.sh (repo only) | battopt-project/bc-build/ | `0b6adcb89dbd27f665991bf4c37fdadb` |
| test_sentinel.sh (repo only) | battopt-project/bc-build/verify-deploy-test/ | `6696d62c3c3d45f0d3760189dbdc7388` |

Deployed copies: md5 == repo, `chmod +x` verified, watchdog heartbeat + plugin render verified post-deploy. bc-limit binary untouched. /Applications app untouched. Plugin file untouched (display_state carries the display fixes; the plugin renders it verbatim). Config untouched: md5 `69c6c438…` (86/85, SAILING=false).

## Regression battery (final code)

| Suite | Result |
|---|---|
| test_discharge | **36/36 PASS** (was 29 cases; +N1–N6, +I9; R4/R4b/R4c/R4e/R4f/I2 reworked to thermal setups, assertions preserved; R4d corrective byte-identical) |
| test_calibration | **98/98 PASS** (A5 reworked to thermal) |
| test_charge_persistence | **51/51 PASS** |
| test_bc_watchdog | **PASS** (exit 0) |
| Sentinel suite | **41/41 PASS** (14 integrity pairs incl. fixture update) |
| Sidecar + dispatch suite | **15/15 PASS** |
| Tracker equivalence | **PASS** |
| bc-verify live | **PHASE_C=VERIFIED, exit 0**, confidence FULL, fails 0/0 |
| verify-install | **12/12 PASS** |
| Project health | **PASS 17 · FAIL 0** · WARN 2 (known) |
| test_bc_limit_calibrate | **1/15 — GAUGE PRECONDITION** (see below) |
| test_bc_limit_discharge | **3/11 — GAUGE PRECONDITION** (see below) |

The two bc-limit suites document a live-baseline assumption (gauge ~86–88%, i.e. ≤94) so their scratch config 95/94 forces a resume decision whose WOULD-WRITE line is each case's decisive signal. Tonight the live gauge read 98%, so every dry-run case correctly decided `nothing to do (pct=98%, BCLM=10 already correct)` and the decisive lines never appeared. Both suites passed in full (15/15, 11/11) on 2026-11-14 with the gauge ≤90. Assertions were NOT weakened; the suites re-run green when the gauge settles ≤94% (the armed auto-check cron `bc-gauge-rerun-job4-2026-11-15` owns that trigger; its Job-4 half is now complete — see the bench build below).

## Live proof (2026-11-15 ~23:05–23:10 EET)

- The session Yousef started at 21:23:29 (MODE=user, TARGET=85) continued under the new watchdog code with full state-file compatibility (new keys default cleanly). First new-code tick 23:05:59: `ARMING_APG_LOAD_BYPASSED session=1794770609 pct=98 bclm=10 ext=Yes chg=No amp=0 cap=5010 ncr=4 apg=yellow temp=30.66` — APG_BLOCK 1→2, **ARMED_TICKS counting again (1; frozen at 0 all evening)**, CONFIRM_COUNT preserved (37).
- Plugin render: `Discharge to 85% — parked on AC (drains on battery)` + `■ Cancel Discharge (to 85%)` — the parked wording is now truthful: the activation path is fixed and the session is progressing under the bypass.
- Fixture proof of activation-on-battery under a load-blocked APG: test case N2 (PASS) — the exact mandate scenario.
- The session was LEFT ARMED (per mandate). It drains on the next unplug a sampler lands on; the 240-min max-age bound from its 21:23 start applies as designed.
- **The real-world unplug proof remains Yousef's next unplug** — no fixture substitutes for it, and this note does not claim it.

## Redesign bench build (Phase 3 — complete, bench only)

- Sources: repo `src/app` copied byte-exact to `battopt-project/bc-build/app-redesign-src/` (+ local mirror `~/workspace/bc-build/app-redesign/src/`); MenuModel.swift carries the label session-keying (`b564f576…` pre-restructure). The 3 pending docs uploaded (button-inventory.md, palette.md → snapshot/; menu-design.md → app-redesign-src/).
- Restructure implemented in the copied MenuModel.swift only, per menu-design.md: primary charge cluster first (Force Reset → Services & Maintenance; Reset to Defaults → Charge Limits); "Quick Actions" → "Power & Sleep" (+ Sleep Report and Auto Cleanup moved up); new "Reports & Verification" group; new "Services & Maintenance" group; About moved next to Quit. Build script icon fallback path adjusted (`../../assets` → `../../../assets`) in the bench copy.
- Build: `app-redesign-src/build/BatteryCommander.app` — **zero errors, zero warnings**, bundle verified, ad-hoc signed. **NOT launched, NOT installed** (Stage C, after the soak verdict + his approval).
- Proofs: dump 153 lines vs snapshot 148 (+2 headers, +1 discharge status line and +1 Stop Discharge companion — both state-driven, +1 group separator); **action coverage equal both directions** (source literal sets identical, 48 actions; dump sets differ only by `[action:kill_discharge]`, which renders only while a session is active — tonight one is, at snapshot time none was); Smart Discharge in the new dump shows the design's active-state label `■ Cancel Discharge (to 85%)` in ORANGE with the GRAY companion beneath, same position in the primary cluster; **Sleep Mode subtree identical** (volatile numbers normalised); colour distribution: #007AFF 9→11 (+2 = the two new headers), #909090 57→58 (+1 = Stop Discharge companion, state), #30D158 6→7 (+1 = a live-state ✅ line inside the unchanged Sleep Report submenu) — **zero new colour values**.

## Final live state (2026-11-15 ~23:1x EET)

- Config: 86/85, SAILING=false, md5 `69c6c438…` — untouched all session.
- bc-limit daemon: ticking (state lines current), pct=98% BCLM=10 charging=0 external=1. Binary untouched.
- Watchdog: ticking on the new code; heartbeat fresh; APG yellow (load), `.apg_paused` present, battery temp ~30.7 °C.
- Session: MODE=user TARGET=85 ARMED under the load bypass (APG_BLOCK=2, ARMED_TICKS counting, SEEN_BATT=0 — on AC all evening since 21:23).
- Sentinel: new code live; all 14 integrity pairs verified clean by direct md5 (incl. the 3 new pairs).
- Stray applet PID 21524: untouched. /Applications app + login item: untouched. No commit.

## What still needs Yousef

1. **The real-world unplug proof** — the next time he unplugs with the session armed (or starts Smart Discharge and unplugs), the session should activate on the first sampled tick and drain to 85. If anything else happens, the discharge.log now records exactly what the monitor saw (SESSION_ON_BATTERY / SESSION_DRAIN_SIGNAL lines).
2. **Soak verdict + Stage C approval** — the soak ends Mon 2026-11-16 21:10 EET; the evaluation is scheduled ~21:52. Stage C installs the redesigned bench build above, retires the plugin, and implements FR-007 Quit.
3. **A calibration day** — still his to name (checklist in calibrate-build-note.md; no restart, nothing closes).
4. **Commit approval** — 150+ changed files remain uncommitted; then DMG; GitHub connection (his) + publish LAST.
5. Nothing else is blocked on him: the two bc-limit suites re-run automatically when the gauge settles ≤94% (armed cron), and their assertions stand as written.
