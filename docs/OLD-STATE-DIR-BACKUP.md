# Old State Directory — BACKUP (do not delete without Yousef's approval)

**Location:** `~/.battopt-swiftbar/` (the pre-migration state directory).
**Status:** KEPT as a backup. NOT deleted. (Yousef's decision, 2026-11-11 17:26 EET: keep the old folder as a backup, with no effect on the running system, and a marker in the project so anyone who works on it knows there is a copy to look at.)
**Superseded:** 2026-11-10 17:50 EET — the state was migrated to `~/.battery-commander/` (25 files, md5-verified).
**New state dir:** `~/.battery-commander/` — this is the live directory. All agents, scripts, and the plugin use it.

## Is it inert?
Yes. No loaded agent points to it:
- The 13 repointed agents (com.battopt.* — being renamed to com.batterycommander.*) run scripts in `~/.battery-commander/`.
- The new core (watchdog, powerwatch, bclimit) uses `~/.battery-commander/`.
- The scripts' DASH fallback only reads the old dir IF `~/.battery-commander/` is missing (a safety net, not normal operation).
- The old SwiftBar plugin was removed from `~/SwiftBar/` (2026-11-10 18:32); only `battery-commander.10s.sh` remains.

## What is in it?
The pre-migration state as of 2026-11-10 17:50 EET: config (86/85, SAILING=false), flags, icons (including the old battopt.png), logs, and the old scripts. (25 items were moved to Trash on 2026-11-10 20:18 as part of the dead-file removal; the rest remains.)

## If something goes wrong
If the new state dir is lost or corrupted, this backup has the last-known-good state (config 86/85, SAILING=false). Do NOT delete it without Yousef's explicit approval. To restore from it, copy the needed files to `~/.battery-commander/` (do not just rename the directory — the new dir is the live one).

**Date:** 2026-11-11.
