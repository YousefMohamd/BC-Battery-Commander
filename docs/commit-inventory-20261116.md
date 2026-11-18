# Commit Inventory — 2026-11-16

**Status: PREPARATION ONLY.** Read-only `git status` taken
2026-11-16 ~15:58 EET. Nothing staged, nothing committed. This
document is the plan Yousef approves (one tap) before the local
commit step runs. Push/publish stays LAST, separately gated.

## 0. Working-tree totals (measured)

- Branch `stable-v1.6.5`, HEAD `45d8336`, **ahead of origin by 54
  commits** (unpushed — unchanged by this inventory).
- `git status --porcelain`: **187 entries** = **41 deleted +
  35 modified + 111 untracked lines**.
- Tracked diff vs HEAD: **76 files changed, 4,380 insertions,
  4,554 deletions**.
- Of the 111 untracked lines, **75 are `.pre-*` backup files**
  and one is a whole directory (`battopt-project/`, 560 files).
  Real new source paths: **35 lines** (grouped in §3).
- `battopt-project/bc-build/` alone holds **521 files / 20 MB**:
  152 `.pre-*` backups, 65 runtime logs/JSONL/episode files, 16
  compiled `bc-limit` binaries, 2 `__pycache__` files, and the
  substantive sources/tests/designs grouped in §4.

## 1. Group D — deletions (41 files) — the battopt removal

All deletions are the retirement of the old product's names and
dead components; every one has a Battery Commander replacement
already live.

| Sub-group | Files | Purpose |
|---|---|---|
| `app/BattOpt.app/` bundle | 3 | Old applet bundle (Info.plist, executable, icns) — replaced by the native app |
| `src/agents/com.battopt.*` plists + `swiftbar_watchdog.sh` + `system/com.battopt.powerwatch.plist` | 15 | Old-named LaunchAgents — renamed equivalents are the untracked `com.batterycommander.*` set (§3) |
| `src/app/BattOpt-launcher.sh`, `BattOpt.applescript` | 2 | Old launcher — replaced by `BatteryCommander-*` |
| `src/daemon-helpers/` retired helpers | 17 | `guardian.sh`, `enforce_watchdog.sh`, `consolidated_checks.sh`, `sd_watcher.sh`, `charge_upper_watcher.sh`, `charging_guard.sh`, `adaptive_governor.sh` (consolidated into `bc-watchdog.sh`); the `battopt-daemon-*` / `battopt-*-cfg` / trial-renew scripts (the closed daemon is gone since Phase C); `500.battopt-renew`; the old `test_enforce_watchdog.sh` |
| `src/launcher/main.c`, `src/plugin/battopt.10s.sh`, `src/swiftbar-plugin/battopt.15s.sh`, `src/sudoers/battopt` | 4 | Old launcher source, old plugins, old sudoers — all replaced |

## 2. Group M — modifications (35 files) — the reworked layer

| Sub-group | Files | Purpose |
|---|---|---|
| `src/daemon-helpers/*.sh` | 29 | The surviving helper layer reworked across W0–W6, the wrapper consolidation, charge/discharge/calibration builds, hardening, APG fixes and the full-fix session (`dispatch.sh` is the core: bc_apply_limit, sessions, last-state-wins) |
| `src/plugin/display_state.sh` | 1 | State classification incl. the 2026-11-16 discharge-mode icon fix |
| `src/powerwatch/powerwatch.c` | 1 | Sleep/wake watcher, current build |
| `src/verify-install.sh` | 1 | Install verification (12 checks) |
| `src/app/build-app.sh` | 1 | Legacy build script, updated |
| `tests/` (`dispatch_helpers.bats`, `test_power_saver_profiles.sh`) | 2 | Repo-level tests, updated |

## 3. Group N — new source files (35 untracked lines) — the additions

| Sub-group | Files | Purpose |
|---|---|---|
| `src/agents/com.batterycommander.*.plist` | 16 | The renamed agent set: acwatcher, hygiene, log-cleanup, morning-report, pmsetcheck, powerwatch, predictive, process-monitor, self-healing, selfmaintenance, sleepmanager, sleepmonitor, swiftbar-watchdog, wakeanalyzer, **watchdog**, **watchdogsentinel** |
| `src/app/` Swift app | 10 | `main.swift`, `AppDelegate.swift`, `MenuModel.swift`, `StatusProvider.swift`, `Shell.swift`, `Housekeeping.swift`, `Info.plist`, `build-app-native.sh`, `BatteryCommander-launcher.sh`, `BatteryCommander.applescript` — the standalone menu-bar app (Stages A/B sources) |
| `src/daemon-helpers/bc-watchdog.sh` | 1 | The consolidated watchdog (guardian + enforce + monitor + APG) |
| `src/plugin/battery-commander.10s.sh` | 1 | The SwiftBar plugin (retires at Stage C; stays as rollback source) |
| `src/sudoers/battery-commander` | 1 | Passwordless pmset/launchctl rules for the BC agents |
| `src/migrate-state-dir.sh` | 1 | The 2026-11-10 state-dir migration tool |
| Assets | 3 | `Battery Commander-.png` (the correct logo source, dark gradient), `assets/icons/Battery Commander.icns` |
| `app/BatteryCommander.app/` | 1 line | The installed-source app bundle (see §5 note) |
| `battopt-project/` | 1 line | 560 files — §4 |

## 4. Inside `battopt-project/` (560 files) — needs a policy decision

This folder (origin unknown — the assistant did not create it;
Yousef's standing instruction: do not delete anything in it)
holds the project's working archive:

- `00-PROMPT.md`, `01-PROJECT.md`, `02-GOAL.md` — the founding
  project documents.
- `reader/` — 9 files: the SMC reader line (v1–v6) and the
  status-prototype source + design.
- `phase0-logs/` — Phase 0 install logs **plus a 27 MB
  craft-anything-cli download (zip + extracted copy)** — a
  third-party tool archive, not project source.
- `bc-build/` — 521 files, of which the substantive core is:
  - **Daemon sources:** `bc-limit.c`, `bc-limit-v1.1.c` …
    `bc-limit-v1.6.1.c`, `bc-limit-phase-b-recon.c`,
    `bc-limit-phase-c.c`, `bc-limit-v1.4-stagec-DRAFT.c`
    (21 `.c` files across the whole folder incl. `reader/`).
  - **The daemon's LaunchDaemon plist:**
    `com.batterycommander.bclimit.plist` — its only home today
    is here; nothing of bc-limit lives under `src/`.
  - **Test suites:** the `test_*.sh` set (discharge, charge
    persistence, calibration, bc-limit matrices, gauge, ac,
    apg, watchdog, sentinel, sidecar).
  - **Verification system:** `bc-episode-tracker.py`,
    `bc-verify.py` (+ shell wrappers).
  - **Designs + build/session notes:** 59 `.md` files
    (limit-writer, discharge, charge, calibrate, verification,
    standalone-app designs; every build/deploy/session note).
  - `bc-status` and the deployed-form helper copies.

**Recommendation (for Yousef's decision, not taken here):** the
substantive bc-build core belongs in the commit — it IS the
product's daemon, tests and design record — but only after the
exclusions in §5 are stripped out of the folder, and ideally
under a top-level home (e.g. promoting bc-build's core to
`daemon/` + `tests/` + `docs/`) instead of nesting the product
inside an unexplained folder. The folder itself is never
deleted; anything not promoted stays on disk, uncommitted.

## 5. Do NOT commit — flagged with reasons

| Item | Count | Reason |
|---|---|---|
| `.pre-*` backup files in `src/`, `tests/` | 75 | Point-in-time safety copies from each deploy; already preserved in `~/.battery-commander/backups/` and bc-build. Committing them freezes 75 stale duplicates of live files |
| `.pre-*` backups inside bc-build | 152 | Same — deploy history, not source |
| Compiled `bc-limit` binaries in bc-build (incl. `bc-limit.new`, `bc-limit-phase-c`, versioned binaries) | 16+ | Build outputs; the `.c` sources are the record. (The live daemon binary stays on disk — it is the running system — it just isn't a commit artifact) |
| Runtime logs / JSONL / episode files in bc-build | 65 | Live verification data (episodes.jsonl etc.); data, not source. The live store in `~/.battery-commander/verification/` is the canonical one |
| Sandbox + backup subdirectories in bc-build | ~10 dirs | `verify-sandbox/`, `verify-deploy-test/`, `stagec-sandbox/`, `ac-test/`, `gauge-test/`, `scratch-morning-replay-20261113/`, `agent-plists-backup-20261110/`, `agent-plists-backup-20261111-rename/`, `retired-plists-20261113/`, `BatteryCommander.app.pre-consolidation-20261113/`, `__pycache__/` — working scratch and preserved backups |
| `re-work/` (inside bc-build) | 1 dir | **Reverse-engineering artifacts of the proprietary binary (disassembly). Never publish** — clean-room discipline: BC's sources describe the mechanism; the upstream binary's disassembly is not ours to ship |
| `phase0-logs/` craft-anything archive | 27 MB | Third-party tool download (zip + extracted) — not project source; the small install logs may commit with the project docs |
| `Battery Commander.png` (repo root) | 1 | The WRONG logo (79% white background; superseded 2026-11-07). Only `Battery Commander-.png` is the logo source |
| `app/BatteryCommander-applet-backup-20261114.app/` | 1 | A preserved backup of the retired applet — stays on disk, not a source |
| `app/BatteryCommander.app/` (built bundle) | 1 | **Judgment call, flagged:** the old repo DID track a built `app/BattOpt.app`. Recommendation: commit the `src/app/` sources + build script only and let the bundle be a build product (`.gitignore` already ignores `build/`); if Yousef prefers the historical pattern, commit the bundle in the app commit instead |
| `dist/BattOpt-Installer.dmg` | 1 | The OLD product's installer (Oct 7) — already git-ignored (`dist/*.dmg`); must never be mistaken for a BC artifact |
| `BattOpt-CC-Release.bak-pre-consolidation-20261014-1815/` | whole dir | A full pre-consolidation repo copy sitting in the repo root; already invisible to git via the `*.bak-*` ignore rule. Never force-add |
| `.snapshot_20261011_201058/`, `.aider*`, `.DS_Store` | — | Already git-ignored; listed so the sweep is complete |

## 6. Proposed commit sequence (recommendation — Yousef decides)

Pre-step (separate approval, before any commit): move the 227
`.pre-*` files and the §5 bc-build scratch out of the tree into
the existing backup homes, so the commit sees only source.
Nothing is deleted — relocation only, with a manifest.

Then, on `stable-v1.6.5`, in order:

1. **`Remove retired battopt components`** — Group D (41
   deletions). Self-contained; the tree builds/runs identically
   before and after (replacements are already live).
2. **`Rework the helper layer for Battery Commander`** —
   Group M (35 modifications).
3. **`Add Battery Commander agents, watchdog, plugin,
   sudoers`** — §3 agents (16) + `bc-watchdog.sh` + plugin +
   sudoers + `migrate-state-dir.sh` (20 files).
4. **`Add the bc-limit daemon, verification system, tests and
   designs`** — the substantive bc-build core from §4 (daemon
   sources + plist, suites, tracker/verifier, designs/notes,
   `bc-status`), in whatever home §4's decision gives it.
5. **`Add the standalone menu-bar app`** — `src/app/` Swift
   sources + build script (10 files; bundle per §5's call).
6. **`Add brand assets`** — `Battery Commander-.png` +
   `assets/icons/Battery Commander.icns` (2 files).

Alternative if Yousef prefers it: one single commit with
everything above — simpler, but the history loses the story
(removal → rework → daemon → app) that the published repo
should tell. The 6-commit sequence is the recommendation.

**Explicitly out of this step:** staging anything from §5,
touching `battopt-project/` beyond §4's decision, the GitHub
connection (Yousef connects it himself), and any push — push
remains the project's last step, separately approved.
