# Changelog

All notable changes to BattOpt Control Center are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [v1.6.5] - 2026-10-16

### Added
- Custom Limit: 2-step dialog (limit → Hold/Sailing → gap if Sailing)
- Plugin: Hold Mode (static) and Sailing (with gaps) are now separate submenus
- guardian.sh: LAYER3 with config-as-source-of-truth + 300s hold-timeout
- `src/agents/swiftbar_watchdog.sh`: direct-binary launch (bypasses Gatekeeper -600)

### Fixed
- SwiftBar `open -a` failure on unsigned SwiftBar.app (macOS 10.15 Gatekeeper)
- Watchdog relaunch loop — now PPID=1, 5-min cooldown after 2 fails, respects .user_shutdown
- intent_apply limit now accepts MODE + GAP so sailing/hold choice is preserved
- Menu refresh after actions (swiftbar:// URL + EXIT trap)

### Changed
- Watchdog StartInterval 60→120s


## [v1.6.2] - 2026-10-16

### Changed
- Atomic intent pattern: single `intent_apply()` mutation path for all battery actions
- Refactored 11 cases: `limit_custom`, `sail_on`, `sail_off`, `sail_gap_set`, `stop_now`, `remove_limit_hold`, `disable_limit`, `charge_full`, `smart_discharge`, `calibrate`, `cal_stop`
- All mutations now kill transients + clear session + verify SMC before notifying
- `state_guard.sh`: new helpers `guard_token_write_locked` / `guard_token_clear_locked` (caller-must-hold-lock variants)

### Fixed
- Menu action conflicts eliminated (no more race between buttons)
- Orphan `battopt charge/discharge` processes after action switching
- Stale `.active_token` after shutdown

### Removed
- Dead code: `apply_intent`, `hold_at_current`, `sd_session_new`, `sd_session_current` (148 lines)


## [v1.6.0] - 2026-10-16

### Added
- 40 bats tests (state_guard, dispatch_helpers, syntax, ci_check, pct_calc, ac_watcher, sleep_manager, enforce_watchdog)
- bats-core submodule at tests/bats
- tests/run.sh wrapper
- SECURITY.md
- .github/workflows/ci.yml

### Changed
- Removed dead notify_proactive() function (superseded by _v2)


## [1.3.0] — 2026-10-11

### Added

- **Protection Layer 6** — Guardian heartbeat in `guardian.sh` records
  state every 2 minutes to `.guardian.log`.
- **Protection Layer 7** — Config Validator inside `self_healing.sh`
  checks `.sleep_mode`, `.current_power_mode`, `config`, and required
  directories; auto-fixes safe corruption.
- **Corrections Log** section in `FUTURE_DEVELOPMENT.md`.

### Fixed

- **Cache bug** — `$NOW_TS` in `battopt.30s.sh` was referenced before
  definition. Bash treated it as 0, making cache age negative. Cache
  never expired; plugin showed stale data indefinitely. Fixed by moving
  `NOW_TS=$(date +%s)` above its first use.
- **`$HOME` in launchd-root context** — `arm_sleep.sh`,
  `pre_sleep_cleanup.sh`, `post_wake_restore.sh` failed silently from
  `powerwatch`. Added line-2 guard `HOME="${HOME:-/Users/Yousef}"`.
- **`powerwatch` environment** — added `EnvironmentVariables: {HOME: ...}`
  to the LaunchDaemon plist.
- **Self-healing duplicate killing** — removed `HUNG_KILLER_V2` block
  (30 lines) that duplicated `zombie` killer.
- **`battopt-daemon-start` bypassing launchd** — rewrote to use
  `launchctl load -w` instead of `nohup … & disown`.
- **`BattOpt.app` ignoring `.user_shutdown`** — added early-exit guard.
- **`predictive.sh` extraction** — corrected regex for `TEMP`,
  `HEALTH`, `CYCLES`.

### Changed

- **Long Tasks Mode** migrated from `caffeinate -dis &` to
  `pmset -a disablesleep 1`. Revert uses `pmset -a disablesleep 0`.
- **Version unified** to `1.3.0` in plugin header, dispatch.sh banner,
  and `BattOpt.app` Info.plist.
- **Backups pruned**: plugin 48 to 5, scripts 76 to 5, dispatch root
  backups 7 to 0.

### Verified

- `pmset -a disablesleep 1` works on macOS 10.15.8 / MacBookPro9,1.
- All 30 helper scripts pass `bash -n`.
- Plugin reports live battery % matching system state.

---

## [1.2.0] — Unreleased (superseded)

Feature work bundled into 1.3.0. See `FUTURE_DEVELOPMENT.md` for the
full list accumulated since v1.1.0.

---

## [1.1.0] — 2026-10-09

### Added

- Power Saver mode (hibernatemode 25 on battery).
- Sleep Report with wake reasons, drain, and temperature.
- Sailing Tracker.
- Pre-Sleep Cleanup and Post-Wake Restore hooks.
- Adaptive Hibernate (battery-aware hibernatemode).
- Post-Update Recovery.
- Full rebuild of scripts after v1.0.0.

---

## [1.0.0] — 2026-10-06

### Added

- Initial release.
- SwiftBar plugin with charge cap.
- `dispatch.sh` router.
- Basic LaunchAgents and daemon start/stop.
- DMG installer.
