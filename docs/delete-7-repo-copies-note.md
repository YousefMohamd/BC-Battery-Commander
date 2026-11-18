# Delete 7 repo copies of root helpers — Completion Note
**Date:** 2026-11-11 (deleted 17:29–17:30 EET). **Approved by Yousef 2026-11-11 17:26 EET**
("امسح النسخ الميته"). **Status: DONE — 7/7 deleted, 0 failed.**
The /usr/local/bin copies were already removed by Yousef (sudo) 2026-11-10 20:20;
these were the REPO copies in `src/daemon-helpers/`.

## What was deleted (File API two-phase delete — trash, recoverable)
All under `/Users/Yousef/muse-fileapi/.muse-fileapi/trash/` (timestamps UTC):

| File (repo) | Size | md5 (pre-delete) | Trash entry |
|---|---|---|---|
| `src/daemon-helpers/battopt-daemon-start` | 1099 B | b13021361e27bcf245b8d88c9ce443e3 | 2026-11-11T15-29-54-468Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-daemon-start (confirmId d7eef292-eb31-41d6-9d6c-27b36361733c) |
| `src/daemon-helpers/battopt-daemon-stop` | 270 B | bc6a7e5afbbb3357bc3264fe8fd7148c | 2026-11-11T15-29-56-313Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-daemon-stop (confirmId e3ac626a-7557-4426-baac-572d74b461b7) |
| `src/daemon-helpers/battopt-daemon-restart` | 734 B | 51dc7373d05b61dc869998c89d32905b | 2026-11-11T15-29-57-506Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-daemon-restart (confirmId 5b3addfc-2931-4cba-9e31-8b6272111e58) |
| `src/daemon-helpers/battopt-powerwatch-start` | 244 B | 117636f2a9aa6ccfaf209de820ab9fbc | 2026-11-11T15-29-58-737Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-powerwatch-start (confirmId 48deb1c1-700f-4899-96e4-2ede137d2dcf) |
| `src/daemon-helpers/battopt-powerwatch-stop` | 212 B | eee02d2dc4a73cd072412adddaafe0a4 | 2026-11-11T15-30-00-654Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-powerwatch-stop (confirmId dcf985f1-3163-4419-b888-844d818eb584) |
| `src/daemon-helpers/battopt-release-cfg` | 517 B | 9a0b28be9b86cd731bcea6d811a68e7d | 2026-11-11T15-30-01-884Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-release-cfg (confirmId ac02210c-ae1a-497a-9b52-ea4dfd92e69f) |
| `src/daemon-helpers/battopt-restore-cfg` | 516 B | b6c3eb59d28d3c54adf0e0e298143a15 | 2026-11-11T15-30-03-113Z___Users_Yousef_Projects_BattOpt-CC-Release_src_daemon-helpers_battopt-restore-cfg (confirmId 9154d031-cae8-44cd-b4ca-338ed721d0ec) |

Script: `~/workspace/bc-build/delete_7_repo_copies.py` (local) — reuses the
two-phase delete flow from `delete_dead_repo.py`.

## Reference check (before deletion, re-verified 2026-11-11)
Grepped the live new stack — repo `src/plugin`, `src/daemon-helpers`, `src/app`,
`src/agents`, `src/launcher` + the new state dir `~/.battery-commander/` + the
installed agent plists `~/Library/LaunchAgents/` — for all 7 filenames.
Only matches:
- `src/daemon-helpers/force_reset.sh:5` — a **comment** describing what the OLD
  version did ("The old version was entirely battopt-based (BAT reads, sudo pkill,
  battopt-daemon-start/restart, ...)"). The BC version never calls them.
- `src/daemon-helpers/battopt-daemon-restart:20` — a **comment** in the deleted
  file itself ("force_reset.sh's unload -w + battopt-daemon-start fallback is
  reachable").
- `/Users/Yousef/.battery-commander/force_reset.sh:5` — the same deployed comment.
No live code calls, invokes, or sources any of the 7 files. Safe to delete.

## Verification (after deletion, 2026-11-11 ~17:31 EET)
- Glob `src/daemon-helpers/battopt-*` → **count 0** — all 7 gone.
- New stack intact: dispatch.sh 77,492 B (Nov 11 16:16, overnight-report version),
  bc-watchdog.sh 50,258 B, plugin battery-commander.10s.sh 42,985 B (Nov 11 16:16),
  `/Applications/BatteryCommander.app` present.
- Processes: launcher applet PID 7952 running; powerwatch PID 44060 running.
  (bc-watchdog.sh has no persistent process by design — it runs every 60 s via
  launchd; its heartbeats prove it is ticking.)
- Watchdog heartbeats 17:27:38 / 17:28:38 / 17:29:38 — PCT=86 BCLM=10 cfg=86/85
  mode=hold APG=yellow backend=bclm.
- Installed agent plists: grep for all 7 names → **no matches** (clean).
- bc-status (read-only): Capacity 86.1%, IsCharging No, ExternalConnected Yes,
  BCLM 10, Backend bclm — **battery holding at 86%**. READ-ONLY DONE, no SMC
  modification.

## Constraints kept
No sudo. No launchctl load/unload. No Phase C (bc-limit daemon still installed,
NOT loaded). No commit/push. No live battery tests. No SMC writes. No pmset
changes. No /etc/sudoers.d touch. No agent-plist or login-item touch.
GET /info first. Read before writing.

## Remaining
- The old battopt CLI binary `/usr/local/bin/battopt` still exists (Yousef's
  manual escape hatch until Phase C; removal is his decision).
- `src/daemon-helpers/test_enforce_watchdog.sh` references the deleted
  `enforce_watchdog.sh` + `sd_watcher.sh` (sandboxed test for dead code, from the
  2026-11-10 dead-file removal — expected; the live test is `test_bc_watchdog.sh`).
