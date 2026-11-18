# Battery Commander — Dead-File Removal List (W5.3)
# For YOUSEF'S APPROVAL. Nothing on this list is deleted in W5.
# The .bak purge runs only via cleanup_logs.sh `purge-bak` + the
# .bak_purge_approved flag (after approval). File deletions happen at
# deploy (W6), after the BC replacements are built and verified.
# Live inventory: 2026-11-10 ~15:40 EET.

## Part 1 - .bak files (38 total, state dir)
# Policy: keep the latest 3 per file, purge the rest only if older than
# 30 days. On Nov 10 the Oct 14 files are 27 days old, so NOTHING is
# purgeable yet except by the latest-3 rule once they cross 30 days
# (Nov 13-14). The Oct 9 file is 32 days old but within the latest 3
# for its file, so it is kept.

### dispatch.sh - 20 files, total ~1,051,272 B (~1.0 MB)
# KEEP (latest 3 by mtime):
#   dispatch.sh.bak-a1-20261014-2029            58,932 B  Oct 14 20:16
#   dispatch.sh.bak-pre-fixes-20261014-2015     58,411 B  Oct 14 20:15
#   dispatch.sh.bak-pre-final-20261014-1207     57,250 B  Oct 14 12:07
# PURGE CANDIDATES (17 files, ~876,679 B, once > 30 days):
#   dispatch.sh.bak-before-groupA-20261014-0734    56,773 B  Oct 14 07:34
#   dispatch.sh.bak-pre-guards-20261014-1040       56,490 B  Oct 14 10:40
#   dispatch.sh.bak-pre-guards-20261014-1050       57,250 B  Oct 14 10:50
#   dispatch.sh.bak-before-v3-20261014-0344        55,056 B  Oct 14 03:44
#   dispatch.sh.bak-v3-20261014-0343               55,056 B  Oct 14 03:30
#   dispatch.sh.bak-before-4fixes-20261014-0301    52,620 B  Oct 14 02:46
#   dispatch.sh.bak-before-4fixes-20261014-0303    52,620 B  Oct 14 02:46
#   dispatch.sh.bak-20261014-0136                   51,730 B  Oct 14 01:36
#   dispatch.sh.bak-before-apply-20261014-0246     51,730 B  Oct 14 02:46
#   dispatch.sh.bak-pre-fixes-20261014-0243        51,730 B  Oct 14 02:43
#   dispatch.sh.bak-before-reorder-20261014-0329   53,713 B  Oct 14 03:03
#   dispatch.sh.bak-before-resume-full-20261014-0519 56,410 B Oct 14 05:19
#   dispatch.sh.bak-before-test4-20261014-0433     55,755 B  Oct 14 04:33
#   dispatch.sh.bak-before-test5-20261014-0448     56,317 B  Oct 14 04:48
#   dispatch.sh.bak-chargefix-20261014-0832        56,398 B  Oct 14 08:32
#   dispatch.sh.bak-final-sync-20261014-0813       56,977 B  Oct 14 08:13
#   dispatch.sh.bak-pre-drytest-20261014-0238          54 B  Oct 14 02:38

### ac_watcher.sh - 3 files (KEEP all 3)
#   ac_watcher.sh.bak-pre-guard-20261014-0941   1,734 B  Oct 14 09:41
#   ac_watcher.sh.bak-20261014-0826             1,367 B  Oct 14 08:26
#   ac_watcher.sh.bak-20261014-0135             1,312 B  Oct 14 01:35

### guardian.sh - 3 files (KEEP all 3)
#   guardian.sh.bak-pre-final-20261014-1207    12,186 B  Oct 14 12:07
#   guardian.sh.bak-pre-guard-20261014-0948    11,800 B  Oct 14 09:48
#   guardian.sh.bak-20261014-0135              11,696 B  Oct 14 01:35

### force_reset.sh - 2 files (KEEP both; Oct 9 file is 32 days old but
#   within the latest 3 for its file, so the latest-3 rule keeps it)
#   force_reset.sh.bak-before-v3-20261014-0344  1,269 B  Oct 14 03:44
#   force_reset.sh.bak-v3-20261014-0343         1,269 B  Oct  9 09:05

### sentinel.sh - 2 files (KEEP with the sentinel removal below; sentinel
#   itself is DROP, so its .baks go with it)
#   sentinel.sh.bak                             9,214 B  Oct 20 23:22
#   sentinel.sh.bak.1792527760                  8,776 B  Oct 20 23:22

### sd_watcher.sh - 2 files (KEEP both)
#   sd_watcher.sh.bak-pre-final-20261014-1207   1,405 B  Oct 14 12:07
#   sd_watcher.sh.bak-final-sync-20261014-0813  1,184 B  Oct 14 08:13

### enforce_watchdog.sh - 2 files (KEEP both)
#   enforce_watchdog.sh.bak-pre-guard-20261014-0941  3,684 B  Oct 14 09:41
#   enforce_watchdog.sh.bak-20261014-0135            3,629 B  Oct 14 01:35

### Singletons (KEEP)
#   ensure_limit.sh.bak-pre-guard-20261014-1054      1,752 B  Oct 14 10:54
#   powerwatch.bak-pre-sleep-audit-20261015-0019    51,520 B  Oct 15 00:19
#   power_saver.sh.bak-pre-sleep-audit-20261015-0017 2,489 B  Oct 15 00:17
#   swiftbar_watchdog.sh.bak-20261014-0549            723 B  Oct 14 05:49

## Part 2 - Dead files (repo)
# Verdict DROP (W0 / W0-extension / W3 / W5.1). Delete at deploy (W6)
# after the BC replacements are built and verified. Nothing deleted in W5.
| File | Size | Reason |
|---|---|---|
| src/swiftbar-plugin/battopt.15s.sh | 17,444 B | Orphan second plugin, not installed, stale 80/75 defaults. |
| src/daemon-helpers/charging_guard.sh | 428 B | Zero callers AND the script is a no-op (always exits 0). |
| src/daemon-helpers/charge_upper_watcher.sh | 2,042 B | Folded into bc-watchdog.sh (W3). Deletion needs EXPLICIT user approval (W3 flag, W6/deploy). |
| battopt-trial-renew | - | Trial bypass, never installed in /etc/periodic/daily/. |
| 500.battopt-renew | - | Trial bypass, never installed. |
| src/agents/swiftbar_watchdog.sh | 799 B | Divergent copy; the live copy (1,157 B) is in the state dir. |
| src/launcher/main.c | 2,360 B | Unreferenced 4th launcher. build-app.sh uses the AppleScript, not main.c. main.c calls `sudo -n battopt-daemon-start` + terminal-notifier BattOpt. DROP (W5.1). |
| app/BattOpt.app | (bundle) | STALE repo bundle (only battopt.icns, Info.plist 864 B vs installed 2,094 B). Replaced by the rebuilt BatteryCommander.app (W5.1). Delete after the new bundle is verified. |
| src/agents/system/com.battopt.powerwatch.plist | 662 B | Root daemon plist. Replaced by the user agent com.batterycommander.powerwatch (W5.2). Delete at deploy (after the user agent is installed). |
| src/sudoers/battopt | 783 B | Replaced by the pmset-only src/sudoers/battery-commander (W5.1). Delete at deploy (after the installed /etc/sudoers.d/battopt is read once to confirm it matches, and the new file is installed). |
| src/app/BattOpt-launcher.sh | 5,929 B | Renamed to BatteryCommander-launcher.sh in W5.1 (old name moved to trash, recoverable - same as the W2 plugin rename). |
| src/app/BattOpt.applescript | 929 B | Renamed to BatteryCommander.applescript in W5.1 (old name moved to trash, recoverable). |

## Part 3 - Dead files (state dir, $HOME/.battopt-swiftbar/)
# Verdict DROP (W0 / W0-extension). Delete at deploy (W6). Nothing deleted in W5.
| File | Size | Reason |
|---|---|---|
| sentinel.sh | 9,208 B | Dead, never runs; no agent, no caller, heartbeat stale Oct 20 23:49. |
| daemon_watchdog.sh | 582 B | Dead, superseded; guardian calls its own inlined function. |
| heat_analysis.sh | 2,747 B | State-dir diagnostic, zero callers. |
| check_permissions.sh | 2,123 B | State-dir diagnostic, zero callers. |
| check_spotlight.sh | 1,812 B | State-dir diagnostic, zero callers. |
| log-change.sh | 160 B | State-dir diagnostic, zero callers. |
| battopt-daemon-start | 296 B | State-dir copy of a root helper (DROP). |
| emergency-stop.sh | 2,360 B | REPLACE (hand-run only). Redesign as a BC capability, not wired in; removal is part of that redesign. |
| BattOpt-launcher.sh | 1,772 B | Old state-dir copy (differs from the repo 5,929 B). Replaced by the BC launcher at deploy. |
| src/powerwatch.c | 4,440 B | Stale state-dir copy (diverges from the repo 4,626 B). Repo copy is canonical; replaced at deploy. |
| src/powerwatch.c.bak-v3 | 4,663 B | Third powerwatch.c version. Stale; replaced at deploy. |
| powerwatch.bak-pre-sleep-audit | 51,520 B | Old binary backup. Keep until the new binary is proven at deploy. |

## Part 4 - Orphaned state (capture-then-remove)
# Capture the contents for the record, then remove at deploy.
| File | Notes |
|---|---|
| .sentinel.lock/ + .sentinel_heartbeat + .sequence + .session | Sentinel is dead (lock PID 65048 dead, heartbeat stale Oct 20 23:49). |
| .7day_test_start | 7-Day Test start marker; W2 deleted the countdown. |
| .native.lock | Native Swift app lock (PID 58071 dead); native app DROPPED (W2). |
| .charging_guard_cooldown | Inert marker (charging guard is gone). |

## Part 5 - Root helpers (/usr/local/bin - NOT in the repo)
# These are installed root helpers (DROP per W0-extension). Removal is a
# USER step at deploy (they are outside the repo and need root to remove).
#   battopt-daemon-start, battopt-daemon-stop, battopt-daemon-restart,
#   battopt-powerwatch-start, battopt-powerwatch-stop,
#   battopt-release-cfg, battopt-restore-cfg, battopt-trial-renew
# BC has no equivalent: the enforcer is managed via launchctl
# (com.batterycommander.bclimit), powerwatch via its user agent,
# and there is no trial/licence code at all.
