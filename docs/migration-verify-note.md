# Post-migration verification note — migration plan steps 3–4

**Date:** 2026-11-10 (verify ~17:53–17:57 EET). **Verdict: MIGRATION VERIFIED.**
The real migration (17:50:57 EET, copied=25, failed=0) is confirmed working:
the new dir `~/.battery-commander/` is the live state dir, `verify-install.sh`
passes except for not-yet-installed deploy components, and the plugin renders
correctly from the new dir. Nothing went live in this task: no agent/daemon
install or load, no plugin install, no deletions, no sudo, no Phase C, no
live battery test, no SMC write.

## 1. verify-install.sh — step 3 (run 17:53 EET)

Full log: `battopt-project/bc-build/verify-install-2026-11-10.log`
(903 B, md5 `78186358…`, local copy md5-identical).
Result: **8 PASS, 2 FAIL (out of 10). Exit 1.**

| # | Check | Result | Classification |
|---|---|---|---|
| 1 | BC binaries executable in bc-build (bc-status, bc-limit, bc-candidates) | PASS | — |
| 2 | BC LaunchDaemon plist exists and lints (com.batterycommander.bclimit) | PASS | — |
| 3 | BC LaunchDaemon loaded state | INFO: not loaded | Expected until Phase C approval |
| 4 | All 17 user LaunchAgents installed and loaded | PASS | Old com.battopt.* agents still live (deploy has not disabled them) |
| 5 | All .sh scripts in `~/.battery-commander` executable | PASS | Vacuous — no .sh files in the new dir (scripts do not migrate) |
| 6 | sudoers /etc/sudoers.d/battopt | INFO: not readable without sudo | Expected (decision 8 still owed) |
| 7 | SwiftBar plugin `~/SwiftBar/battery-commander.10s.sh` | **FAIL: missing** | **Expected — not installed yet (deploy step)** |
| 8 | Battery Commander.app bundle | INFO: "not yet built (W5.1)" | Expected — see finding 4 (stale wording; bundle IS built in the repo, only /Applications install is pending) |
| 9 | powerwatch binary `~/.battery-commander/powerwatch` | **FAIL: missing** | **Expected — not installed yet (deploy step; agent plist expects it at `@HOME@/.battery-commander/powerwatch`, verified by grep)** |
| 10 | config parses with LAST_UPPER/LAST_LOWER | PASS | New-dir config, canonical 86/85 |
| 11 | .active_mode = hold | PASS | New-dir state file |
| 12 | bc-status returns output (Capacity line present) | PASS | Live read, read-only |
| 13 | no dispatch.sh shutdown process running | PASS | — |

No unexpected failures. Both FAILs are not-yet-installed deploy components.

## 2. Plugin smoke test — step 4 (run 17:55 EET)

Full log: `battopt-project/bc-build/plugin-smoke-2026-11-10.log`
(12,463 B, 155 lines, md5 `c80163a1…`, local copy md5-identical).
Run: `bash src/plugin/battery-commander.10s.sh` (see finding 1 for why
`bash` was needed). Exit 0, ~13 s.

Rendered (live battery at render: **87.4%, hold, BCLM=10, ExternalConnected
Yes, Health 75.9%, Cycle 568** — bc-status, read-only):

- Top line: `🔌 87%` white (hold on AC) — correct for BCLM=10 + AC.
- `Charge: 87%`, `Mode: Holding at 87%`, `Health: 75% - 568 cycles`,
  `Temperature: 30°C`, `Backend: bclm` — all match bc-status/ioreg.
- `Custom Limit — 86% / 85%` (config read from the NEW dir).
- `Remove Hold (return to 86/85%)` (W6.3 label fix present).
- `BC limit daemon: not loaded (Phase C)` and `Services: 0 agents loaded`
  (BC agents — none installed yet; honest status).
- Sailing range 85% ↔ 86% (1% gap), position at upper, 76 transitions —
  from the migrated `.sailing_state` / `.sailing_history`.
- Power Saver ENABLED, Power Nap OFF, Wake on Network OFF, TCP Keep-Alive
  OFF — from live pmset.
- **Zero `battopt` references in the render** (grep count 0).
- **Zero errors** (no "error" / "not found" / "No such file" / "command
  not found" in the output).
- **No trial UI.**
- All menu `bash=` paths point at `/Users/Yousef/.battery-commander/dispatch.sh`
  (the new dir — see finding 2; render only, no action was clicked).
- Render cache writes landed in the NEW dir, user-owned:
  `.status_cache` (305 B), `.daemon_fail_count` (2 B, "0"),
  `.last_icon` (5 B) — all 17:55 EET. No `actions.log` entries (correct:
  render only, no menu action ran).

## 3. Old dir untouched (re-checked after verification)

- Entry count still **95** (before/after migration).
- `config` md5 identical old↔new: `07be808a4000b7bb77fa6669be853421`.
- The old live system keeps running off the old dir; the new dir is the
  BC live dir from here on (DASH fallback resolves new-first).

## 4. Findings (none block the migration; all are deploy checklist items)

1. **Plugin repo copy is not executable** (`-rw-r--r--`, File API transfer
   artifact — same as the migration script was). The first direct run
   failed exit 126 (`Permission denied`); the smoke test ran via `bash`.
   Deploy install to `~/SwiftBar/` must `chmod +x` the plugin.
   (`display_state.sh` and `verify-install.sh` in the repo ARE +x.)
2. **Menu actions point at `~/.battery-commander/dispatch.sh`, which does
   not exist yet.** Scripts do not migrate by design (migration plan);
   they deploy from the repo. The render works because `display_state.sh`
   falls back to the repo copy (`src/plugin/display_state.sh`), but menu
   actions will fail until the deploy step populates the new state dir
   with the BC scripts (`dispatch.sh`, `display_state.sh`,
   `state_guard.sh`, …) from the repo. Deploy checklist item.
3. **`state_guard.sh` is absent in the new dir** (same cause as 2). The
   plugin sources it with `2>/dev/null`, so session detection silently
   falls back to `ACTIVE_MODE=idle` (`read_effective_session` undefined).
   The rendered mode is still correct (it comes from BCLM via
   `display_state.sh`), but session detection is degraded until the
   deploy script-population step (finding 2) runs.
4. **verify-install.sh INFO wording is stale:** `Battery Commander.app
   bundle: not yet built (W5.1)`. The bundle IS built in the repo
   (`app/BatteryCommander.app`, W5.1 + icon task); only the
   `/Applications` install is pending. INFO classification is correct;
   the message should say "not installed in /Applications". Cosmetic —
   left as-is (not a failure; fix opportunistically in deploy prep).

## 5. Verdict

**MIGRATION VERIFIED.** Steps 3–4 of the plan pass: verify-install.sh
resolves DASH to the new dir and passes every check that can pass before
deploy; the plugin renders the correct hold/86/85 state from the new dir
with no errors and no battopt references. Remaining deploy work is
unchanged (W6 CONDITIONAL PASS blockers): populate the new state dir with
BC scripts + powerwatch binary, install the plugin (chmod +x) and the
watchdog + powerwatch agents + bc-limit daemon (Yousef's sudo steps),
disable the 3 old `com.battopt.*` agents, sudoers verification (decision
8), dead-file removal at deploy (approved 17:46 EET — .baks purge
Nov 13–14), Phase C (rejected unless necessary). Old dir deleted only
after a full day of normal use on the new dir + Yousef's explicit approval.
