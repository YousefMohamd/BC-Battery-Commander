# Battery Commander — Fix + Hardening Package (2026-11-14, 21:40–22:15 EET)

Ordered by Yousef 2026-11-14 21:38: fix the Custom Limit / Smart
Discharge "nothing happened" problem, check EVERYTHING, hunt bugs,
close the gaps, add strong protection. Deployed live the same
evening. Backups: every replaced file kept as
`<file>.pre-hardening-20261114` (state-dir `backups/` for deployed
scripts, repo `bc-build/` + `verify-deploy-test/` + `tests/` for
repo files). No Stage C work, no app reinstall, no commit/push, no
calibration run, no SMC writes beyond normal enforcement, no pmset
changes.

## The 21:37 incident, root-caused (why "nothing happened")

Yousef's Smart Discharge (started 21:37:39, TARGET=85, parked on AC)
was REFUSED by the watchdog monitor at 21:43:38
(`EPISODE … result=refused reason=no-second-signal`). His battery
had gauge-drifted to 90% at zero current — an "overshoot claim"
(PCT > UPPER+2) — and discharge-design rule 2 requires a second
signal (IsCharging / Amperage>0 / capacity rising) before activation.
**On AC in hold, no second signal can ever exist**, so every user
session started in that state was guaranteed to silently die after
~6 minutes. His Custom Limit at 21:34 hit the companion defect: the
limit branch wrote the config and deferred to "natural drain" — no
session at all. Both are fixed below; the fixes were designed to
NOT weaken rule 2 (see WS1-A2).

## WS1 — behaviour fixes

### WS1-A1. Custom Limit now ACTS (dispatch.sh)
New helper `sd_pull_down_for_limit <UPPER>`, called from
intent_apply's `limit` branch (the Custom Limit / preset path —
verified: it is the only path that can land above target;
hold_current has U=CUR, disable_limit/charge_full have U=100) and
from `clear_hold` (returning to a configured limit below the current
charge). When pct > new upper it starts a REAL user discharge
session with TARGET=upper through the same machinery Smart
Discharge uses: same file/format, same atomic write, STARTER=dispatch,
written AFTER the config write under the same lock (so the monitor
arms it against the new config signature — the charge_full ordering
lesson). Rules: an existing session targeting the same upper is
left untouched; a session with another target is superseded with a
`SESSION_SUPERSEDED by=dispatch.limit-intent` discharge.log line
(the monitor's own vocabulary); the AC-flip cooldown is respected
exactly as Smart Discharge respects it; a calibration session is
never touched; upper <20 (session range floor) starts nothing and
says so. Feedback is unmissable and specific (`_pd_notify`):
"… — discharging to 80% (parked on AC; unplug to drain)" /
"… — discharging to 80%" (battery) / cooldown, range, calibrate and
already-running variants, plus actions.log + discharge.log lines
(`SESSION_START_REQUESTED … origin=limit-intent`).

Tests: test_charge_persistence C7–C13 (above-target AC/battery,
below-target, at-target, supersede, cooldown, range-16) — suite now
**39 passed, 0 failed** (was 20 checks).

### WS1-A2. Extended arming (bc-watchdog.sh monitor)
A MODE=user session whose overshoot claim has no second signal is
no longer deleted at the armed-budget expiry. Rule 2 stands — it
can NEVER reach ACTIVE on a % reading alone — but it stays ARMED
(`SESSION_ARMING_EXTENDED`, logged once): it activates the moment a
second signal appears, or when the reading settles back inside the
+2 band (`OVERSHOOT_CLAIM_CLEARED` → normal confirmation). The
existing 240-min max-age abort still bounds it. MODE=corrective
sessions (the watchdog's own inference) keep the hard refusal,
byte-identical behaviour.

Tests: R2 split into R2-user-extended (signal arrives → ACTIVE),
R2-user-settle (reading settles → claim dissolves → ACTIVE),
R2-corrective-refusal (old expectation, unchanged). Suite **18/18**.

### WS1-B. Notification delivery
Root divergence found: dispatch's `notify()` was the ONLY notify
implementation that passed `-timeout 3` to terminal-notifier —
menu-action feedback self-dismissed in 3 s (the watchdog's
`notify_ratelimited` never passes it), which is why actions felt
silent. Fixes at the dispatch layer (no app change needed — the app
invokes dispatch via Process with an inherited login-session env,
and the dialogs provably worked from the app twice that evening;
all external commands resolve in the minimal GUI PATH):
- dispatch `notify()`: `-timeout 3` removed (both branches);
  fallback osascript made absolute (`/usr/bin/osascript`);
  `BC_NOTIFIER` env override added (same testability pattern as
  BC_PMSET) so the stub harness records deliveries verbatim.
- sentinel `notify()`: `-timeout 3` removed likewise.
Proof: the charge suite's recorder stub captured the C7/C11/C12/C13
notifications verbatim under a harness env; the sentinel's live
22:07 desktop notification (below) proves LaunchAgent-context
delivery end-to-end.

### WS1-C. Parked-session visibility
Plumbing was intact; the empty status at recon time was because the
session had just been refused (21:43). End-to-end sandbox fixture
proof (parked user session, real ioreg ExternalConnected=Yes):
- display_state.sh → `DISCHARGE_STATUS=Discharge to 85% — parked on AC (drains on battery)`
- plugin render → `Discharge to 85% — parked on AC (drains on battery) | size=11 color=#FF9500`
- bench app --dump-menu → `Discharge to 85% — parked on AC (drains on battery) [color=#FF9500]`
With WS1-A2, parked sessions now persist, so the line persists too.

## WS2 — audit + hardening findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Sentinel watched only the watchdog; a dead bc-limit alerted NOBODY | High | **FIXED** — sentinel now watches bc-limit-daemon.log mtime with the same discipline (stale >240 s + 300 s sentinel-observed, once per incident, wake-gap reset). Tests D1–D7 incl. the sleep-gap case |
| 2 | No integrity check on deployed scripts (the 2026-11-14 watchdog death: lost exec bit, unseen 15 h) | High | **FIXED** — sentinel integrity guard: 11 deployed↔repo pairs (existence, exec bit for scripts, md5). 300 s observation window makes it deploy-proof. Tests I1–I6. **Proven LIVE the same evening**: it caught a wrong repo path in its own pair list (display_state.sh lives in src/plugin/, not src/daemon-helpers/), notified once at 22:07, and logged "integrity restored — incident cleared" at 22:13 after the pair was corrected |
| 3 | project_health FAILed on womp=1 — Yousef's own deliberate toggle (enabled 2026-11-13); FAIL had stopped meaning failure | Medium | **FIXED** — womp is preference-aware (0 or 1 PASS with the value shown; unreadable/out-of-range FAIL). Also added the missing `watchdogsentinel` to the health check's agent loop. Health now **PASS 17 · FAIL 0** |
| 4 | tests/dispatch_helpers.bats fixture pointed at the retired ~/.battopt-swiftbar | Low | **FIXED** (text → ~/.battery-commander). bats itself is not installed on the Mac (pre-existing) — the suite cannot execute until it is |
| 5 | .charge_target race-class scan (two state files a 60 s tick can interleave) | — | **CLEAN** — config, session file, .discharge_state, sentinel state, .sleep_episode (tmp+mv), tracker state (tmp+rename) are all single atomic writes; the only multi-file protocol was charge_full's, fixed in the charge build. No other instance exists |
| 6 | Log-rotation coverage | Low | **FIXED** — cleanup_logs.sh now rotates `.watchdog_sentinel.log` + `verdicts.jsonl` (both were produced but never rotated; episodes.jsonl self-rotates at 100 KB by design) and sweeps orphaned `*.tmp.*` state-dir files >24 h (one real orphan found: bc-limit-daemon.log.tmp.75302) |
| 7 | Locks + staleness audit | — | **SOUND, no change** — dispatch lock: dead-PID removal + cmdline check against PID reuse + 600 s staleness; tracker lock steals >180 s; session staleness bounded in both bc-limit and the monitor; the .apg_paused freeze mode is now covered by sentinel liveness (finding 1) |
| 8a | **Gauge wedge (found by the hunt)**: the monitor's gauge deferral freezes LAST_PCT on gauge ticks, so a rock-stable reading after a ≥5-point jump wedges EVERY % decision for the rest of a session (delta vs the frozen baseline never falls below 5). A bq20z451 can hold one value for hours at zero current — exactly tonight's battery | Medium | **FIXED** — `GAUGE_ACCEPT`: a jumped reading that repeats exactly on the next tick is accepted as the settled level (the deferral's own documented contract: "defer one tick; the next tick counts"). New DS_GAUGE_PCT state field. Proven by R2-user-settle; R3-gauge semantics unchanged |
| 8b | verify-install false-FAIL: its app-bundle check still expected the pre-Stage-B applet+launcher layout, so it FAILed the correct native install | Low | **FIXED** — check accepts the native layout strictly (Mach-O executable + bundle id com.batterycommander.launcher); legacy layout still accepted. Now **12/12 ALL CHECKS PASSED** |
| 8c | All 17 LaunchAgent/Daemon program paths verified executable; state-dir hygiene reviewed | — | **CLEAN** |
| 8d | Observation, no action: menu header % (91, from bc-status) vs daemon tick % (90) can differ by a point for a few seconds during gauge re-estimation — two readers of the same source, seconds apart; enforcement uses the daemon's reading | Info | Noted only |

Deferred: nothing from the seeds. App-binary changes: NONE were
needed — WS1-B was fixed entirely at the dispatch layer, so nothing
is pending Stage C from this package.

## Final regression battery (on final deployed code)

| Suite | Result |
|---|---|
| test_bc_watchdog.sh | PASS (exit 0) |
| test_discharge.sh | **18/18 cases PASS** (16 original − R2 replaced by 3) |
| test_charge_persistence.sh | **39 passed, 0 failed** (20 + 19 new WS1-A checks) |
| test_calibration.sh | PASS (exit 0) |
| test_bc_limit_calibrate.sh | PASS (exit 0, 15/15) |
| test_bc_limit_discharge.sh | PASS (exit 0, 11/11 matrix) |
| test_sentinel.sh | **41 passed, 0 failed** (legacy + daemon D1–D7 + integrity I1–I6) |
| test_sidecar_dispatch.sh | 15 passed, 0 failed |
| test_tracker_live_equiv.py | PASS (0 failures); bc-verify reports VERIFIED |
| verify-install.sh | **12/12 ALL CHECKS PASSED** |
| project_health.sh | **PASS 17 · FAIL 0 · WARN 2** (load, swap — transient) — HEALTHY |
| Plugin render vs bench app --dump-menu | 148 lines both; identical content modulo the 3 documented Stage A deviations + render-time volatility (CPU %, "seconds ago") |
| Live state at close (22:13) | config 86/85, md5 `69c6c438…` unchanged all evening; daemon ticking (pct=90, BCLM=10, hold); watchdog heartbeat fresh; sentinel healthy, integrity incident cleared, no alerts outstanding; no discharge session (the 21:37 session ended under the OLD refusal at 21:43, before this deploy — a re-issued Smart Discharge / Custom Limit now behaves per WS1-A) |

## Deploy md5s (repo == deployed == built)

- dispatch.sh `d3c4fa405eb7361e0e8692e2128adeff`
- bc-watchdog.sh `4a35256bd289ba482c07568a002e39a0`
- bc-watchdog-sentinel.sh `e66008c328a254d63f2beddb4d44f8d4`
- project_health.sh `2e6599a9a7605dae65a4a05ce688a989`
- cleanup_logs.sh `7a9c1811bb58353e604f418331007804`
- src/verify-install.sh (repo only) `66102d52155a1655b51ebafca6f8e174`
- test files: test_charge_persistence.sh `dcad23f4…`, test_discharge.sh `007b4fd8…`, test_sentinel.sh `29a1f039…`, tests/dispatch_helpers.bats `46aff274…`

## Remaining risks

1. Extended arming trades a silent refusal for a bounded wait: a
   user session started on a genuinely false gauge reading can sit
   ARMED up to the 240-min max-age abort. It can never activate on
   the % alone, and every state transition is logged — accepted
   trade-off, called out for the record.
2. The integrity guard compares against the repo on the same disk;
   it catches bad deploys and drift, not a compromised repo.
3. Yousef received ONE real desktop notification from the new guard
   at 22:07 ("drift persists: repomissing:display_state.sh") — that
   was the guard's own pair-list error, fixed and cleared at 22:13;
   it is also the live proof the alert path works.
4. APG read yellow at 22:10 (load-driven, self-clearing hysteresis);
   no session was active and hold enforcement is unaffected.
5. bats is not installed, so the (fixed) bats fixture still cannot
   execute — noted, not installed (out of scope).
6. The 48 h app soak, Stage C, the live calibration run, commit and
   publishing are untouched by this package and proceed as planned.
