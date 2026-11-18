# Battery Commander — State-Dir Manifest (W5.3)
# Single source of truth for ~/.battopt-swiftbar/ contents, purpose, retention.
# Live inventory: 2026-11-10 ~15:40 EET (146 entries). The rename to
# ~/.battery-commander/ is a single-pass migration in W6.3; this manifest
# describes the CURRENT dir name. Paths below are relative to the state dir.
#
# OWNERSHIP: everything is user-owned (Yousef:staff) EXCEPT:
#   .power_saver (root, 7 B) and powerwatch (root binary, 51,520 B).
#   Fix .power_saver with: sudo chown Yousef:staff ~/.battopt-swiftbar/.power_saver
#   (user step; the next power_saver.sh on/off atomic write also self-heals
#   it, since the dir is user-writable). powerwatch stays root-owned until
#   the user LaunchAgent replaces the root daemon at deploy (W6).

## Config & canonical state (KEEP, never auto-delete)
| File | Purpose | Retention |
|---|---|---|
| config (53 B) | Canonical config: LAST_UPPER=86, LAST_LOWER=85, SAILING=false, SAIL_GAP=1. The single source of truth (W1/W6.1). | Keep. Written atomically by dispatch only. |
| .active_mode (5 B) | Current mode: hold / idle / discharge / charge_full / calibration. | Keep. |
| .ac_state (4 B) | AC transition state (Yes/No). | Keep. |
| .hold_since (11 B) | Timestamp the current hold started. | Keep. |
| .sleep_profile (10 B) | Active sleep profile (default). | Keep. |
| .last_session_mode (45 B) | Shutdown-time mode snapshot (dispatch shutdown handler only). | Keep. |
| .last_session_config / .last_session_upper / .last_session_lower | Shutdown-time limit snapshot. | Keep. |
| .power_saver (7 B, ROOT-owned) | Power-saver flag (ENABLED). See ownership note above. | Keep value; fix ownership (user step). |
| .sailing_state (89 B) | Sailing state. NOTE: currently holds STALE 85/80 fallbacks (tracker source dead) - W1/W2/W5 must use config 86/85, never this file's limits. | Keep; limits ignored until the tracker is fixed. |
| .sailing_history (3,952 B) | Sailing transition history. | Keep. |
| .last_wake (MISSING) | Wake timestamp (epoch) for the watchdog post-wake delay. Does NOT exist yet - W5.2 powerwatch writes it on wake. Watchdog uses a gated pmset -g log fallback until then. | Created by powerwatch at deploy. |
| .last_wake_count (4 B) | Wake counter. | Keep. |
| .last_sleep_state / .last_icon / .last_inputs / .lid_watch_state / .usb_cache / .wake_cache / .temp_alert_state | Small caches and last-known states for the plugin/reports. | Keep; plugin-managed. |
| .daemon_fail_count (2 B) | Consecutive bc-status failure count (W2.6 auto-recovery). | Keep. |
| .enforce_hb (11 B) | Enforce heartbeat. | Keep. |
| .status_cache (411 B) | Plugin status cache (20 s TTL, W2). | Keep; plugin-managed. |
| .night_test_baseline (1,781 B) | Night-test baseline. | Keep. |
| .permissions_status (752 B) | Permissions check output. | Keep. |
| .sleep_baseline (126 B) | Sleep baseline. | Keep. |
| final_report.txt (83 B) | A saved final report. | Keep. |

## Flags & markers (KEEP, tiny files)
| File | Purpose |
|---|---|
| .auto_cleanup (0 B) | Auto-cleanup toggle. |
| .charging_guard_cooldown (0 B) | Charging-guard cooldown marker (guard is gone; marker is inert). |
| .paused_services (0 B) | Paused-services marker. |
| .report_sent (0 B) | Report-sent marker. |
| .7day_test_start (11 B) | 7-Day Test start marker. ORPHANED - W2 deleted the countdown. On the removal list. |
| .maint_alerted (11 B) | Self-maintenance alert marker. |
| .apg_state (6 B) | APG state. FROZEN "green" since Oct 10 - NOT trusted; W3 treats APG as UNKNOWN on first BC run. |
| .native.lock (5 B) | Native Swift app lock (PID 58071 dead). The native app is DROPPED (W2 decision). On the removal list. |
| .armed_for_sleep | Set by arm_sleep, cleared by post_wake_restore (W4.1 single owner). cleanup_logs clears it in daytime hours. |

## Logs (ROTATED by cleanup_logs.sh at 100 KB, keep last 200 lines)
| File | Live size (2026-11-10) | Notes |
|---|---|---|
| .sleep_manager.log | 2,154,863 B (2.05 MB) | Was UNROTATED - W5.3 rotation covers it now. |
| .enforce.log | 1,747,165 B (1.71 MB) | Was UNROTATED - W5.3 rotation covers it now. |
| maintenance.log | 87,501 B | Was UNCOVERED - W5.3 rotation covers it now. |
| actions.log | 72,967 B | Rotated (was the only one covered before W5.3). |
| .guardian.log | 58,213 B | Was UNCOVERED - W5.3 rotation covers it now. |
| .audit.log | 32,539 B | Rotated. |
| .healing.log | 27,730 B | Rotated. |
| .hygiene.log | 19,854 B | Rotated (W5.3 adds it). |
| .cleanup.log | 12,894 B | Kept under 50 KB (own rule). |
| .arm_log | 10,725 B | Capped at 100 KB by arm_sleep itself (W4.1); rotation covers it too. |
| .sleep_analysis.log | 2,455 B | Rotated (W5.3 adds it). |
| .watchdog.log | (new, W3) | Rotated (W5.3 adds it); trimmed at 100 KB by the watchdog itself. |
| powerwatch.log / powerwatch.err | (new, W5.2) | Rotated (W5.3 adds it). User-agent logs (were /var/log as root). |

## Live scripts (state-dir copies - REPLACED at deploy, after W6.4)
# The repo copies are the source; these state-dir copies are the LIVE
# (old battopt) versions until deploy copies the BC repo files over them.
# Do NOT edit these in place; edit the repo and deploy.
| File | Repo version (BC) | Live version |
|---|---|---|
| dispatch.sh (70,993 B) | W1: 76,477 B | OLD (Oct 28) |
| ac_watcher.sh (2,507 B) | W4: 4,813 B | OLD |
| arm_sleep.sh (4,151 B) | W4: 6,428 B | OLD |
| pre_sleep_cleanup.sh (1,161 B) | W4: 2,085 B | OLD |
| power_saver.sh (3,730 B) | W4: 5,934 B (from installed copy) | Installed copy (Oct 28) |
| ensure_limit.sh (2,314 B) | W4: 3,693 B | OLD |
| display_state.sh (2,813 B) | W2: 4,128 B | OLD |
| self_maintenance.sh (2,422 B) | W2: 4,183 B | OLD |
| guardian.sh (19,398 B) | W3: replaced by bc-watchdog.sh | OLD (replaced at deploy) |
| enforce_watchdog.sh (6,801 B) | W3: replaced by bc-watchdog.sh | OLD (replaced at deploy) |
| charge_upper_watcher.sh (2,042 B) | W3: folded into bc-watchdog.sh | OLD (file deletion needs approval) |
| consolidated_checks.sh (681 B) | W3: folded into bc-watchdog.sh | OLD (replaced at deploy) |
| sd_watcher.sh (2,220 B) | REPLACE (skeleton only) | OLD |
| adaptive_governor.sh (3,234 B) | REPLACE as BC APG guard | OLD |
| adaptive.sh (1,398 B) | KEEP (never triggered) | Live |
| system_guard.sh (1,643 B) | KEEP | Live |
| conflict_check.sh (2,140 B) | KEEP | Live |
| pmset_check.sh (1,106 B) | KEEP | Live |
| sleep_monitor.sh (1,073 B) | KEEP (+1-line fix) | Live |
| power_mode.sh (3,752 B) | KEEP (minor FIX notes) | Live |
| sleep_manager.sh (2,415 B) | FIX - profiler-only (W5.2 decision: NO pmset tuning restore) | Live (neutered, logs only) |
| post_wake_restore.sh (731 B) | FIX small | Live |
| wake_analyzer.sh (2,298 B) | FIX | Live |
| morning_report.sh (2,019 B) | FIX | Live |
| predictive.sh (3,047 B) | FIX | Live |
| process_monitor.sh (1,743 B) | FIX | Live |
| project_health.sh (8,777 B) | FIX | Live |
| sailing_tracker.sh (1,652 B) | FIX | Live |
| self_healing.sh (8,862 B) | FIX | Live |
| state_guard.sh (2,546 B) | FIX | Live |
| state_hygiene.sh (8,664 B) | FIX | Live |
| launch_swiftbar.sh (690 B) | KEEP | Live |
| cleanup_logs.sh (3,932 B) | W5.3: extended rotation (every log) | OLD (replaced at deploy) |
| force_reset.sh (3,543 B) | FIX (guard-lock pattern kept) | Live |
| BattOpt-launcher.sh (1,772 B) | W5.1: replaced by BatteryCommander-launcher.sh | OLD state-dir copy (differs from repo 5,929 B) |
| powerwatch (51,520 B, ROOT) | W5.2: rebuilt from repo powerwatch.c (v4) | OLD root binary (provenance undetermined) |
| powerwatch.bak-pre-sleep-audit (51,520 B) | - | Backup of the old binary. |
| battopt-daemon-start (296 B) | DROP (root helper) | On the removal list. |
| emergency-stop.sh (2,360 B) | REPLACE (hand-run only) | On the removal list (redesign as BC capability, not wired in). |
| sentinel.sh (9,208 B) | DROP (dead, never runs) | On the removal list. |
| daemon_watchdog.sh (582 B) | DROP (dead, superseded) | On the removal list. |
| heat_analysis.sh (2,747 B) | DROP (zero callers) | On the removal list. |
| check_permissions.sh (2,123 B) | DROP (zero callers) | On the removal list. |
| check_spotlight.sh (1,812 B) | DROP (zero callers) | On the removal list. |
| log-change.sh (160 B) | DROP (zero callers) | On the removal list. |
| charging_guard.sh | DROP (zero callers, no-op) | Repo file; on the removal list. |

## Directories
| Dir | Purpose | Retention |
|---|---|---|
| .guard_alerts/ | Guard alert files (> 7 days deleted by cleanup). | Keep dir. |
| .notify/ | Notification files (> 48 h deleted by cleanup). | Keep dir. |
| .sentinel.lock/ | Sentinel lock dir. ORPHANED (sentinel dead). On the removal list. |
| backups/ | Backup dir. | Keep; review at deploy. |
| diagnostics/ | Diagnostics output. | Keep. |
| disabled/ | Disabled plugins (restored by the launcher). | Keep. |
| icons/ (17 entries) | Menu-bar icons. | Keep. |
| plugin-backups/ (9 entries) | Plugin backups. | Keep; review at deploy. |
| predictive_data/ (101 entries) | Predictive snapshots. | Keep. |
| reports/ (24 entries) | Reports + log archives. Morning reports: keep latest 7; archives > 30 days deleted. | Keep dir. |
| src/ | State-dir source copies. powerwatch.c (4,440 B) DIVERGES from the repo copy (4,626 B); .bak-v3 (4,663 B) is a third version. Repo copy is canonical for the BC rewrite; state-dir copies are stale, replaced at deploy. Installed binary provenance undetermined. | Keep until deploy. |

## .bak files (38 total, Oct 9-15) - retention: latest 3 per file, purge > 30 days
# Full list with sizes/dates is in bak-removal-list.md. Summary:
#   dispatch.sh: 20 files (Oct 14). Keep latest 3 (a1-20261014-2029 20:16,
#     pre-fixes-20261014-2015 20:15, pre-final-20261014-1207 12:07).
#     17 beyond latest 3; all 27 days old on Nov 10 (purge when > 30 days).
#   ac_watcher.sh: 3 (keep all 3). guardian.sh: 3 (keep all 3).
#   force_reset.sh: 2 (keep both; one is Oct 9, 32 days old, but within latest 3).
#   sentinel.sh: 2. sd_watcher.sh: 2. enforce_watchdog.sh: 2.
#   ensure_limit.sh: 1. powerwatch.bak: 1. power_saver.sh.bak: 1.
#   swiftbar_watchdog.sh.bak: 1.
# Purge is MANUAL ONLY (cleanup_logs.sh purge-bak + .bak_purge_approved
# flag, after Yousef approves bak-removal-list.md). Nothing auto-purges.

## Orphaned state (capture-then-remove, on the removal list)
| File | Notes |
|---|---|
| .sentinel.lock/ + .sentinel_heartbeat + .sequence + .session | Sentinel is dead (heartbeat stale Oct 20 23:49, lock PID 65048 dead). Capture the 4 files' contents for the record, then remove. |
| .7day_test_start | 7-Day Test start marker; W2 deleted the countdown. |
| .native.lock | Native Swift app lock (PID 58071 dead); native app DROPPED (W2). |
| .charging_guard_cooldown | Inert marker (charging guard is gone). |
