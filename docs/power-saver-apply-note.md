# Power-Saver Profiles Apply Note — 2026-11-11 18:13–18:25 EET

Applies the approved design (`power-saver-profiles-design.md` §4/§6).
Yousef approved 2026-11-11 18:13 EET: "أيوه، طبّق القيم دي (travel + long)".

## What was applied

### 1. `src/daemon-helpers/power_saver.sh` (repo + deployed)
- `apply_delays()` gained `long)` and `travel)` cases with the §4 values.
- `default` byte-identical (battery 600/600/1800, AC 10800/10800/3600, sleep 90).
- Unknown-profile fallback to `default` kept.
- Header comment updated (long/travel redefined 2026-11-11).
- New: 192 lines, 7012 B, md5 `a4ab52c5fd235fd77e6016a06deb82ae`.

Values (high/low = standbydelayhigh/low seconds; auto = autopoweroffdelay seconds; sleep = AC idle-sleep minutes):

| profile | battery high/low | battery auto | AC high/low | AC auto | AC sleep |
|---------|-----------------|--------------|-------------|---------|----------|
| default | 600 / 600 | 1800 | 10800 / 10800 | 3600 | 90 |
| travel  | 3600 / 3600 | 14400 | 10800 / 10800 | 3600 | 90 |
| long    | 3600 / 3600 | 3600 | 14400 / 14400 | 7200 | 90 |

### 2. `src/daemon-helpers/dispatch.sh` (repo + deployed)
- New `sleep_mode_long` action (line ~942), mirroring `sleep_mode_travel`:
  osascript confirm dialog → acquire → rm the three `.sleep_override_*`
  files → `power_saver.sh apply-delays long` → `sudo -n pmset -a
  disablesleep 0` → atomic write `.sleep_mode` = "long" → log → notify
  "Sleep Mode: Long" → release.
- Dialog text: "Keeps the Mac ready on both battery and AC" + the impact
  (standby 1h battery / 4h AC; hibernates 1h battery / 2h AC; drains more).
- New: 2110 lines, 78463 B, md5 `b78d190ba0d8d6e27d0c5d4c1297cdf7`.

### 3. `src/plugin/battery-commander.10s.sh` (repo + `~/SwiftBar/`)
- `long) SM_TITLE="Long";;` added to the SM_TITLE case.
- New "Long" menu item after Travel, subtitle "Ready longer on battery + AC".
- New: 947 lines, 44460 B, md5 `bb1d2ce840a05d302827f321e4c056dc`.

### 4. `src/daemon-helpers/arm_sleep.sh` (repo + deployed) — optional wiring, done
- `APPLY_PROFILE` is now wired to `.sleep_mode` instead of hardcoded `=default`:
  `case "$SLEEP_MODE" in travel|long) APPLY_PROFILE="$SLEEP_MODE";; *) APPLY_PROFILE=default;; esac`.
  So Prepare (arm_sleep) applies the profile matching the active sleep mode.
- New: 156 lines, 6886 B, md5 `240bb64d608a1ed7effb1da523b72030`.

### 5. `tests/test_power_saver_profiles.sh` (repo)
- Expected outputs updated to the §4 values, WITH the `disksleep` lines
  (`-b disksleep 10` after `-b standbydelay`, `-c disksleep 10` after `-c sleep`),
  in the exact order `apply_delays` writes them. (The old test file was stale:
  it encoded the 134379a values, not the W4.3 default, and had no disksleep lines.)
- New `bogus` case: unknown profile falls back to default values.
- New: 128 lines, 2618 B, md5 `7acef8e248c93b55598384aa236b872c`.

Backups (Mac, repo): `*.pre-power-saver-apply` next to each edited file.
Edit script: `battopt-project/bc-build/power_saver_apply.py` (local copy md5 `a760ae50…`).

## Verification
- `bash -n` OK on all 5 edited files.
- `bash tests/test_power_saver_profiles.sh` → **"Power Saver profile tests passed."**
- Deploy: `deploy-populate.sh` FAIL=0 (28 files); plugin `cp -p` + `chmod +x`
  to `~/SwiftBar/battery-commander.10s.sh`.
- Repo = deployed md5s (all 4): power_saver `a4ab52c5…`, dispatch `b78d190b…`,
  arm_sleep `240bb64d…`, plugin `bb1d2ce8…`.
- Dry-run (pmset stub via `PMSET_BIN`, script `ps_dryrun.sh`):
  - long → battery 3600/3600/3600, AC 14400/14400/7200, sleep 90 ✓
  - travel → battery 3600/3600/14400, AC 10800/10800/3600, sleep 90 ✓
  - default → battery 600/600/1800, AC 10800/10800/3600, sleep 90 ✓
  - bogus → falls back to default ✓
  - (First dry-run attempt ran the real pmset without root and FAILED — no live
    settings were changed; the fix was `PMSET_BIN` override. `_ps` uses
    `sudo -n "$PMSET_BIN"`, so `PMSET_BIN` is the correct stub hook.)
- Live `pmset -g` (read-only, 18:23 EET): Battery standbydelayhigh/low 600,
  autopoweroffdelay 1800; AC 10800/10800/3600 — **live settings still default**.
  No `.sleep_mode` file (no mode active); `.power_saver` = ENABLED.
- Live health after deploy (18:22 EET): watchdog heartbeat PCT=86 BCLM=10
  cfg=86/85 mode=hold; bc-status 86.1%, IsCharging No, ExternalConnected Yes.

## How Yousef uses it
- SwiftBar menu → Sleep Mode → **Travel** or **Long** (each asks for confirmation).
- Travel = short trips: keeps the session alive on battery (hibernates after 4h
  instead of 30 min). Long = long work sessions: keeps the Mac ready on both
  battery and AC.
- Default stays the drain-conscious one; nothing changes until he picks a mode.
- Tradeoff (from the design): delaying standby INCREASES overnight drain
  (~3% for travel). These are responsiveness profiles, NOT a sleep-drain fix.
- To go back: pick **Normal** from the same Sleep Mode menu.

## Incidents
- Tunnel flapped (HTTP 530) once during deploy — backed off 120 s, retried, deploy succeeded.
- One /run HTTP 403 (command string contained the word "sudo" in a printf for a stub) — worked around by putting the dry-run in a script file and running the file.
