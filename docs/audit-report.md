# Battery Commander — Full Audit Report

## Status: DRAFT — read-only audit, no changes made to any component
## Date: 2026-11-08
## Scope: every component audited as if rebuilding from scratch, for stability and integration
## Method: read-only File API reads (repo files) + read-only /run cat/ls (live state dir). No writes, no sudo, no SMC access, no installs, no pmset changes. Four parallel read-only agents (plugin, dispatch, helpers, powerwatch/app/state); findings synthesised here.
## Baseline: live config LAST_UPPER=86, LAST_LOWER=85, SAILING=false, SAIL_GAP=1; mode hold; BCLM=10 (hold) / 100 (resume); the limit % is never written to the SMC.

### Files audited

| Component | File | Size | Lines | mtime (UTC) |
|---|---|---|---|---|
| SwiftBar plugin | src/plugin/battopt.10s.sh | 38,768 B | 843 | — (not returned by read API) |
| Display helper | src/plugin/display_state.sh | 2,813 B | 67 | — |
| Router | src/daemon-helpers/dispatch.sh | 70,993 B | 1,970 | — |
| Guardian | src/daemon-helpers/guardian.sh | 19,398 B | 442 | 2026-10-30 |
| Sleep prep | src/daemon-helpers/arm_sleep.sh | 4,151 B | 108 | 2026-10-30 |
| AC watcher | src/daemon-helpers/ac_watcher.sh | 2,507 B | 69 | 2026-10-27 |
| Power saver | src/daemon-helpers/power_saver.sh | 4,796 B | 149 | 2026-10-24 |
| Charge-upper watcher | src/daemon-helpers/charge_upper_watcher.sh | 2,042 B | 47 | 2026-10-27 |
| Ensure limit | src/daemon-helpers/ensure_limit.sh | 2,314 B | 61 | 2026-10-26 |
| Enforce watchdog | src/daemon-helpers/enforce_watchdog.sh | 6,801 B | 177 | 2026-10-27 |
| Sleep/wake daemon | src/powerwatch/powerwatch.c | 4,626 B | 139 | 2026-10-15 |
| Daemon plist | src/agents/system/com.battopt.powerwatch.plist | 662 B | 26 | — |
| App launcher src | src/launcher/main.c | 2,360 B | 62 | 2026-10-07 |
| App | app/BattOpt.app (binary 49,816 B; Info.plist 864 B) | — | — | 2026-10-07 |
| Live state dir | ~/.battopt-swiftbar/ (95 non-hidden + ~50 dotfiles) | — | — | live |

### Executive summary

The tool is a working system, but it is a **battopt-shaped shell around a closed-source binary**: every charge-control decision is executed by `battopt` (`status` / `limit` / `discharge` / `charge` / `calibrate`), and the plugin, router, guardian, watchdogs, and launchers all parse battopt's free English output or call its daemon. Removing battopt therefore touches every component — but the **UI contract (menu items + dispatch param1 values) and the state machine (modes, tokens, config format) are sound and stay**. The independent version keeps the UI and the state machine, replaces every battopt call with a BC config write + the bc-limit enforcer (BCLM 10/100), and drops the trial/licence surface entirely (it is only 3 lines in the plugin; absent everywhere else).

The three highest-stability risks are: (1) **silent degradation** — `sudo -n battopt status` failures are swallowed (`2>/dev/null`) and the plugin/guardian/watchdog all proceed with empty data, some of them auto-firing resets against a dead daemon; (2) **overlapping enforcers** — guardian (L3, L10), enforce_watchdog, ac_watcher, and ensure_limit all reapply the limit on slightly different triggers with no coordination, and they disagree on the threshold (guardian +2, watchdog any excess); (3) **unbounded logs and stale state** — `.sleep_manager.log` 1.9 MB and `.enforce.log` 1.42 MB are never rotated, 38 `.bak` files litter the live dir, and the installed `power_saver.sh` is stale vs the repo (3,730 B vs 4,796 B).

### Verdict table (per component)

| Component | Verdict | One-line reason |
|---|---|---|
| SwiftBar plugin (battopt.10s.sh) | FIX | UI + param1 contract stay; status source, sudo, eval, NCR=14, pgrep-state must change |
| display_state.sh | FIX (merge) | Duplicate of the plugin fallback; keep one display decider |
| dispatch.sh | FIX (backend swap) | Router, intents, dialogs, locking stay; every battopt call swaps to BC config + bc-limit |
| guardian.sh | REPLACE | Core state machine; every actuator is battopt / its daemon plist |
| arm_sleep.sh | FIX | No battopt dependency; patch hard kills, focus-stealing mute, unbounded log |
| ac_watcher.sh | FIX | Sound transition logic; swap one battopt limit, atomic state write |
| power_saver.sh | FIX | pmset mechanism is correct and battopt-free; fix dead profiles, off-contradiction, silent failures |
| charge_upper_watcher.sh | REPLACE | Redundant 2 h poller once bc-limit enforces the temporary UPPER |
| ensure_limit.sh | FIX | Sound guards; swap battopt status/limit for BCLM read-and-reapply |
| enforce_watchdog.sh | REPLACE | Ladder built around restarting battopt's daemon; redesign around verifying BCLM |
| powerwatch.c | FIX | Sleep/wake watcher is sound; hardcoded paths, 7 s blocking delay, unjustified root |
| powerwatch plist + start/stop | FIX | Keep launchd pattern; re-label, verify real state, SIGTERM before SIGKILL |
| BattOpt.app / main.c | REPLACE | Thin notifier + sudo wrapper, silent failures, diverges from BattOpt-launcher.sh |
| Live state dir — config/flags | KEEP | Config, mode (hold), flags healthy and consistent with 86/85 |
| Live state dir — logs | FIX | Rotation misses the two >1 MB logs |
| Live state dir — .bak files | FIX (hygiene, user-approved only) | 38 stale backups, no retention policy; delete nothing without approval |
| power_saver.sh drift | FIX | Installed copy stale (3,730 B vs repo 4,796 B); decide canonical copy, re-sync |

---

## 1. SwiftBar plugin — src/plugin/battopt.10s.sh (843 lines) + display_state.sh (67 lines)

### What it does
- Menu-bar icon + full SwiftBar menu. Status comes from **two sources**: (a) `sudo -n /usr/local/bin/battopt status` (L53, cached 10 s in `.status_cache`), parsed with regexes for `Capacity`, `upper limit`, `lower limit`, `Health`, `Cycle`, temperature, trial days; (b) `ioreg -rn AppleSmartBattery` (L197–208) for `IsCharging`, `ExternalConnected`, `CurrentCapacity`/`MaxCapacity`, `NotChargingReason`, `ChargingCurrent`.
- Icon table (display_state.sh L40–52, duplicated as fallback in plugin L240–275): discharge 🔋, unplugged 🔴, charge_full/calibration ⚡, charging ⚡, hold on AC 🔌, else 🔴, invalid data ⏳. Colours: charging grey `#707070`, hold white `#FFFFFF`, on battery pink `#E8A0A0`, discharge `#8A9AAB`, temp ≥42 °C red `#FF3B30`, ≥38 °C orange `#FF9500`.
- Hold is inferred by magic number `NotChargingReason=14` (display_state.sh L21–24, plugin L225–229) — undocumented in the file.
- All 40+ menu items call `dispatch.sh` with a `param1` (full list in §1.1). Header/status rows are display-only.
- Notifications via `notify_proactive_v2` (L57–120): per-key cooldowns, max 3 non-critical/day, quiet hours 23:00–08:00 for non-critical, 1800 s minimum gap for critical keys.
- Auto-recovery (L125–141): if `battopt status` is empty or reports timeout/not-running 3 times, it fires `force_reset.sh` in the background and notifies `daemon_recovery` every 600 s.

### 1.1 Menu items and param1 (all via bash=$DISPATCH unless noted)
- Power mode: `power_mode_fast`, `power_mode_balanced`, `power_mode_awake`, `power_mode_deep`, `power_mode_custom`
- Sleep mode: `sleep_mode_default`, `sleep_mode_presentation`, `sleep_mode_download`, `sleep_mode_travel`, `arm_sleep`
- Charge: `stop_now`, `charge_full`, `smart_discharge`, `kill_discharge`, `force_reset`, `reset_defaults`
- Limits: `limit_custom`, `remove_limit_hold`, `disable_limit`
- Calibration: `calibrate`, `cal_stop`, `kill_calibrate`
- Clamshell: `clam0`, `clam1`, `clam2`; Schedule: `sched_on`, `sched_off`
- Reports/system: `details`, `sleep_report`, `sleep_report_save`, `open_reports`, `open_actions_log`, `login_toggle`, `open_app`, `about`, `Renew Trial Now` (not dispatch — `bash=/usr/local/bin/battopt-trial-renew`)
- Power Saver: `power_saver_on`, `power_saver_off`, `power_saver_report`
- Auto Cleanup: `pre_sleep_now`, `post_wake_now`, `auto_cleanup_toggle`
- Developer: `project_health`, `conflict_check`, `predictive`, `process_monitor`
- Logs: `logs_ai_bundle`, `logs_actions`, `logs_sailing`, `logs_arm`, `logs_daemon`, `logs_reports`
- Footer: `shutdown`

### 1.2 Closed-source / trial / sudo references
- `BAT="/usr/local/bin/battopt"` (L13); `CFG="/Library/Application Support/battopt/battopt_cfg"` (L15); `xbar.abouturl https://battopt.buddha-path.top` and `# <xbar.dependencies>bash,battopt</xbar.dependencies>` (L1–6).
- Trial/licence — only 3 places, all must go: `TRIAL` parse (L159), `Trial: ${TRIAL} days` header (L396), `Renew Trial Now | bash=/usr/local/bin/battopt-trial-renew` (L634). No licence check, no paywall branch, no expired handling — purely a display line plus the Renew button.
- sudo — exactly **one** call: `SNAP=$(sudo -n "$BAT" status 2>/dev/null)` (L53). `sudo -n` means a missing NOPASSWD rule fails silently and `SNAP` is empty.

### 1.3 Fragile points
1. **Single point of failure on battopt status text.** Seven regexes parse free English (`Capacity`, `upper limit`, `lower limit`, `Health`, `Cycle`, temperature, trial). Any wording/punctuation/locale/version change silently empties the values; the plugin then shows `?`/`Unknown` or falls back to the 80/75 defaults with no error. Temperature has three chained fallbacks including positional `awk -F',' '{print $3}'`.
2. **If battopt is gone, the plugin keeps rendering but lies quietly.** `SNAP` empty → PCT/UPPER/HEALTH/TEMP empty, `MODE=Unknown`; but the ioreg % still shows, and `Custom Limit` still shows config values. The auto-recovery counter then fires `force_reset.sh` every 3rd empty render — a restart loop against a binary that no longer exists.
3. **`eval "$DISPLAY_OUT"` (L214–221).** The plugin runs `display_state.sh`, captures stdout, and `eval`s it after only checking the string contains `ICON=` and `FINAL_COLOR=`. Same class: `source "$MYCFG"` twice (L31, L34), `source "$DASH/state_guard.sh"` (L9), `source "$SAIL_STATE"` — config/state files executed as code with no validation.
4. **Duplicated display logic, two sources of truth.** `display_state.sh` and the plugin fallback implement the same icon/colour/mode decisions independently (including the NCR=14 rule and the `pgrep -f "battopt discharge"` logic). They can drift; the `DISPLAY_OK` flag decides which wins. The `STATE_COLOR` grey rule also differs between them (display_state.sh sets grey whenever `ISCHG=Yes`; the plugin fallback additionally requires `ChargingCurrent > 50`).
5. **Magic number NCR=14.** No comment or reference for what 14 means. If the OS/firmware reports a different reason code for an SMC hold, hold is never detected.
6. **`pgrep -f "battopt discharge"` as state** (plugin L235/247; display_state.sh L27/40), bridged by a `.active_token` file. A stale token, a matching unrelated process, or a renamed binary flips the mode.
7. **Race conditions, no locking.** The plugin runs every 10 s and does unlocked read-modify-write on `.status_cache`, `.daemon_fail_count`, `.notify/` counters, `.last_icon`, `.audit.log` (with a `tail -200 && mv` rotation), `.temp_alert_state`, `.sd_watch`.
8. **Heavy/slow calls on the render path.** `system_profiler SPUSBDataType` (300 s cache), `pmset -g log | grep -c` (600 s cache, unbounded scan), and an `osascript` System Events login-item query run inside the 10 s render.
9. **TTL comment/code mismatch + refresh loop.** L38 comment says `20s TTL`, code says `CACHE_TTL=10`; combined with `trap … EXIT` re-triggering `swiftbar://refreshplugin` on every run, the plugin can re-render more often than the cache intends.
10. **Leftover test harness in production.** L615–632 "7-DAY TEST COUNTDOWN": if `.7day_test_start` exists it runs `verify-install.sh` and `self_maintenance.sh`, writes `final_report.txt`, fires a notification, and deletes the marker — from a menu render.
11. **pmset parsing assumes exact output shape.** Section headers, positional `awk $1/$2`, exact value tuples for power modes (`5/5`, `18/10`, `60/15`, `0`+hib `25`, else Custom); invented defaults when keys are absent (`HIBERNATE=3`, `STANDBY_DELAY=4200`), masking missing data as "standard".
12. **Hardcoded paths everywhere.** `/usr/local/bin/battopt`, `/usr/local/bin/battopt-trial-renew`, `/Library/Application Support/battopt/battopt_cfg`, `/Library/Logs/battopt/`, `/Applications/terminal-notifier.app/…`, `$HOME/.battopt-swiftbar/`, `swiftbar://refreshplugin?name=battopt.10s`, `com.battopt`, `BattOpt` login-item name. None is configurable.

### 1.4 Verdict — plugin
- **KEEP:** menu structure, labels, and the `param1` contract (all 40+ actions); the icon/colour table; ioreg-based detection (`ExternalConnected`, `IsCharging`, `CurrentCapacity`/`MaxCapacity`, `NotChargingReason`, `ChargingCurrent`); notification discipline (cooldowns, 3/day cap, quiet hours); the short status cache and capped change-only icon audit log (with locking); `pmset -g custom` / `pmset -g` reads for power/sleep modes (fix parsing).
- **FIX:** status source — drop `sudo -n battopt status` entirely; replace with the BC daemon/status source (ioreg + BC config + BCLM state: % from `CurrentCapacity/MaxCapacity`, limit from BC config, hold from BCLM=10, not from parsing battopt text). Delete all seven `SNAP` regexes, the `, charging/discharging/no charging` mode derivation, and the `Error:.*ongoing` STUCK check (or re-derive STUCK from the BC daemon). Remove the only sudo call. Replace magic `NCR=14` with the BC daemon's authoritative hold state (keep NCR only as a secondary hint, with a comment). Replace `pgrep -f "battopt discharge"` / `pgrep -f "battopt daemon"` with the BC daemon's pidfile/status endpoint. Replace `eval "$DISPLAY_OUT"` with structured `KEY=value` parsing with an allow-list; parse config as `KEY=value`, do not execute. Delete one of the two icon/colour implementations (keep `display_state.sh` as the sole decider) and resolve the grey discrepancy. Add locking (flock/atomic writes) for cache, counters, and logs. Reconcile the TTL comment/code. Parse pmset by exact key match with validation; show `?` when a key is absent instead of inventing defaults. Move `system_profiler`, `pmset -g log`, and the `osascript` login-item query out of the 10 s render. Re-point auto-recovery at the BC daemon. Rebrand all paths/labels (the `xbar.abouturl` must not survive). Guard the `IDLE` arithmetic against empty values.
- **DROP:** trial/licence UI entirely (L159, L396, L634) — no replacement text, no fake "Lifetime"/"Pro" badge, no trial-renew binary. The `battopt` binary dependency (L13, L6). The 7-Day Test countdown block (L615–632). Battopt config/log paths (`CFG`, `/Library/Logs/battopt/`). The `force_reset.sh` auto-launch in its battopt form (the menu item `force_reset` may stay only if its dispatch backend is the BC reset).
- **Open point:** Sailing is displayed in the Sleep Report submenu but no menu item toggles it directly — confirm whether a sailing toggle belongs in the independent UI or stays config-only. `SM_DEF_MARK` etc. (L484–493) are set but never used — dead code, safe to delete.

---

## 2. dispatch.sh — router (1,970 lines, 70,993 bytes)

### What it does
- Single `case "$1" in` (L690–~1967) routing every SwiftBar `param1` to an action. No shebang, no `set -euo pipefail`; uses bashisms, so it only works when invoked by bash. **No `*)` default branch** — an unknown `$1` silently does nothing except the EXIT-trap cleanup + SwiftBar refresh.
- Globals (L2–27): `DASH`, `BAT=/usr/local/bin/battopt`, `LOG=actions.log`, `LOCK=.op.lock`, `CFG=config`, `LOCK_TIMEOUT` default 600 s. Defaults `LAST_UPPER=85, LAST_LOWER=75, SAILING=true, SAIL_GAP=10`, then `source "$CFG"`. `state_guard.sh` is sourced if present (L18–21) — it provides `guard_lock/guard_unlock/guard_token_*/guard_session_*`, none defined in this file.
- `intent_apply_inner()` (L345–648) handles: `limit` (L361), `hold_current` (L416), `sail_on|sail_off|sail_gap` (L459), `disable_limit` (L500), `charge_full` (L529), `smart_discharge` (L583), `calibration_start` (L618), `calibration_stop` (L633). Wrapper `intent_apply()` (L650–657) deletes `.layer4b_hold` on success. `cleanup()` (L661–680) + `trap 'cleanup $?' EXIT` (L688) refreshes SwiftBar on every exit.
- All `limit` calls go through `run_with_retry` (L150–165): runs `sudo -n "$BAT" "$@"`, and on failure containing `ongoing`, pkills battopt clients, runs `discharge stop` + `calibrate stop`, and retries once.

### Limit intents and their exact battopt calls
- **`limit`** (L361–414; outer `limit_custom` ~L1150): parse U/L/MODE/GAP; set SAILING/SAIL_GAP; `save_cfg` (**config written before verification**); if `CUR > U`: write `discharge` to `.active_mode`, spawn `sd_watcher.sh`, `nohup sudo -n "$BAT" discharge "$U"` (L388), return 0 immediately (no verification discharge started). Else hold path: `run_with_retry limit "$U" "$L"` (L397) + retry, verify via `_verify_smc_upper` (parses `battopt status` for `upper limit [0-9]+`).
- **`hold_current`** (L416–457; outer `stop_now` ~L911 and `remove_limit_hold` ~L917 — **identical**, both call it): `U=$CUR`, `L=$CUR-1` (floor 20); `run_with_retry limit "$U" "$L"` (L429) + retry; on success persist U/L, `date +%s > .hold_since`, notify. Note: `remove_limit_hold` is a misnomer — it holds at the current %, it removes nothing.
- **`sail_on|sail_off|sail_gap`** (L459–498): adjust SAILING/SAIL_GAP/LAST_LOWER, `save_cfg`, `run_with_retry limit "$LAST_UPPER" "$LAST_LOWER"` (L481) + retry, verify.
- **`disable_limit`** (L500–527; outer ~L923): `U=100; L=99`; `run_with_retry limit "$U" "$L"` (L502) + retry; config written **only on success** — the cleanest intent.
- **`charge_full`** (L529–581; outer ~L929): `.charge_target=100`, `.active_mode=charge_full`, `run_with_retry limit 100 99` (L538) + retry; then `nohup sudo -n "$BAT" charge 100` (L553) plus a background watcher (L555–576) polling `sudo -n "$B" status` every 10 s up to 720× (2 h) for `Capacity ≥ 99`, then `charge stop` + `limit 99 98` (L566) and rewrites `config` directly via `printf … > config.tmp.$$ && mv` (bypasses `save_cfg`).
- **`smart_discharge`** (L583–616; outer ~L987–1055, two osascript dialogs for target 20–90 and Hold/Sail mode): fail if `CUR` empty or `CUR ≤ T`; `save_cfg`; `.active_mode=discharge`, spawn `sd_watcher.sh`, `nohup sudo -n "$BAT" discharge "$T"` (L611).
- **`calibration_start` / `calibration_stop`** (L618–640): start = `nohup sudo -n "$BAT" calibrate` (L626); stop = `kill_calibrate` (pkill + `battopt calibrate stop`).
- **`kill_charge` / `kill_discharge` / `kill_calibrate`** (L300–302): `kill_charge` uses `sudo pkill` **without `-n`** (bug); the others use `sudo -n pkill -9 -f "battopt …"` + `battopt … stop`.
- **Other direct battopt calls in the outer case:** `reapply_limit` (~L835, `sudo -n "$BAT" limit` — no lock, no verify); `reset_defaults` (~L848–905, `limit 85 80`); `charge_to_upper` (~L935–985, `limit` + `charge $U` + `charge_upper_watcher.sh`); `shutdown` (~L1196–1400, `battopt limit 100 99` at L~1305 after `battopt-release-cfg`); `resume` (~L1401–1445, `limit ${LAST_UPPER:-85} ${LAST_LOWER:-80}`); `sched_on/off` (`schedule enable/disable`); `clam0/1/2` (`clamshell 0/1/2`).

### Locking / concurrency
- Two locks: **`.op.lock`** (L5) — `acquire()` (L210–269) uses atomic `set -C` (noclobber) create writing `$$`; dead owner → re-read then `rm -f`; stale owner (>600 s) → killed only if `ps` shows `dispatch.sh` (PID-reuse guard), TERM, sleep 2, KILL; live owner → logs and **`exit 2`** (no queueing — the click just fails). A watchdog (L193–208) TERM/KILLs the owner's whole process tree after `LOCK_TIMEOUT` if the lock is still held. `release()` (L271–285) removes the lock only if content == `$$`. **Guard lock** from `state_guard.sh` (L18–21), used inside `intent_apply_inner` only; if that file is absent, every intent fails at L350.
- Gaps: (a) the outer case does `acquire; ensure_clean; release; intent_apply…` — `.op.lock` is released and the guard lock acquired afterwards, leaving a window where another dispatch can interleave between `ensure_clean` and the intent; (b) several branches take **no lock at all** (`force_reset` L691, `reapply_limit`, `sched_on/off`, `clam*`, `details`, `about`, log-openers); (c) `limit_custom`/`smart_discharge` **hold `.op.lock` while waiting on osascript dialogs** — unbounded user think time, and the 600 s watchdog will TERM/KILL the dispatch mid-dialog; (d) no `flock`; (e) lock file lives in `$HOME`, not `/tmp`.

### sudo / battopt / trial
- **sudo: ~70 occurrences**, pattern `sudo -n` everywhere except two bugs (`kill_charge` L300 and `_kill_transients` L320–324 use `sudo pkill` without `-n`). Subcommands: `status`, `limit U L`, `limit 100 99`, `limit 99 98`, `discharge $U/$T`, `discharge stop`, `charge 100`, `charge $U`, `charge stop`, `calibrate`, `calibrate stop`, `schedule enable/disable`, `clamshell 0/1/2`; helper binaries `battopt-daemon-restart`, `battopt-daemon-start`, `battopt-release-cfg`, `battopt-powerwatch-start/stop`; `pkill -f` patterns matching `battopt charge|discharge|calibrate`; daemon IDs `com.buddha-path.BattOpt.daemon`, `com.battopt.powerwatch`; config path `/Library/Application Support/battopt/battopt_cfg`.
- **Trial/licence: NONE** in all 1,970 lines. No trial, licence, expiry, purchase, or activation string. The "absent by design" requirement is satisfied by simply not introducing any.

### Logging
- `log()` (L29): `[HH:MM:SS] msg >> actions.log` — time-of-day only, no date, no levels. **No rotation, size cap, or truncation of `actions.log` anywhere in this file** — unbounded growth (shutdown truncates only `.enforce.log`/`.guardian.log`).

### Fragile points
1. **Battopt-output parsing everywhere.** `get_pct` greps `Capacity [0-9]+` (L31); `_verify_smc_upper` greps `upper limit [0-9]+` (L338–343); shutdown polls the same plus `NotChargingReason` from ioreg. If battopt is gone, `CUR` is empty: `limit` proceeds as if not above target, `hold_current`/`smart_discharge` fail, `charge_full`'s watcher spins 2 h then gives up, every verify returns empty → one retry → "failed" notify. `preflight` (L118) will also loop `battopt-daemon-restart` + `force_reset.sh` on every click when the daemon is dead.
2. **Config-before-verify.** `limit` (L380) and `sail_*` (L478) `save_cfg` *before* verification, so a failed apply leaves config and SMC diverged. (`disable_limit` and `hold_current` correctly gate the config write on success.)
3. **Duplicated logic.** The verify → sleep 2 → retry → verify block is copy-pasted ~6 times (L397–402, L429–434, L481–486, L502–507, L538–543, charge_to_upper); token-fail boilerplate duplicated in `charge_full`/`smart_discharge`/`calibration_start`; the same `battopt limit` + SMC-verify pattern repeats in `reapply_limit`/`reset_defaults`/`resume`/`shutdown` without the retry.
4. **Long functions/branches.** `intent_apply_inner` ~300 lines (L345–648); `shutdown` ~200 lines (~L1196–1400) mixing daemon stop, 10×1 s SMC-release polling, LaunchDaemon unload, state purge, plugin move, and a verification gate — and it proceeds to kill the daemon even when release is unverified ("proceeding to daemon stop").
5. **`save_cfg` is non-atomic** (`cat > "$CFG"`, L87–94) while `atomic_write` exists and is used elsewhere; the config is `source`d (code execution from a data file) in several places, so a torn write can break sourcing.
6. **Hardcoded paths** — `/usr/local/bin/battopt`, `$HOME/.battopt-swiftbar/*`, `/Applications/terminal-notifier.app`, `/Applications/BattOpt.app`, `~/SwiftBar/battopt.10s.sh`, `/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`, `/Library/Application Support/battopt/battopt_cfg`, plus assumed sibling scripts invoked with output discarded (`>/dev/null 2>&1 || true`), so a missing helper fails silently.
7. **Error-handling gaps.** `details` (~L1451) interpolates raw `battopt status` output into an osascript dialog without sanitising quotes (contrast `power_saver_report`, which does `tr '"`\\$' '____'`); `get_last_input`/`save_last_input` put the key unescaped into a `grep` pattern; `force_reset` (L691) runs with no lock and no preflight; `reapply_limit` has neither lock nor verify; unknown `$1` is silently ignored.
8. **Inconsistent defaults.** Top-of-file 85/75 gap 10 (L23–26) vs `reset_defaults`/`reapply_limit`/`resume` 85/80 gap 5 vs `charge_to_upper` fallback 86/85.
9. **External dependency.** All session/token logic (`guard_*`) lives in `state_guard.sh`; if it is absent or its functions change, every intent fails at L350.

### Verdict — dispatch.sh
- **KEEP:** outer `case "$1"` router and button names; `intent_apply_inner` skeleton (guard_lock, `_kill_transients` renamed to BC processes, token/session handling, `.active_mode` state machine, `notify`); `save_cfg` config format (`LAST_UPPER/LAST_LOWER/SAILING/SAIL_GAP`); dialogs + `validate_int` ranges in `limit_custom`/`smart_discharge`; `.op.lock` noclobber design + watchdog (fix the dialog-holds-lock and release-then-reacquire gaps); `log()` format and `actions.log` location (add rotation).
- **FIX:** replace `_verify_smc_upper` with a BC-state verifier and collapse the ~6 duplicated verify-retry blocks into one helper; make `save_cfg` atomic (use `atomic_write`) and write config only after successful verification (as `disable_limit`/`hold_current` already do); add `sudo -n` to `kill_charge` (L300) and `_kill_transients` (L320–324); sanitise `details` dialog input like `power_saver_report` does; add a `*)` branch to the outer case; reconcile inconsistent defaults (85/75 vs 85/80 vs 86/85); fix `project_health`'s bare `battopt` (PATH) vs `$BAT`; rework `preflight`/`ensure_clean` to check/kill BC processes instead of the battopt daemon.
- **DROP:** every `battopt …` invocation and `pkill -f battopt …` pattern; `battopt-daemon-restart/start`, `battopt-release-cfg`, `battopt-powerwatch-start/stop`; `com.buddha-path.BattOpt.daemon` / `com.battopt.powerwatch` LaunchDaemon handling; `/Library/Application Support/battopt/battopt_cfg`; `schedule`/`clamshell` subcommands; `force_reset.sh` as-is; `calibrate` (postponed — keep the menu routing stub only, no battopt call).
- **Per intent:** `limit_custom` → logic stays, call swaps (the over-target discharge sub-path L382–392 needs rework — BC has no discharge mechanism yet; sd_watcher must be replaced or the path deferred). `stop_now`/`remove_limit_hold` → logic stays, call swaps (rename `remove_limit_hold` — it holds, it removes nothing). `disable_limit` → logic stays, call swaps (cleanest intent). `sail_*` → logic stays, call swaps. `charge_full` → REWORK (markers/token/watcher skeleton stays; `limit 100 99`, `charge 100`, status-polling watcher, and watcher `limit 99 98` are all battopt — BC equivalent: write 100/99 to BC config, watcher polls ioreg/BC % and on ≥99 writes 99/98; needs a design decision on whether bc-limit has a force-charge mode or "charge to 100%" is just limit 100/99). `smart_discharge` → REWORK, later phase (wizard dialogs + config write stay; `battopt discharge` + `sd_watcher.sh` have no BC equivalent yet). `calibrate`/`cal_stop` → DROP from limit-writer scope (postpone). `kill_charge`/`kill_discharge` → REWORK (pkill patterns target battopt processes; need BC equivalents). `force_reset` → DROP as-is (BC needs its own recovery). `reapply_limit` → logic stays, call swaps + FIX (add the missing lock and verification). `reset_defaults` → logic stays, call swaps. `charge_to_upper` → REWORK (limit part swaps; `battopt charge $U` + `charge_upper_watcher.sh` have no BC equivalent yet). `shutdown`/`resume` → REWORK (all battopt LaunchDaemon IDs, `battopt_cfg`, `battopt-release-cfg`, powerwatch, daemon-start/stop are battopt infrastructure — drop; "release SMC via `limit 100 99`" becomes "write 100/99 to BC config + BCLM=100"). `sched_on/off`, `clam0/1/2` → DROP (battopt subcommands, no BC equivalent, out of limit-writer scope). Non-limit branches (sleep/power modes, reports, logs, health, login) → KEEP, except their `battopt status` reads (swap to ioreg/BC status).

---

## 3. Daemon helpers — src/daemon-helpers/

Shared context all files assume (not audited here): `$HOME/.battopt-swiftbar/` as the live state dir (config, `.active_mode`, `.sd_session`, `.active_token`, `.apg_paused`, `.user_shutdown`, `state_guard.sh`, `sd_watcher.sh`, `.throttle_helper.sh`), and the closed-source binary at `/usr/local/bin/battopt` invoked via `sudo -n`.

### 3.1 guardian.sh (442 lines) — REPLACE
Central state guardian / drift corrector. One-shot run, every 2 minutes via LaunchAgent (L6). No internal loop. Sequence: throttle (`ac_throttle "guardian" 300`), shutdown-flag exit, `source state_guard.sh || exit 1`, reads config + `battopt status` + ioreg, then Layers 1, 2, 2b, 3/3a, 4, 4b, heartbeat + log trim, then at the bottom calls `daemon_watchdog`, `ncr_monitor`, `smc_drift_check` (L437–439).
- Reads: config (`LAST_UPPER`/`LAST_LOWER`/`SAILING`, defaults 85/80), `sudo -n "$BAT" status`, `ioreg -rn AppleSmartBattery`, `pmset -g batt` / `pmset -g log`, `.active_mode`, `.sd_session`, `.apg_paused`, `.enforce_state`, `.hold_since`, `.active_token`.
- Writes: `actions.log` + `.guardian.log`, `.sd_session`, `.active_mode` (atomic tmp+`mv` in L3a only; plain `echo >` elsewhere), `.hold_since`, `.layer4b_hold`; trims `.guardian.log` only (100 KB → tail -200).
- battopt/sudo calls: `status` (L~55); L1: `sudo pkill -9 -f "battopt discharge"`, `sudo -n "$BAT" discharge stop`; L2: `nohup sudo -n "$BAT" discharge "$UPPER"` (the overshoot discharge) and fallback `limit "$UPPER" "$LOWER"`; L2b: pkill + `discharge stop` + `limit`; L3: `limit "$UPPER" "$LOWER"` (twice); L4: pkill + `discharge stop` (twice); L8 `daemon_watchdog` (~L350–385): `sudo -n pkill -9 -f "Application Support/battopt/battopt daemon"`, `sudo -n launchctl unload/load /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`, poll ≤15 s for daemon count = 1 + `battopt status`, then `battopt limit`; L9 `ncr_monitor` (~L392–405): `battopt limit` after abnormal NCR >300 s; L10 `smc_drift_check` (~L410–435): `battopt status` + `battopt limit`.
- Layers inside it: L1 stale session >7200 s → clean + kill discharge; L2 overshoot (see §5); L2b stop discharge at ≤UPPER; L3 config-as-truth + L3a silent-hold detection (`NCR=14 && SMC_UPPER==UPPER && mode=idle && no session && PCT>=UPPER` → write `hold`); L4 orphan discharge (90 s grace via `ps -o etime=` parsing); L4b phantom session (>60 s; AC-disconnected + mode=discharge → transition to `hold` + `.layer4b_hold`, else clear to idle); L8 daemon watchdog (exactly 1 daemon); L9 NCR monitor (0/14 normal, other sustained >300 s → reapply limit); L10 SMC↔config drift. Layers 5, 6, 7, 11+ are absent here — presumably in other files.
- Fragile: three overlapping drift re-appliers (L3, L10, plus enforce_watchdog) all calling `battopt limit` on slightly different triggers — race/churn source. `pmset -g log` full-log scan every 2 min for the wake parse. `guarded()` deliberately *not* applied to the L2 discharge start (comment explains why — would create a phantom session). `.active_mode` writes non-atomic except L3a. `heartbeat()` re-parses ioreg a second time. `actions.log` never trimmed by this file.
- **Verdict: REPLACE** — the state machine is the thing being rebuilt: every actuator is `battopt status/limit/discharge` or the battopt daemon/launchd plist, and the logic is tangled across 10 sub-layers with duplicated drift checks.

### 3.2 arm_sleep.sh (108 lines) — FIX
One-shot "Arm Sleep" preparation, triggered by a user button (no LaunchAgent, no loop). **No `battopt` and no `sudo` call anywhere in this file.**
- Sequence: HOME unset → error exit 1; `.user_shutdown` → silent exit 0. `notify()` fallback (terminal-notifier + icon). **Prepare warning (L25–33):** sources config, `WARN_UPPER="${LAST_UPPER:-85}"`, `WARN_PCT=$(pmset -g batt …)`; `if PCT < UPPER && AC Power` → log `WARNING: sleep on charger risk — Battery ${WARN_PCT}% < limit ${WARN_UPPER}%, charger attached, enforcement pauses during sleep, overshoot possible — unplug or wait for stable hold before sleeping` + notify. **Log + notify only; nothing is blocked, stopped, or unplugged.** Sleep-profile selection (`.sleep_mode` travel→travel, download→long; else `.sleep_profile`); if `.power_saver` flag exists → `power_saver.sh on` + `apply-delays`; else → `power_saver.sh off` + log. **Kill audio apps (L75–82):** `for app in VLC Spotify Music; do pgrep -x "$app" && /usr/bin/pkill -x "$app"; sleep 0.5; done`. **Mute Firefox (L84–90):** activates Firefox, `sleep 0.3`, Cmd-Shift-M keystroke via System Events. Runs `pre_sleep_cleanup.sh` (no existence check; stderr discarded). `sleep 2`, checks `coreaudiod` assertions, appends to `.arm_log`, `touch .armed_for_sleep`.
- Destructive: `pkill -x VLC/Spotify/Music` is a hard kill, not a graceful quit — kills playback/mid-task apps unconditionally, no check whether anything is playing or unsaved. No user confirmation in-script.
- Fragile: Firefox mute depends on *activating* Firefox (steals focus) and a Cmd-Shift-M keystroke landing in the right window/tab; fixed `sleep 0.5/0.3/2` delays assume app-kill and audio-teardown timing; `pre_sleep_cleanup.sh` invoked blind; `.arm_log` grows without bound (no trim); `pmset -g log` full scan for the wake count on every arm; the `power_saver.sh off` branch's log line claims "conservative sleep settings" while `off` still applies the conservative profile internally — confusing but not incorrect in effect.
- **Verdict: FIX** — no battopt dependency and the flow (warn → profile → quiet audio → verify → record) is sound; patch the kill to a graceful quit with a kill fallback, make Firefox mute non-focus-stealing or drop it, and cap `.arm_log`.

### 3.3 ac_watcher.sh (69 lines) — FIX
AC transition detector. Every 10 seconds via LaunchAgent (L6), one-shot per tick. Sources `.throttle_helper.sh` (battery-mode throttle 30 s) and `state_guard.sh || exit 1`; `.user_shutdown` → exit 0. Reads `ioreg` → `ExternalConnected`, NCR (audit-only); previous state from `.ac_state`; **writes new state unconditionally** (`echo "$EXT" > "$STATE_FILE"`, non-atomic).
- Transitions: `No → Yes`: clears `.layer4b_hold` if mode is `hold` (→ `idle`); if `guard_session_active` → log + exit (does not override charge_full/discharge/calibration); if `.apg_paused` → log + exit; else log `AC CONNECTED — reapplying intent` and `sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER"` (L~66). `Yes → No`: log only — `AC DISCONNECTED — sailing continues on battery` — **no action, sailing is preserved**.
- battopt/sudo: exactly one call, the `battopt limit` on AC connect. No `status`, no `discharge`.
- Fragile: 10 s poll + non-atomic `.ac_state` write (a crash mid-write leaves a torn/empty state → next tick treats PREV as "" and misses the transition). No validation that `EXT` parsed sanely beyond non-empty. The `.layer4b_hold` check tests two paths that are the same file — dead duplication. `DISPATCH` is defined (L11) but **never used**.
- **Verdict: FIX** — small, correct transition logic; replace the one `battopt limit` with a bc-limit reapply, make the state write atomic (tmp+mv), delete the unused `DISPATCH`.

### 3.4 power_saver.sh (149 lines) — FIX
Sleep-policy setter. No LaunchAgent/loop — invoked as `power_saver.sh on|off|apply-delays <profile>|enforce-sleep-policy|status`, principally by `arm_sleep.sh`. **No battopt call at all; ~25 `sudo -n pmset` calls.** (This file *does* change pmset sleep settings — that is its job; the audit changed nothing.)
- `apply_delays(profile)` (L11–75): `conservative` = 3600/3600/3600, sleep 30; `default`/`long`/`travel`/fallback = **all identical** 300/300/900, sleep 20. `long` and `travel` are dead copies of `default` — a real bug/placeholder.
- `on` (L~90–116): shutdown-guard exit; `pmset -a powernap 0, womp 0, tcpkeepalive 0, acwake 0, lidwake 1`; `enforce_sleep_policy` (conservative 3600); `standby 1, standbydelay 300, -b/-c standbydelayhigh/low 300, sleep 20 (all), disksleep 10`; `x86_64` only → `hibernatemode 25`; `autopoweroff 1, autopoweroffdelay 900`; writes flag atomically (`printf ENABLED > FLAG.tmp && mv`).
- `off` (L~117–141): restores `powernap/womp/tcpkeepalive/acwake 1, lidwake 1`; **still calls `enforce_sleep_policy` (conservative 3600)** — so "off" leaves 3600 s standby delays in place; `standby 0, standbydelay 3600, sleep 30, disksleep 10, hibernatemode 3, autopoweroff 0, autopoweroffdelay 3600`; `rm -f FLAG`.
- `status`: `ENABLED`/`DISABLED` by flag existence only — never verifies actual pmset values.
- Fragile: zero error checking on any `sudo pmset` — a failed `sudo -n` (e.g. sudoers lapse) still writes the `ENABLED` flag and prints success. `PMSET_BIN` env override honoured without validation. `on` and `apply_delays` fight each other on standby delays (300 vs 3600) depending on call order from arm_sleep. `hibernatemode 25` is x86-only, correct for this 9,1, but the file has no model guard otherwise. Header claim "Reduces battery drain during Sleep by ~60-70%" is unverified marketing, not measured in-code.
- **Verdict: FIX** — the pmset mechanism is correct and battopt-free; fix the dead `long`/`travel` profiles, the `off`-still-applies-conservative contradiction, add failure checks before writing the flag, and make `status` read real pmset values. Sleep policy is separate from the charge-limit enforcer; keep it a separate component.

### 3.5 charge_upper_watcher.sh (47 lines) — REPLACE
Bounded polling loop, not a daemon: `for i in $(seq 1 720); do sleep 10; … done` — up to 720 × 10 s = 2 h. Args: `BAT DASH LOG TOKEN UPPER`. Spawned by dispatch for an explicit "charge to UPPER" session; the session's own watchdog.
- Per tick: `.user_shutdown` → `sudo -n "$B" charge stop`, remove `.charge_upper_token` if it still equals `$T`, log, break. AC disconnected → same stop + token cleanup + break. `.active_mode` in `discharge|charge_full|calibration` → log `new session $MODE, exiting without stop`, remove token, break. Else `P=$(sudo -n "$B" status … 'Capacity [0-9]+')`; if `P >= U` → `sudo -n "$B" charge stop`, log `reached $U%, stopping` or `overshoot $P% > $U%, stopping`, remove token, break. After loop expiry, if token still matches → `charge stop` + remove token + log `timeout, stopping`.
- battopt/sudo: `sudo -n "$B" charge stop` (4 sites) and `sudo -n "$B" status` (1 site, every 10 s). No `limit`, no `discharge`.
- Fragile: 10 s poll means up to ~10 s of charging past UPPER before detection (overshoot is expected and merely logged). Token check-then-delete is non-atomic — two watchers could both act. No guard against being spawned twice for the same token. `P` empty (status failure) is silently skipped, so a dead `battopt status` lets charging run to the 2 h timeout. No APG/wake logic at all.
- **Verdict: REPLACE** — in the independent version "charge to UPPER" is just a temporary limit enforced by the bc-limit loop itself (BCLM=10 at UPPER); a separate 2-hour poller duplicating the enforcer is a race source. Fold its shutdown/AC-disconnect/new-session exits into bc-limit.

### 3.6 ensure_limit.sh (61 lines) — FIX
One-shot "reapply the limit after daemon restart". No loop, no LaunchAgent line in-file. Sequence: source `config`; session guard — if `guard_session_active` → log `active session ($ACTIVE) — skipping`, exit 0; legacy `.sd_session` non-empty and ≠ `none` → same skip; `.apg_paused` → log `APG thermal pause - skipping`, exit 0. Then **wait ≤10 s for daemon readiness** (`for i in 1..10; sudo -n /usr/local/bin/battopt status | grep -q Capacity → break; sleep 1`). Then parse `upper limit` from status: if status matches `Charge limit is suspended|Charge limit: disabled` → reapply; elif no limit reported → apply; elif `CURRENT != UPPER` → reapply. All reapplies are `sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER"` (3 sites). Defaults `UPPER=${LAST_UPPER:-85}`, `LOWER=${LAST_LOWER:-80}`.
- Fragile: the "daemon ready" wait keys off `battopt status` succeeding, not on the daemon actually holding the limit — a status that answers while the daemon is wedged passes the gate. The suspended/disabled regex is narrow by design but depends on battopt's exact English status strings. If `status` returns empty, `CURRENT` is empty and it applies — correct fallback, but it cannot distinguish "daemon down" from "no limit". No loop/retry beyond the 10 s wait.
- **Verdict: FIX** — logic and guards are sound and small; swap `battopt status/limit` for a bc-limit/BCLM read-and-write (compare SMC BCLM state against config, reapply if drifted) and keep the session/APG guards.

### 3.7 enforce_watchdog.sh (177 lines, Layer 12) — REPLACE
OS-level enforcement watchdog. One-shot per run (no internal loop; run interval is **not stated in the file** — the COUNT→time mapping is therefore unverifiable from this file alone). Throttle at top (`ac_throttle "enforce" 60` on battery). Shutdown-flag exit; `source state_guard.sh || exit 1`; if `guard_session_active` → log `skipping: active session (…)` to `.enforce.log`, exit 0.
- Reads: config (defaults 85/80); `ioreg` directly — `CurrentCapacity`/`MaxCapacity`/`IsCharging`/`ExternalConnected` — computes `PCT=$(( (CUR*100 + MAX/2) / MAX ))` (rounded). Heartbeat: writes `.enforce_hb` + `heartbeat: alive (PCT=… UPPER=…)` to `.enforce.log` at most every 60 s.
- Healthy path (L~66–70): if `EXT != Yes` OR `IsChg != Yes` OR `PCT <= UPPER` → **delete** `.enforce_state`, `.enforce_last_discharge`, `.enforce_last_critical`, `.enforce_crit_count` and exit 0. This resets the escalation counter every healthy tick, so COUNT is consecutive violations per episode.
- Escalation ladder (violation = charging on AC while PCT > UPPER): COUNT read from `.enforce_state` as `COUNT|TS`, incremented, logged `VIOLATION #$COUNT…`: `COUNT == 1`: reapply limit — `sudo -n "$BAT" limit "$UPPER" "$LOWER"`; on sudo failure log + `exit 1`. `COUNT == 4`: restart daemon — `sudo pkill -9 -f "Application Support/battopt/battopt daemon"`, `sleep 2`, `sudo launchctl unload/load /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`, `sleep 3`, reapply limit. `COUNT >= 8`: tracked discharge, gated by 300 s cooldown (`.enforce_last_discharge`): `guard_session_begin discharge`, write `.sd_session`, `nohup sd_watcher.sh … &`, `nohup sudo -n "$BAT" discharge "$UPPER" &`, `sleep 2`, verify with `pgrep -f "battopt discharge"` else roll back session + reapply limit. `COUNT >= 16`: CRITICAL, 300 s cooldown (`.enforce_last_critical`), terminal-notifier `BattOpt — CRITICAL / Charge limit not enforced…` with `-sound Basso`, capped at 3 notifications per episode (`.enforce_crit_count`, cleared by the healthy path). Saves `COUNT|NOW` to `.enforce_state` (non-atomic `echo >`).
- battopt/sudo: `sudo -n "$BAT" limit` (COUNT 1, 4, 8-fallback, 8-no-session), `sudo pkill -9 -f "…battopt daemon"`, `sudo launchctl unload/load` (the battopt daemon plist), `sudo -n "$BAT" discharge "$UPPER"`.
- Fragile / gaps (important): **no APG guard, no UPPER+2 threshold, and no post-wake delay** — it fires a discharge at any `PCT > UPPER` (1% over), unlike guardian L2. Its ladder assumes the battopt daemon exists and is restartable via launchctl; the COUNT==4/8/16 timings depend on an undocumented run interval. `exit 1` on sudo failure at COUNT==1 aborts the run *before* saving state, so the count does not advance on that failure mode. `.enforce.log` is never trimmed. The `COUNT` file is written non-atomically while guardian may read related state concurrently.
- **Verdict: REPLACE** — the ladder's premise ("trust SMC, not battopt exit code") is right, but every rung is battopt-shaped (restart *its* daemon, call *its* limit/discharge); in the independent version the "daemon" is bc-limit itself, so the ladder must be redesigned around verifying BCLM directly.

### 3.8 Trial/licence in the 7 helper files
**NONE found.** No `trial`, `licen[cs]e`, `expir`, `activat`, purchase, or entitlement strings in any of the 7 files. One caveat: in guardian.sh Layer 1 the read tool redacted a value on a `TOKEN=` line (~L88, stale-session cleanup) — from context it is almost certainly the session `.active_token`, not licence code, but it is unverified, not confirmed.

### 3.9 Sailing
Preserved — ac_watcher logs `sailing continues on battery` on disconnect and takes no action; guardian's L4b explicitly transitions an AC-interrupted discharge to `hold` (not idle) so the limit resumes on reconnect. Nothing in this audit proposes removing sailing.

---

## 4. powerwatch daemon + plist + start/stop

### 4.1 powerwatch.c (139 lines, 4,626 bytes, Oct 15) — FIX
- Registers with `IORegisterForSystemPower` and runs a `CFRunLoop`. It watches **sleep/wake only** — despite the name, it does **not** watch AC plug/unplug or battery level. Three events: `kIOMessageSystemWillSleep`: if `.user_shutdown` exists, allow sleep immediately; otherwise run `arm_sleep.sh`, `sleep(4)`, run `pre_sleep_cleanup.sh`, `sleep(3)`, then `IOAllowPowerChange`. `kIOMessageCanSystemSleep`: allow immediately. `kIOMessageSystemHasPoweredOn` (wake): run `post_wake_restore.sh`.
- `run_script()`: fork + `execle("/bin/bash", path)` with a minimal env (`HOME=<derived>`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`). Children are fire-and-forget (`SIGCHLD` ignored) — no exit-code check, no timeout.
- `resolve_paths()`: script dir = dirname of the resolved executable path; home = its parent. Hardcoded fallbacks `DEFAULT_SCRIPT_DIR="/Users/Yousef/.battopt-swiftbar"`, `DEFAULT_HOME_DIR="/Users/Yousef"`.
- Logs via syslog (`LOG_DAEMON`) + stdout `PowerWatch v3 started`. **Calls nothing else:** no `battopt`, no `dispatch.sh`, no SMC — only the three sleep scripts above.
- No compiled binary in the repo — source only. Installed binary is `/Users/Yousef/.battopt-swiftbar/powerwatch`, root-owned, 51,520 bytes, Oct 22 03:15 (plus a same-size `.bak` from Oct 15).
- Fragile: (1) hardcoded `/Users/Yousef` paths (source + plist HOME) — breaks on any other Mac; a publish blocker. (2) Up to 7 s blocking delay inside the sleep callback (`sleep(4)+sleep(3)`) — delays system sleep; a hung `arm_sleep.sh` has no timeout and blocks sleep indefinitely. (3) Runs as **root** but does nothing that needs root (it only execs user scripts) — over-privileged. (4) Scripts executed with no ownership/content validation; script location derived from binary location, so moving the binary silently retargets the scripts. (5) No `ThrottleInterval`, no crash-loop protection beyond KeepAlive.
- **Verdict: FIX** — concept is sound and it calls no battopt/SMC code, but fix the paths, the blocking delay (run scripts async with a timeout, or shorten), and the privilege (see §4.3).

### 4.2 Plist + start/stop — FIX
- Repo `src/agents/system/com.battopt.powerwatch.plist` (662 bytes, 26 lines) and installed `/Library/LaunchDaemons/com.battopt.powerwatch.plist` (root:wheel, 662 bytes, Oct 23 18:41 — same size). Contents: Label `com.battopt.powerwatch`, ProgramArguments `[/Users/Yousef/.battopt-swiftbar/powerwatch]`, **RunAtLoad true, KeepAlive true**, EnvironmentVariables `HOME=/Users/Yousef`, StandardOut `/var/log/powerwatch.log`, StandardError `/var/log/powerwatch.err`. **No `UserName` key — but as a LaunchDaemon it runs as root by default, so yes, it is a root daemon.** Live check: running as root, PID 158, started 1:05 PM. `/var/log/powerwatch.log` 13,555 bytes (Nov 8 09:42, current); `.err` 69,008 bytes but mtime Oct 23 04:02 (not growing recently).
- Start/stop helpers (`src/daemon-helpers/`, both "Runs as root via sudo NOPASSWD"): `battopt-powerwatch-start` (244 bytes, 10 lines): if `launchctl list` shows the label, exit 0; else `launchctl load -w`, `sleep 2`, exit 0 — **always exits 0, never verifies the daemon actually started.** `battopt-powerwatch-stop` (212 bytes, 8 lines): `launchctl unload`, `sleep 1`, `pkill -9 -f "battopt-swiftbar/powerwatch"`, exit 0 — **SIGKILL, no graceful SIGTERM, no verification it stopped.**
- **Verdict: FIX** — keep the launchd pattern, but re-label (`com.batterycommander.*`), drop hardcoded HOME, make start/stop verify real state instead of always exiting 0, SIGTERM before SIGKILL.

### 4.3 Privilege split (key design decision for the independent version)
- `powerwatch` itself does **not** need root — it only runs sleep scripts — so it should become a **user LaunchAgent**, not a root LaunchDaemon.
- The **limit enforcer (`bc-limit`) does need privilege**, because writing SMC key BCLM (10 = hold / 100 = resume) requires root on Catalina: give it a separate, minimal root LaunchDaemon (or a privileged helper via SMJobBless), keeping the sleep/wake watcher unprivileged and the enforcer's attack surface as small as possible.
- The launcher must start `bc-limit` + the menu UI with no `sudo -n`, no terminal-notifier, no SwiftBar dependency, and no call to any `battopt` binary; trial/licence helpers (`battopt-trial-renew`, `500.battopt-renew`) must not be carried over.

---

## 5. BattOpt.app — launcher — REPLACE
- Info.plist (`app/BattOpt.app/Contents/Info.plist`, 864 bytes, Oct 7): CFBundleIdentifier `com.yousef.battopt.app`, CFBundleName `BattOpt`, display name **"BattOpt Control Center"**, version **1.0.0**, `LSMinimumSystemVersion` **10.15**, `LSUIElement` true (menu-bar app, no Dock icon), `NSPrincipalClass` NSApplication, icon file `battopt`, executable `BattOpt`. Binary: `Contents/MacOS/BattOpt`, 49,816 bytes, Oct 7.
- Source `src/launcher/main.c` (2,360 bytes, 62 lines, Oct 7). Minimal launcher, not a real app: (1) checks `~/.battopt-swiftbar/.disabled`; (2) immediately fires a `terminal-notifier` notification ("Control Center is running" / "Restoring Control Center…") via `system()`; (3) ensures SwiftBar is running (`pgrep` / `open /Applications/SwiftBar.app`); (4) forks; the child runs `sudo -n /usr/local/bin/battopt-daemon-start` (NOPASSWD sudo, output discarded), and if it was disabled, deletes `.disabled` and notifies "Control Center restored". Parent exits immediately.
- Dependencies/problems: hard external deps on `/Applications/terminal-notifier.app` and `/Applications/SwiftBar.app`; silent failure everywhere (sudo failure invisible); no verification the daemon actually started; HOME fallback is `/Users/unknown`.
- **There is a SECOND, divergent launcher:** installed `~/.battopt-swiftbar/BattOpt-launcher.sh` (1,772 bytes, Oct 22 20:52), a bash script `main.c` never calls. It clears `.user_shutdown`/`.disabled`/`.paused`, restores plugins from `disabled/`, starts powerwatch via `sudo battopt-powerwatch-start`, loads **a different daemon plist** (`/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`), reloads all `~/Library/LaunchAgents/com.battopt.*.plist`, reapplies the limit via **`sudo -n /usr/local/bin/battopt limit $LAST_UPPER $LAST_LOWER`** (the closed-source binary), then launches SwiftBar. Which launcher actually runs is unclear — they disagree.
- **Proprietary dependency confirmed:** `battopt-daemon-start` (repo 1,099 bytes, 38 lines; installed `/usr/local/bin/battopt-daemon-start`, root:admin, 1,099 bytes, Oct 25 19:13) loads the `com.buddha-path.BattOpt.daemon.plist` and probes `sudo -n /usr/local/bin/battopt status`. `/usr/local/bin/battopt` is a symlink (Oct 6 22:25) to `/Library/Application Support/battopt/battopt` — the closed-source daemon is still in the start chain. Repo also contains `battopt-trial-renew` and `500.battopt-renew` helpers — trial/licence code that must be **absent by design** in the independent version.
- **Verdict: REPLACE** — thin notifier + `sudo -n` wrapper with silent failures, hard deps, and it diverges from `BattOpt-launcher.sh`; both launchers still call the closed-source `battopt` daemon. The independent launcher must start bc-limit + the menu UI, verify they actually started, and report failure visibly.

---

## 6. Live state dir — ~/.battopt-swiftbar/

Inventory (listed Nov 8 ~10:12 EET): 95 non-hidden entries + ~50 dotfiles. Subdirs: `backups`, `disabled`, `diagnostics`, `icons` (17 entries), `.notify`, `.guard_alerts`, `.sentinel.lock`, `plugin-backups`, `predictive_data` (92 entries), `reports` (23 entries), `src`.
- Config / flags (all as expected, read-only, untouched): `config` (53 bytes, Oct 28 20:56): `LAST_UPPER=86`, `LAST_LOWER=85`, `SAILING=false`, `SAIL_GAP=1`. `.active_mode` (5 bytes, Nov 7 13:06): `hold`. `.power_saver` (7 bytes, **root-owned**, Nov 8 09:42): `ENABLED` — read only, not changed. Other live flags: `.ac_state` (Nov 8 10:12), `.daemon_fail_count`, `.enforce_hb` (Nov 7 00:12), `.hold_since` (Nov 7 00:13), `.status_cache` (Nov 8 10:12).
- **Log sizes — rotation exists but is incomplete:**

| Log | Size | Modified |
|---|---|---|
| `.sleep_manager.log` | **1,912,044 (~1.82 MB)** | Nov 8 10:11 |
| `.enforce.log` | **1,420,925 (~1.36 MB)** | Nov 8 10:12 |
| `maintenance.log` | 76,125 | Nov 8 10:12 |
| `.guardian.log` | 75,043 | Nov 8 10:11 |
| `actions.log` | 47,752 | Nov 8 10:07 |
| `.hygiene.log` | 41,073 | Nov 8 10:12 |
| `.audit.log` | 30,215 | Nov 8 10:05 |
| `.cleanup.log` | 12,030 | Nov 8 09:41 |
| `.arm_log` | 9,945 | Nov 8 09:42 |

`cleanup_logs.sh` (3,932 bytes, 103 lines; header says daily 3 AM LaunchAgent) rotates **only** `actions.log` (>100 KB), `.healing.log`/`.audit.log` (>100 KB) and `.cleanup.log` (>50 KB), plus age-based pruning of `reports/`, `.notify/`, `.guard_alerts/`, `/tmp/battopt_*`. It does **not** touch `.enforce.log`, `.sleep_manager.log`, `.guardian.log`, or `maintenance.log` — exactly the two >1 MB logs are unrotated. (Whether the 3 AM LaunchAgent is actually loaded was not verified — see §9.)
- **`.bak` clutter: 38 files**, all from Oct 14–20 (mostly one Oct 14 fix session), ~1 MB+ in aggregate. Breakdown: `dispatch.sh` **20**, `guardian.sh` 3, `ac_watcher.sh` 3, `enforce_watchdog.sh` 2, `force_reset.sh` 2, `sd_watcher.sh` 2, `sentinel.sh` 2, `ensure_limit.sh` 1, `power_saver.sh` 1, `swiftbar_watchdog.sh` 1, `powerwatch` 1. No `.bak` cleanup policy exists (`cleanup_logs.sh` ignores them). Nothing deleted — per instructions.
- **Installed-vs-repo drift (md5):**

| File | Installed md5 | Repo md5 (src/daemon-helpers/) | Verdict |
|---|---|---|---|
| `power_saver.sh` | `fc8514dc5bbe9e9afd338feccf8373ca` (3,730 B) | `73acd1c156a3bcc603b82191f08f6963` (4,796 B) | **MISMATCH — drift confirmed** |
| `dispatch.sh` | `0909b5179c10ebd420a2a37c177e9ab9` (70,993 B) | same | MATCH |
| `guardian.sh` | `06277386370b45c1976341aa3ff81bf2` (19,398 B) | same | MATCH |
| `ac_watcher.sh` | `d05cdde1b1354aa49ef522b89a7de242` (2,507 B) | same | MATCH |
| `charge_upper_watcher.sh` | `3d0d24a2a10d52a29e1a85da951221dd` (2,042 B) | same | MATCH |
| `arm_sleep.sh` | `6cfb787e98c8cbaef8e2999d42d7afe0` (4,151 B) | same | MATCH |

Only `power_saver.sh` drifted: installed copy is 3,730 bytes vs repo 4,796 bytes (1,066 bytes smaller) — the installed copy is stale relative to the repo. All other five files are byte-identical. (Note: the 2026-10-28 record said the installed `fc8514dc…` matched the installed copy of that date — the drift is repo-vs-installed, not a recent change. Decide which copy is canonical and re-sync; do not assume the repo copy is the live one.)
- **State-dir hygiene for the independent version:** one state dir with a manifest; all logs capped (e.g. rotate at 100 KB, keep last N lines — the existing `cleanup_logs.sh` pattern, extended to every log); backups versioned in `backups/` with a retention policy (keep latest 3 per file, purge >30 days) instead of `*.bak-*` litter in the live dir; no root-owned files in a user-owned dir (`.power_saver` is currently root-owned inside a user dir — a split-ownership smell).
- **Verdict:** config/flags KEEP; logs FIX; `.bak` files FIX (hygiene, user-approved only); `power_saver.sh` drift FIX.

---

## 7. Protection layers — verified in code

**(a) Threshold overshoot = UPPER+2, discharge at 89%+ — PRESENT, but only in guardian.sh.**
`OVERSHOOT=$((UPPER + 2))` and `if [ "$PCT" -gt "$OVERSHOOT" ] && [ "$AC_NOW" = "yes" ]` (guardian L~108–138). With the live config UPPER=86 this fires at PCT > 88, i.e. 89%+. **Inconsistent elsewhere:** enforce_watchdog fires at any `PCT > UPPER` (no +2), and charge_upper_watcher stops at `P >= UPPER`. So the +2 hysteresis is a guardian-only convention, not a system-wide one.
- **Verdict: ADAPT.** Keep the +2 hysteresis as the *trigger* (avoids churn on 1% noise), but replace the `battopt discharge` actuator — with a tight loop the overshoot should rarely reach +2, and "discharge" must become hold-and-wait-for-natural-drain or an independent discharge, not a battopt call.

**(b) APG guard (skip discharge if `.apg_paused`) — PRESENT in guardian, ac_watcher, ensure_limit; ABSENT in enforce_watchdog and charge_upper_watcher.**
Guardian L2 final condition includes `[ ! -f "$HOME/.battopt-swiftbar/.apg_paused" ]` (and logs `LAYER2: skipping discharge (APG thermal pause)` when the file exists with PCT > OVERSHOOT); L3/L10 also skip drift reapply while paused. ac_watcher skips AC-connect reapply while paused; ensure_limit skips entirely. But enforce_watchdog's COUNT>=8 discharge path and charge_upper_watcher never check `.apg_paused` — a thermal pause can be overridden by the watchdog.
- **Verdict: KEEP.** Thermal pause is orthogonal to the enforcer; it must still suppress any forced discharge, and must be *added* to enforce_watchdog, which currently lacks it.

**(c) Prepare warning (AC attached + PCT < UPPER → log + notify only) — PRESENT, exactly as specified, in arm_sleep.sh L25–33.**
Log line + `notify` with the ⚠ message; no blocking, no forced unplug, no state change. Verified verbatim in §3.2.
- **Verdict: KEEP.** Still true: with BCLM=100 (charging) and no loop running in sleep, the battery charges through sleep past UPPER — warn, don't block. (If BCLM=10 is already holding, the risk is lower, so reword the message to the charging-through-sleep case.)

**(d) Post-wake delay (skip discharge 600 s after a full Wake unless PCT ≥95) — PRESENT, only in guardian L2.**
`LAST_WAKE_LINE=$(pmset -g log | awk '$4=="Wake" && $5=="Wake"' | tail -1)`, parsed with `date -j -f "%Y-%m-%d %H:%M:%S %z"`, `WAKE_AGE=$((NOW - WAKE_EPOCH))`; `if [ "$WAKE_AGE" -lt 600 ] && [ "$PCT" -lt 95 ]` → log `LAYER2: skipping discharge (post-wake delay ${WAKE_AGE}s < 600s)` and `WAKE_DELAY=1`, which blocks the discharge. Fragile: if no Wake line is found or the date parse fails, `WAKE_AGE` defaults to 999999 (no delay — fail-open); the `$4/$5=="Wake"` match depends on `pmset -g log`'s exact column layout; and enforce_watchdog's discharge has no equivalent delay.
- **Verdict: ADAPT.** Keep a *shorter* delay (e.g. 60–120 s, not 600 s) scoped to *discharge only* — never to the BCLM=10 hold reapply; 10 minutes of unprotected charging after every wake is too long for a tight loop, but post-wake % readings are still briefly unreliable.
- **Note on (a)/(d):** in the independent version the primary enforcement (BCLM=10 at UPPER) is a *hold*, not a discharge — discharge is only the corrective action for an already-overshot battery, so both layers should gate the corrective discharge, never the hold.

---

## 8. Cross-cutting stability risks (top 10)

1. **Silent degradation on battopt failure.** `sudo -n battopt status` failures are swallowed (`2>/dev/null`) in the plugin, guardian, dispatch, and watchdogs; each proceeds with empty data. The plugin auto-fires `force_reset.sh` every 3rd empty render; dispatch `preflight` loops `battopt-daemon-restart` on every click when the daemon is dead. The independent version must distinguish "no data yet" from "daemon down" and must never auto-reset against a missing binary.
2. **Overlapping enforcers with no coordination.** guardian (L3, L10), enforce_watchdog, ac_watcher, and ensure_limit all reapply the limit on slightly different triggers; they disagree on the threshold (guardian +2, watchdog any excess, charge_upper_watcher ≥UPPER). One enforcer (bc-limit) with one trigger rule replaces all of them.
3. **Free-text parsing of battopt output as the system of record.** % / limits / health / temperature / trial / STUCK are all regexed from English sentences in the plugin, dispatch, guardian, and watchers. Any wording change breaks them silently. The independent version reads structured sources only (ioreg, BC config, BCLM).
4. **Config-before-verify divergence.** dispatch `limit` and `sail_*` write the config *before* verification, so a failed apply leaves config and SMC diverged. (`disable_limit` and `hold_current` already gate correctly — the pattern exists, it just isn't applied everywhere.)
5. **Non-atomic state writes + no locking in the hot paths.** `.active_mode`, `.ac_state`, `.enforce_state`, `.sd_session`, `.charge_upper_token`, `.daemon_fail_count`, `.notify/` counters, `.audit.log` rotation are plain `echo >` / check-then-delete, while the plugin (10 s), ac_watcher (10 s), guardian (2 min), and enforce_watchdog all write concurrently. Only L3a's hold write and power_saver's flag use tmp+`mv`.
6. **Unbounded logs + stale state.** `.sleep_manager.log` 1.9 MB, `.enforce.log` 1.42 MB, `actions.log` unbounded (no rotation in dispatch), `.arm_log` unbounded; 38 `.bak` files; installed `power_saver.sh` stale vs repo. No retention policy anywhere except the partial `cleanup_logs.sh`.
7. **Root/user privilege split is backwards.** powerwatch runs as root but needs no privilege; the plugin runs `sudo -n battopt status` on every 10 s render; `.power_saver` is root-owned inside a user-owned dir. The independent version splits cleanly: unprivileged UI + sleep watcher, one minimal privileged enforcer.
8. **Two divergent launchers, unclear which runs.** `main.c` (BattOpt.app) and `BattOpt-launcher.sh` disagree on the daemon plist, the start chain, and the limit reapply; both still call the closed-source binary. The independent version needs exactly one launcher that verifies what it started.
9. **Blocking sleeps and full-log scans on hot paths.** powerwatch blocks sleep up to 7 s; guardian scans the whole `pmset -g log` every 2 min; arm_sleep scans it for the wake count on every arm; the plugin runs `system_profiler` + `pmset -g log` + `osascript` inside the 10 s render; `limit_custom`/`smart_discharge` hold `.op.lock` while waiting on osascript dialogs (the 600 s watchdog will kill the dispatch mid-dialog).
10. **Hardcoded identity everywhere.** `/Users/Yousef`, `/usr/local/bin/battopt`, `/Library/Application Support/battopt/`, `com.buddha-path.BattOpt.daemon`, `com.battopt.*`, `BattOpt` login-item name, `https://battopt.buddha-path.top`. None is configurable; a rename or a different install location breaks silently. A publish blocker.

---

## 9. Trial / licence — absent by design

- **Plugin:** 3 places (TRIAL parse L159, header L396, Renew Trial Now L634) — the only trial surface in the whole tool. **DROP entirely** — no replacement text, no fake "Lifetime"/"Pro" badge, no trial-renew binary.
- **dispatch.sh:** NONE in 1,970 lines.
- **7 helper files:** NONE in any of them.
- **powerwatch / plist / launcher:** the launcher chain still *calls* the closed-source daemon (which owns the licence), and the repo contains `battopt-trial-renew` and `500.battopt-renew` helpers — **must not be carried over**.
- The independent version must have **no licence/trial code at all** — no checks, no expiry, no renewal, no "Pro" gating. The menu must not show any trial line.

---

## 10. Replace vs Fix vs Keep — master table

| Area | Verdict |
|---|---|
| Menu structure + param1 contract | KEEP |
| Icon/colour table | KEEP |
| ioreg-based detection | KEEP |
| Notification discipline (cooldowns, quiet hours) | KEEP |
| Config format (LAST_UPPER/LAST_LOWER/SAILING/SAIL_GAP) | KEEP |
| `.op.lock` noclobber design + watchdog | KEEP (fix gaps) |
| Sleep-policy (pmset) mechanism | KEEP (fix profiles) |
| Sailing | KEEP (do not remove) |
| Plugin status source / sudo / eval / NCR=14 / pgrep-state | FIX |
| display_state.sh duplication | FIX (merge to one decider) |
| dispatch backend (every battopt call → BC config + bc-limit) | FIX |
| dispatch verify blocks, save_cfg atomicity, defaults | FIX |
| arm_sleep kills / Firefox mute / .arm_log | FIX |
| ac_watcher state write / unused DISPATCH | FIX |
| power_saver dead profiles / off-contradiction / silent pmset failures | FIX |
| ensure_limit battopt calls | FIX |
| powerwatch paths / blocking delay / privilege | FIX |
| Plist labels / start-stop verification | FIX |
| State-dir log rotation (all logs) | FIX |
| power_saver.sh drift | FIX |
| guardian.sh | REPLACE |
| charge_upper_watcher.sh | REPLACE |
| enforce_watchdog.sh | REPLACE |
| BattOpt.app / main.c launcher | REPLACE |
| Trial/licence UI + helpers | DROP (absent by design) |
| schedule / clamshell subcommands | DROP (battopt-only, out of scope) |
| calibrate | DROP from limit-writer scope (postpone; menu stub only) |
| force_reset.sh as-is | DROP (BC needs its own recovery) |
| 7-Day Test countdown block | DROP |
| Battopt config/log paths | DROP |

---

## 11. Gaps / unverified items (from the audit agents)

- Whether `/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist` exists (a combined `/run` call listing it was blocked by the File API safety policy, HTTP 403; narrower retries confirmed the symlink and the start helper but not this plist).
- Contents of `BattOpt.app/Contents/Resources/` (icon files) — not read.
- Whether the daily 3 AM `cleanup_logs.sh` LaunchAgent is actually loaded — the script exists, its scheduling was not confirmed.
- `guardian.sh` L~88 `TOKEN=` line value was redacted by the read tool — from context almost certainly the session `.active_token`, not licence code, but unverified.
- `dispatch.sh` `TOKEN=…` assignments (L~384, ~532, ~602, ~620) were redacted the same way — the surrounding fail-handling was visible; the exact token-generation command could not be quoted.
- `enforce_watchdog.sh` run interval is not stated in the file — the COUNT→time mapping (COUNT 4/8/16) is unverifiable from the file alone.
- `display_state.sh` / plugin line numbers are approximate (`L~`) where the read tool's paging made exact lines hard to pin; the quoted code is verbatim.
- Not audited (dependencies the audited files assume): `state_guard.sh`, `sd_watcher.sh`, `.throttle_helper.sh`, `pre_sleep_cleanup.sh`, `post_wake_restore.sh`, `sleep_manager.sh`, `self_healing.sh`, `sentinel.sh`, `sailing_tracker.sh`, `predictive.sh`, `process_monitor.sh`, `project_health.sh`, `conflict_check.sh`, `morning_report.sh`, `pmset_check.sh`, `wake_analyzer.sh`, `sleep_monitor.sh`, `adaptive.sh`, `adaptive_governor.sh`, `consolidated_checks.sh`, `system_guard.sh`, `state_hygiene.sh`, `daemon_watchdog.sh`, `emergency-stop.sh`, `power_mode.sh`, and the LaunchAgent plists that set the 2-min / 10-s cadences. The FIX/REPLACE verdicts above assume those exist and are themselves audited before any rewrite lands.

---

## 12. Recommended build order (after this audit)

1. **bc-limit enforcer first** (limit-writer design, updated — see limit-writer-design.md): probe → enforce BCLM 10/100 on this Mac; dry-run, then one controlled write, then full cycle. Each phase separately approved.
2. **dispatch.sh backend swap** (limit intents only): `limit_custom`, `stop_now`/`remove_limit_hold`, `disable_limit`, `sail_*`, `reapply_limit` — config write + bc-limit signal, `_verify_smc_upper` → BC-state verifier, atomic `save_cfg`, config-after-verify.
3. **Plugin status source swap**: ioreg + BC config + BCLM; drop `sudo -n battopt status`, the regexes, the trial UI, `eval`, NCR=14; merge the display decider.
4. **Replace guardian + enforce_watchdog + charge_upper_watcher** with one BC watchdog that verifies BCLM directly (with the adapted protection layers from §7).
5. **Fix arm_sleep / ac_watcher / power_saver / ensure_limit** (small, independent patches).
6. **Replace the launcher** (one launcher, verifies what it starts) + **split privilege** (user LaunchAgent for powerwatch, minimal root daemon for bc-limit).
7. **State-dir hygiene**: log rotation for every log, `.bak` retention policy (user-approved), resolve the `power_saver.sh` drift, single canonical copy per file.
8. **Later phases (separate approvals):** smart_discharge, charge_full rework, calibrate, shutdown button, DMG. Push/publish LAST.
