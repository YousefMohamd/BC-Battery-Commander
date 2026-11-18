# Battery Commander — bc-limit root LaunchDaemon: install guide

## ⚠️ STOP — READ THIS FIRST (Phase C gate)

**Loading this daemon starts REAL enforcement (`--write`). It is NOT a
routine install step.**

- The daemon runs `bc-limit --write` as root once every 60 s.
- Check the live % first (`./battopt-project/bc-build/bc-status` or
  the menu bar): if it is below the lower limit (85%), the **first
  run will write BCLM=100** (resume charging). The battery will
  charge to 86%, then bc-limit will write BCLM=10 (hold). That is the
  full enforcement cycle — **loading the daemon IS Phase C**.
- **Do NOT load the daemon without Phase C approval.** Building the plist
  (this file) and validating it is safe; loading it starts enforcement.
- If you only want to inspect or test without enforcing, do NOT load it.
  Use `bc-limit --probe` / `--dry-run` (read-only) instead.

## What this is

- **Daemon:** `com.batterycommander.bclimit` — a minimal root LaunchDaemon.
- **What it runs:** `@HOME@/Projects/BattOpt-CC-Release/battopt-project/bc-build/bc-limit --config @HOME@/.battery-commander/config --write`
  (absolute path after the `@HOME@` substitution at install time,
  as root, once every 60 s; `RunAtLoad: true`).
- **Why root:** SMC writes require root (proven in Phase B — unprivileged
  write failed, `sudo` write succeeded and was verified by read-back).
  The UI and the sleep watcher stay unprivileged; only this enforcer
  runs as root.
- **Config:** `~/.battery-commander/config` (LAST_UPPER=86,
  LAST_LOWER=85) — the canonical state-dir config (W6.1). The
  `battopt-project/bc-build/limit.conf` is dev/test only. Run the
  state-dir migration (`src/migrate-state-dir.sh`) BEFORE installing
  the daemon; bc-limit exits 1 (fail loud, no write) if the config
  is missing or invalid.
- **Logs:** `~/.battery-commander/bc-limit-daemon.log` (launchd
  stdout/stderr, rotated by cleanup_logs.sh) and
  `battopt-project/bc-build/limit.log` (bc-limit decisions).
- **Plist:** `battopt-project/bc-build/com.batterycommander.bclimit.plist`
  (validated with `plutil -lint`: OK). Label is clean
  (`com.batterycommander.bclimit`) — no `battopt` / `buddha-path`
  references anywhere (the `battopt-project/` folder name in the
  paths is the project docs folder, not a reference to the tool —
  accepted, W6.3).

## Install (the USER runs these — never the assistant)

Run from the repo root: `/Users/Yousef/Projects/BattOpt-CC-Release`

First run the state-dir migration (the plist points at
`~/.battery-commander/config`, which does not exist until the
migration runs) — see
`battopt-project/bc-build/state-dir-migration-plan.md`.

Then substitute `@HOME@` with the actual home path (launchd does
not expand `$HOME`) and install:

```sh
sed "s|@HOME@|$HOME|g" battopt-project/bc-build/com.batterycommander.bclimit.plist > /tmp/com.batterycommander.bclimit.plist
sudo cp /tmp/com.batterycommander.bclimit.plist /Library/LaunchDaemons/com.batterycommander.bclimit.plist
sudo chown root:wheel /Library/LaunchDaemons/com.batterycommander.bclimit.plist
sudo chmod 644 /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

Then **only with Phase C approval**, load it:

```sh
sudo launchctl load /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

## Verify it is running

```sh
sudo launchctl list | grep batterycommander
# expected: a line with com.batterycommander.bclimit and a PID (or 0 if idle)
```

Watch the logs (from the repo root):

```sh
tail -f ~/.battery-commander/bc-limit-daemon.log
tail -f battopt-project/bc-build/limit.log
```

Confirm enforcement is working (BCLM should flip 100 → 10 as the
battery rises to 86% and holds):

```sh
./battopt-project/bc-build/bc-candidates 2>&1 | grep -E "BCLM|CHLC"
```

## Stop / rollback

Unload (stops enforcement — bc-limit stops writing; the **last BCLM
value persists** in the SMC, so the battery stays in whatever state
it was in when you unloaded):

```sh
sudo launchctl unload /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

Remove the plist entirely:

```sh
sudo rm /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

To return to the old tool after unloading, re-apply the limit with
battopt (`battopt limit 86 85`) or set BCLM manually. Unloading does
NOT reset BCLM by itself.

## Notes

- The binary path in the plist is the **build location**
  (`battopt-project/bc-build/`). For the published tool, the binary
  will move to a standard install location (e.g. `/usr/local/bin/bc-limit`
  or the app bundle) and the plist path must be updated.
- `KeepAlive` is `false`: bc-limit runs once per invocation and exits.
  On this Mac (Intel, BCLM persists across sleep/reboot) that is
  enough. On Apple Silicon with volatile keys (CH0B/CH0C/CHTE) the
  daemon must stay alive — `KeepAlive` would be required there.
- If `launchctl load` reports "already loaded", unload first, then load.
- If the daemon fails to start, check `bc-limit-daemon.log` and
  `limit.log` for the error; the most common cause is a wrong binary
  path or wrong ownership/permissions on the plist (must be
  `root:wheel`, `644`).

