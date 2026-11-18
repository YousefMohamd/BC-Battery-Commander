# Plugin Integration Audit — 2026-11-14

**Headline: 31 checks run · 30 PASS · 1 FIXED · 6 report-only notes · 0 display bugs left open**

Scope: deployed plugin `~/SwiftBar/battery-commander.10s.sh` + repo copy `src/plugin/battery-commander.10s.sh`; deployed + repo `display_state.sh`; `dispatch.sh` read-only as the action reference table. Method: full headless render (136 lines, 0 stderr) + every dynamic value cross-checked against a live source read in the same minute. Audit window 18:25–18:29 EET, 2026-11-14.

Pre-audit integrity: plugin deployed == repo (md5 `8804426527adc3a7d185c6520a729dbf`); display_state deployed == repo (md5 `431dc3b22be99168fa2fd519c23a694e`).

---

## FIXED — Bug #1: daemon line (the known bug)

**Before (rendered):**
```
BC limit daemon: not loaded (Phase C) | size=11 color=#909090
```
Cause: the plugin checked `launchctl list com.batterycommander.bclimit` in the **user** domain; bc-limit is a **system**-domain root LaunchDaemon (`sudo -n launchctl list` shows it, exit 0, ticking every minute), so the check always failed and printed the stale pre–Phase C text — false since 2026-11-13.

**Fix:** the launchctl check is replaced by a log-based liveness check with real statistics (plugin lines 930–958): parse the newest `state:` line of `~/.battery-commander/bc-limit-daemon.log`; alive = tick age ≤ 180 s; render last tick + age, pct/BCLM/mode from that line, and today's `WRITE:` count. A stale/missing log renders an orange warning instead of a false "not loaded".

**After (fresh headless render, 18:28:21):**
```
BC limit daemon: active — last tick 2026-11-14 18:27:54 (27s ago) | size=11 color=#909090
Daemon state: 86% · BCLM=10 · holding · writes today: 2 | size=11 color=#909090
```
Every rendered value verified against independent reads in the same minute: last daemon state `pct=86% BCLM=10 charging=0` (→ holding ✓); today's `WRITE:` lines in the daemon log = 2 (15:03:49 resume BCLM=100 + the hold write at 86%) ✓; age math 18:28:21 − 18:27:54 = 27 s ✓; render stderr 0; the string `not loaded (Phase C)` no longer exists in the plugin (grep count 0).

Backups: `battery-commander.10s.sh.pre-integrationfix-20261114` in both `~/SwiftBar/` and `src/plugin/` (md5 `88044265…` = pre-fix). Post-fix: deployed == repo, md5 `d41d579009b2a327cd2fa3545a71657f`; deployed copy is `-rwxr-xr-x` (exec bit verified after the in-place edit — today's deploy lesson applied); `bash -n` clean.

---

## PASS — actions & structure

1. **Render integrity** — 136 lines, exit clean, stderr empty (before and after the fix).
2. **Every plugin action exists in dispatch** — all 47 unique `param1=` values in the plugin source (including conditional branches not rendered today: `kill_discharge`, `kill_calibrate`, `power_saver_on`) exist in dispatch.sh's case table. 47/47.
3. **Every `bash=` path exists** — state-dir `dispatch.sh` (all menu actions), `/usr/bin/open` + the state-dir path (Logs item). No dead paths.
4. **display_state.sh integration** — plugin sources it for mode/icon/discharge line; its live output (`DISPLAY_MODE=hold`, `ICON=🔌`, `DISCHARGE_STATUS=` empty) matches the render exactly, and the empty discharge line is correct (no session file, no shadow flag).

## PASS — header & status lines (vs live sources, same minute)

5. **Header `🔌 86%`** — ioreg CurrentCapacity/MaxCapacity = 4491/5209 = 86.2% → 86 (the tool's floor convention, same as the daemon's pct); ExternalConnected=Yes, IsCharging=No → hold-on-AC icon 🔌 white per spec.
6. **Charge 86% / Mode: Holding at 86%** — matches daemon state line and display_state.
7. **Health: 75%** — 5209/6900 = 75.49% → 75 ✓. **568 cycles** — ioreg CycleCount ✓.
8. **Temperature: 30°C** — bc-status/watchdog battery temp 29.7–30.6 °C ✓.
9. **Backend: bclm** — daemon state line `backend=bclm` ✓.
10. **Overnight line** — byte-identical to `~/.battery-commander/.overnight_summary`: "Last night (Nov 13 -> Nov 14): 86% -> 70% (-16%, 1.4%/h)" ✓ (the fixed morning report's output).

## PASS — limits & quick actions

11. **✓ Custom Limit — 86% / 85%** — config `LAST_UPPER=86 / LAST_LOWER=85` ✓. "Remove Hold (return to 86%/85%)" consistent.
12. **✓ Stop Charging Now (hold at 86%)** — check glyph present because mode=hold (BCLM=10 at upper) ✓.

## PASS — power & sleep sections

13. **Power Mode — Balanced, checked** — plugin infers the active profile via power_mode.sh's rule (battery sleep minutes 18 → balanced); live pmset battery sleep = 18 ✓.
14. **"Active: Bat 18/10/10m · AC 90m"** — exactly matches `pmset -g custom`: battery sleep 18 / displaysleep 10 / disksleep 10; AC sleep 90 ✓.
15. **Preset sublabels** — e.g. Balanced "18/10/15" matches power_mode.sh's profile definition (sleep 18, display 10, standby 900 s = 15 min). Note the two triples measure different things (preset = profile definition incl. standby; Active = live pmset incl. disksleep); each is accurate against its own source.
16. **Sleep Mode — Normal, checked** — `~/.battery-commander/.sleep_mode` absent → plugin default "default" → Normal ✓ (dispatch creates the file only for non-default modes).
17. **Power Saver: ENABLED** — `.power_saver` state present; arm-sleep log agrees ("power_saver: ON").
18. **Power Nap: OFF** — `pmset` exposes no `powernap` key on this hardware (Mid-2012 MBP has no Power Nap); the plugin's default-to-0 engages and agrees with pmset_check's own reading (powernap=0). Rendered value is the truthful one.
19. **Wake on Network: ON ⚠️** — live `pmset -g` womp = 1 at audit time ✓ (it read 0 at 13:42 — the value changed during the day; the plugin tracks live pmset, which is the desired behaviour).
20. **TCP Keep-Alive: OFF** — no `tcpkeepalive` key in pmset output on this machine; default-to-0 engages; consistent with the rest of the tool.
21. **Hibernate after: 180 min ⚠️** — standbydelayhigh 10800 s = 180 ✓. **Deep Hibernate (RAM→Disk) ✅** — hibernatemode 25 ✓.
22. **Issues line "WoMP on; Slow hib;"** — consistent with womp=1 and standby 180 > 30 ✓.
23. **Wake events: 83** — independently reproduced: `pmset -g log | grep -cE "Wake from|DarkWake"` = 83 ✓ (10-min cache in the plugin).
24. **External USB: 1** — independently reproduced: `system_profiler SPUSBDataType | grep -c "Wireless Device"` = 1 ✓ (5-min cache).
25. **Sleep Report: OPTIMIZED** — consistent with the all-✅ power-saver block it summarises.

## PASS — sailing / discharge / services / misc

26. **Sailing block values** — "Sailing Range: 85% ↔ 86% (1% gap)" from config (the code deliberately ignores `.sailing_state`'s stored UPPER/LOWER); "Position: at upper (86%)" ✓; "Last change: 2026-11-14 18:24:39" and "Transitions: 86" byte-match `.sailing_state` metadata (LAST_TIME / TRANSITIONS), and 18:24:39 is the watchdog's consolidated tick that ran sailing_tracker.sh ✓.
27. **Services: 16 agents loaded** — `launchctl list | grep -c com.batterycommander` (user domain) = 16 ✓. (The system-domain daemon is not an "agent" in this count and is now covered by its own line.)
28. **✓ Launch at Login** — login items include `BatteryCommander` (verified via System Events) ✓.
29. **Repo == deployed after the fix** — plugin md5 `d41d5790…` both sides; display_state untouched, `431dc3b2…` both sides.
30. **Stale-text sweep** — no `.battopt-swiftbar` paths anywhere in the plugin; `battopt` survives only in historical header comments and the login-item legacy fallback match (`BattOpt|BatteryCommander|…`, line ~694, functional and harmless); the only rendered stale text was Bug #1, now removed.

---

## REPORT-ONLY (no fix taken — behaviour/product layer, or accurate today)

- **R1 — "Sailing Range" label vs `SAILING=false`.** The block's values are accurate, but the config's sailing flag is `false`; the label is the tool's long-standing name for the 85↔86 hold band. Renaming it (e.g. "Hold Range") is a product-vocabulary decision — a natural one to settle in the standalone app's UI pass.
- **R2 — Power-profile definition vs live sleep layer.** power_mode.sh's `balanced` definition also carries `standby_seconds=900` and `hibernate_mode=3`, while the live machine runs battery standby 600 s and hibernatemode 25 — owned by the sleep layer (arm_sleep/pmset_check enforce those). The plugin's checkmark infers the profile from sleep minutes only, and its Active line reports live pmset truthfully, so the display is faithful to both sources; whether the apply-order layering is intended is a behaviour question, not a display bug.
- **R3 — Calibration submenu text.** "Not in v1 yet — arrives in a later phase." is **accurate today** (the calibrate build is still pending; dispatch's `calibrate` records a `calibration_start` intent only, no calibration runs). The text will go stale the day the calibrate phase ships — flag it for that phase's deploy checklist.
- **R4 — Dispatch surface the plugin never renders.** dispatch.sh also accepts `sail_*`, `sched_*`, `clam*`, `calibration_start/stop`, `kill_charge`, `reapply_limit`, etc. The sched/clam handlers answer "not supported in BC yet", consistent with the approved wrapper decisions (features dropped); the plugin correctly renders no buttons for them. No plugin change.
- **R5 — Comment at plugin line ~216** still describes the enforcer as "(loaded only in Phase C)". Comment only, never rendered; left untouched by this display-layer pass.
- **R6 — Auto Cleanup block** (OFF / idle 0 min / Last cleanup: NO) renders from its state files; values are consistent with an actively used machine and a never-run cleanup. No independent ground truth exists beyond those files; nothing contradicts them.

---

## What Yousef must decide

Nothing is blocked on him from this audit. Optional, whenever he wants:
1. **R1** — keep "Sailing Range" as the band's name in the standalone app, or rename it (values are correct either way).
2. **R2** — confirm the layering is intended: power profiles own sleep/display times; the sleep layer owns standby/hibernatemode (the plugin already displays both truthfully).

Deploy artefacts from this task: fixed plugin (deployed + repo, md5 `d41d579009b2a327cd2fa3545a71657f`), backups `*.pre-integrationfix-20261114` in both plugin locations, splice helper kept at `battopt-project/bc-build/splice_daemon_block.py` (+ local `~/workspace/bc-build/`). No changes to dispatch.sh, display_state.sh, the daemon, or any state.
