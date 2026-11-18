# Dead-file removal — COMPLETE

**Date:** 2026-11-10 ~20:18 EET. **Approved:** full list 17:46 EET (W5 parts 1–5 +
W6 addendum, incl. charge_upper_watcher.sh explicitly); start approved 20:13 EET
(Yousef tapped the option). **Method:** repo files via File API two-phase delete
(trash, recoverable, `delete_dead_repo.py`); old state-dir files via /run `mv` to
`~/.Trash/` (File API allowed root is repo-only). No sudo, no launchctl, no Phase C,
no commit/push, no live battery tests, no SMC writes.

## Results

### Repo files deleted (14, File API trash — `/Users/Yousef/muse-fileapi/.muse-fileapi/trash/`)

| File | Size | confirmId | Trash timestamp (UTC) |
|---|---|---|---|
| src/swiftbar-plugin/battopt.15s.sh | 17,444 B | 4ca9e06f-d095-4bb0-87d6-cab67e8d49d0 | 2026-11-10T18-17-11-911Z |
| src/daemon-helpers/charging_guard.sh | 428 B | dc6c3451-414e-44bd-8cdc-1fa86b49a920 | 2026-11-10T18-17-13-584Z |
| src/daemon-helpers/charge_upper_watcher.sh | 2,042 B | 275d9c47-e81e-45ad-b5dd-2b8aa8d14712 | 2026-11-10T18-17-16-475Z |
| src/daemon-helpers/battopt-trial-renew | 670 B | 271ff967-1642-475f-b7c3-6b14443b454d | 2026-11-10T18-17-21-160Z |
| src/daemon-helpers/500.battopt-renew | 45 B | ad6a09ee-f0ff-4f17-9e3a-5547b90adeb2 | 2026-11-10T18-17-25-322Z |
| src/agents/swiftbar_watchdog.sh | 799 B | 00a4e8c2-4133-4ab6-a988-66165ab5b170 | 2026-11-10T18-17-28-485Z |
| src/launcher/main.c | 2,360 B | 4d051bc7-8aa6-4fd9-adb2-334b435def96 | 2026-11-10T18-17-30-656Z |
| src/agents/system/com.battopt.powerwatch.plist | 662 B | d0a91faf-5ed5-43d1-af99-ecad3a19e630 | 2026-11-10T18-17-32-676Z |
| src/sudoers/battopt | 783 B | 82c83533-2992-4a8b-9aab-1f2adccf60c1 | 2026-11-10T18-17-33-972Z |
| src/daemon-helpers/guardian.sh (W6 addendum) | 19,398 B | 7c7bdf88-6fa1-459d-a0be-17ac080ce300 | 2026-11-10T18-17-35-536Z |
| src/daemon-helpers/enforce_watchdog.sh (W6 addendum) | 6,801 B | 9e17244a-cf3d-44c8-bfb3-97fe7620fddf | 2026-11-10T18-17-37-085Z |
| src/daemon-helpers/consolidated_checks.sh (W6 addendum) | 681 B | aa12dbeb-b1e9-47b9-b327-a3d9be7d83b1 | 2026-11-10T18-17-38-668Z |
| src/daemon-helpers/sd_watcher.sh (W6 addendum) | 2,220 B | 5148f888-6253-482d-b152-ef7f800c694e | 2026-11-10T18-17-40-204Z |
| src/daemon-helpers/adaptive_governor.sh (W6 addendum) | 3,234 B | da5ecc49-fa3d-4bf6-9abe-b434d98c82c1 | 2026-11-10T18-17-41-740Z |

Notes:
- The trial-renew files were found in `src/daemon-helpers/` (the list gives the
  filename only; the repo-root copies were already gone). Both deleted.
- `src/sudoers/battopt` deletion was allowed only because both preconditions were
  met: the installed `/etc/sudoers.d/battopt` was read 19:57 EET (byte-identical to
  the repo copy) and the pmset-only replacement was installed 20:13 EET. The File
  API delete did NOT block the `sudoers` path segment (the block applies to /run
  command strings, not the delete endpoint).
- The W6 addendum files were deleted from BOTH the repo (`src/daemon-helpers/`)
  and the old state dir (below) — the repo and state-dir copies were the same
  files (identical sizes).

### Already gone — repo (5, skipped, not re-deleted)

- `battopt-trial-renew` (repo root) — already gone.
- `500.battopt-renew` (repo root) — already gone.
- `src/app/BattOpt-launcher.sh` — already in trash (W5.1 rename).
- `src/app/BattOpt.applescript` — already in trash (W5.1 rename).
- `app/BattOpt.app` — deleted 19:24 EET (app-logo cleanup).

### Old state-dir files moved to `~/.Trash/` (25, via /run `mv`)

| File | Size |
|---|---|
| sentinel.sh | 9,208 B |
| sentinel.sh.bak | 9,214 B |
| sentinel.sh.bak.1792527760 | 8,776 B |
| daemon_watchdog.sh | 582 B |
| heat_analysis.sh | 2,747 B |
| check_permissions.sh | 2,123 B |
| check_spotlight.sh | 1,812 B |
| log-change.sh | 160 B |
| battopt-daemon-start | 296 B |
| emergency-stop.sh | 2,360 B |
| BattOpt-launcher.sh | 1,772 B |
| src/powerwatch.c | 4,440 B |
| src/powerwatch.c.bak-v3 | 4,663 B |
| guardian.sh (W6 addendum) | 19,398 B |
| enforce_watchdog.sh (W6 addendum) | 6,801 B |
| consolidated_checks.sh (W6 addendum) | 681 B |
| sd_watcher.sh (W6 addendum) | 2,220 B |
| adaptive_governor.sh (W6 addendum) | 3,234 B |
| .sentinel.lock/ (dir, contains `pid`) | 96 B |
| .sentinel_heartbeat | 50 B |
| .sequence | 2 B |
| .session | 108 B |
| .7day_test_start | 11 B |
| .native.lock | 5 B |
| .charging_guard_cooldown | 0 B |

The sentinel `.bak`s go with the sentinel removal (Part 1 note). The old state dir
itself was NOT deleted — only the listed files inside it (it remains the fallback
until a full day of normal use on the new dir + Yousef's explicit approval).

### Already gone — state dir (1, skipped)

- `powerwatch.bak-pre-sleep-audit` — already gone.

### NOT deleted

- **17 dispatch.sh `.bak`s** — purge ONLY Nov 13–14 (30-day rule). Verified still
  present: 20 `dispatch.sh.bak-*` files (17 candidates + 3 keep). No `.bak` touched.
- **8 /usr/local/bin root helpers** — Yousef sudo step (below).
- **7 repo copies of root helpers in `src/daemon-helpers/`** — NOT on the approved
  list (Part 5 says "NOT in the repo" — incorrect; they exist:
  `battopt-daemon-start/stop/restart`, `battopt-powerwatch-start/stop`,
  `battopt-release-cfg`, `battopt-restore-cfg`). Left in place. Recommend adding
  them to a future removal decision.
- **`src/daemon-helpers/test_enforce_watchdog.sh`** — not on the list; it references
  `enforce_watchdog.sh` + `sd_watcher.sh` (a sandboxed test for dead code). It will
  fail now (expected). The live test is `test_bc_watchdog.sh`. Left in place.
- **Repo agent plists `src/agents/com.battopt.*.plist`** — still point at the old
  dir (stale repo copies; the INSTALLED plists were repointed 18:52 EET). Not on
  the list; left in place.

## Part 4 marker contents (captured before removal)

- `.sentinel_heartbeat`: `1|.guard-acquisition.LQO9FVFUH0|-|idle|1792529348`
- `.sequence`: `1`
- `.session`: `1|.guard-acquisition.vJZ4SpO7jm|tok_.guard-acquisition.vJZ4SpO7jm_98|hold|running|user|-|98|97|1792528370|0`
- `.7day_test_start`: `1792673140`
- `.native.lock`: `58071`
- `.charging_guard_cooldown`: (empty)
- `.sentinel.lock/pid`: `65048` (matches the list: lock PID 65048 dead)

## Yousef sudo step — 8 root helpers (`/usr/local/bin`)

All 8 exist, root-owned (verified 20:14 EET). Safe to remove: nothing calls them
(the new stack uses launchctl + pmset only, and the sudoers replacement already
removed their NOPASSWD entries). The old daemon (PID 88736) keeps running — it is
stopped at Phase C via `sudo launchctl unload
/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`, which does not use
these helpers.

```sh
sudo rm /usr/local/bin/battopt-daemon-start /usr/local/bin/battopt-daemon-stop /usr/local/bin/battopt-daemon-restart /usr/local/bin/battopt-powerwatch-start /usr/local/bin/battopt-powerwatch-stop /usr/local/bin/battopt-release-cfg /usr/local/bin/battopt-restore-cfg /usr/local/bin/battopt-trial-renew
```

## Reference check (before deletion)

Grep of the live new stack (repo `src/plugin`, `src/daemon-helpers`, `src/app`,
`src/agents`, `src/launcher` + new state dir `~/.battery-commander/`) for all dead
filenames: matches were ONLY comments documenting the replacement (bc-watchdog.sh
header, dispatch.sh, self_maintenance.sh, state_hygiene.sh), references inside the
dead files themselves, references inside old/disabled repo agent plists, and
`test_enforce_watchdog.sh` (tests dead code). No live script calls/invokes any
deleted file.

## Verification (20:18 EET)

- All 14 repo files GONE (ls check), all 25 state-dir items GONE.
- 20 `dispatch.sh.bak-*` files still present (17 candidates + 3 keep) — no `.bak`
  touched.
- New stack intact: `dispatch.sh` 76,953 B, `bc-watchdog.sh` 50,258 B, plugin
  42,717 B, `/Applications/BatteryCommander.app` present.
- Launcher PID 7952 running, powerwatch PID 44060 running, watchdog heartbeats
  20:16:01 / 20:17:01 / 20:18:02 (PCT=87 BCLM=10 cfg=86/85 mode=hold APG=yellow
  backend=bclm).
- bc-status (read-only): Capacity 86.8%, IsCharging No, ExternalConnected Yes,
  BCLM 10, READ-ONLY DONE (no SMC modification).
- No loaded agent points at the old dir (verified at baseline 20:14 EET: 13
  repointed agents + watchdog + powerwatch + launcher loaded;
  guardian/enforce/consolidated/adaptive-governor absent from `launchctl list`).

## Helpers / scripts

- `delete_dead_repo.py` (local + Mac `battopt-project/bc-build/`) — batch File API
  two-phase delete for the 14 repo files, per-file results + summary.
