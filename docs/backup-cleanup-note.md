# Backup cleanup — 18 old-app backups + installer copy

**Date:** 2026-11-10. **Status: 17 moved to Trash, 2 root-owned remain (Yousef sudo step).**
**Approval:** Yousef 19:34 EET (tapped "أيوه، امسح الـ 18 backup + نسخة الـ Installer").

## 1. Before — inventory re-verified (GET /info OK first)

All 18 backup dirs + the installer copy existed. Ownership re-verified (not relying on the earlier inventory):

- Root-owned (2): `BattOpt.app.backup-20261021-152223` (root admin, 992K), `BattOpt.app.backup-20261023-031800` (root wheel, 104K).
- User-owned (16): all Yousef wheel, 1.1M each.
- Installer copy: `/Users/Yousef/BattOpt-Installer/BattOpt.app`, Yousef staff, 1.0M.

## 2. Results — moved to `~/.Trash/` (recoverable, via /run mv)

16 backup dirs MOVED (1.1M each):

- 20261023-002913, 010428, 011900, 013700, 015116, 015132, 023227, 024045, 024600, 024737, 172546, 181326, 184152, 185151, 194438, 20261025-193056.

Installer copy MOVED (1.0M): `/Users/Yousef/BattOpt-Installer/BattOpt.app` → `~/.Trash/BattOpt.app`.
The BattOpt-Installer folder itself was NOT deleted (intact, 11 entries).

Method: /run `mv` to `~/.Trash/` (the File API cannot reach /Applications — it is outside the allowed root; `rm -rf` is blocked by the /run safety policy). Per-item loop with MOVED/FAILED echo.

## 3. FAILED — 2 root-owned (permission denied, as expected)

- `/Applications/BattOpt.app.backup-20261021-152223` (root admin, 992K) — `mv: Permission denied`
- `/Applications/BattOpt.app.backup-20261023-031800` (root wheel, 104K) — `mv: Permission denied`

Yousef sudo step (he runs these himself in Terminal — move to Trash, recoverable):

```sh
sudo mv /Applications/BattOpt.app.backup-20261021-152223 ~/.Trash/
sudo mv /Applications/BattOpt.app.backup-20261023-031800 ~/.Trash/
```

(Permanent alternative, only if he prefers it: `sudo rm -rf` on the same two paths. Not recommended — Trash keeps them recoverable.)

## 4. Verification

- /Applications now holds exactly the 2 root-owned backup dirs (`ls -d` confirms only those two remain); no other `BattOpt.app.backup-*`.
- Installer folder intact (11 entries, Yousef staff); BattOpt.app gone ("No such file or directory").
- Trash confirmed by explicit paths (TCC blocks listing `~/.Trash/` — `ls ~/.Trash/` fails "Operation not permitted", and glob expansion fails the same way; verified each of the 16 by exact path: 1.1M each; installer copy 1.0M).
- New app untouched: /Applications/BatteryCommander.app .icns md5 `bf88d95d…` (NEW); repo app/BatteryCommander.app .icns md5 `bf88d95d…` (NEW).
- Launcher still running: PID 7952. Old daemon still enforcing: PID 88736.
- Battery (read-only bc-status): Capacity 86.8%, BCLM 10, IsCharging No, ExternalConnected Yes, Health 75.9%, Cycle 568 — unchanged.
- Watchdog ticking: heartbeats 19:33:47 and 19:34:48 — PCT=87 BCLM=10 cfg=86/85 mode=hold APG=yellow backend=bclm.

## 5. Not touched (per constraints)

- `BattOpt-CC-Release.bak-pre-consolidation-20261014-1815/` (including its app/BattOpt.app).
- Repo `src/native/BattOpt.app` (dropped native-app build artifact).
- /Applications/BatteryCommander.app + repo app/BatteryCommander.app.
- The BattOpt-Installer folder itself.
- No sudo, no launchctl, no Phase C daemon load, no commit/push, no live battery tests, no SMC writes.

## 6. What remains

- The 2 root-owned backup dirs above — Yousef's sudo step (commands in §3).
- After those two are gone: /Applications will hold no `BattOpt.app.backup-*` at all.
