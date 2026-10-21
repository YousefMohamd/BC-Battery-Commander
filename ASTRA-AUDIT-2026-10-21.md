# Astra Phase 1 Audit — 2026-10-21

## Confirmed (F1-F9)
- F1: battopt-daemon-restart missing from sudoers (REAL)
- F2: pmset duplicate in sudoers (REAL)
- F3: install.sh skips extensionless helpers (REAL)
- F4: install.sh stages nothing to /usr/local/bin (REAL)
- F5: sudoers not idempotent (REAL)
- F6: exec bits not enforced on DASH helpers (REAL)
- F7: dead-buttons false positive (RETRACTED)
- F8: LAYER3a present both sides (NEUTRAL)
- F9: 500.battopt-renew subset of F3 (REAL)

## New findings (Install gaps on fresh Mac)
1. /usr/local/bin/battopt (vendor CLI) — no repo source
2. /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist — no source
3. Only sleepmonitor.plist shipped; runtime needs guardian/acwatcher/hygiene/enforce
4. powerwatch.c never compiled/installed by install.sh
5. App bundle: install.sh assumes exists, only overwrites Mach-O
6. Extensionless helpers skipped (F3)
7. Sudoers idempotency (F5)
8. Exec bits not enforced (F6)
9. No SwiftBar presence check

## Code issues
- guardian.sh L18 + ac_watcher.sh: hardcoded /Users/Yousef paths
- arm_sleep.sh: HOME="${HOME:-/Users/Yousef}" fallback
- Many scripts: absolute /Users/Yousef paths
- StateStore default lower=80 vs dispatch default=75
- install.sh runs bash -n on Mach-O launcher (harmless)
- visudo -cf non-interactive abort semantics
- No SwiftBar version pin
- No terminal-notifier presence check

## Required install invariants (13)
1. Executable battopt at /usr/local/bin
2. Root LaunchDaemon loaded
3. >=18 user LaunchAgents loaded
4. Every DASH helper present & executable
5. Sudoers: no dup, all helpers granted
6. Plugin at ~/SwiftBar/battopt.10s.sh exec
7. BattOpt.app valid (codesign, launcher, icon)
8. powerwatch binary installed + daemon loaded
9. config matches SMC (LAST_UPPER/LOWER vs ioreg)
10. .active_mode == idle when no session
11. guardian/ac_watcher/enforce scheduled
12. All helpers respond to --help/exit 0 within 3s
13. install.sh idempotent (2nd run no-op)

## Classified by fixability
CAN FIX FROM REPO:
A. Hardcoded /Users/Yousef paths (guardian, ac_watcher, arm_sleep, ~12 more)
B. LaunchAgent plists missing from repo (guardian, acwatcher, hygiene, enforce)
C. Root LaunchDaemon plist missing from repo
D. install.sh gaps: extensionless, /usr/local/bin, exec bits, idempotency
E. sudoers: restart entry + duplicate removal
F. powerwatch.c build step in install.sh
G. install.sh: bundle/SwiftBar/terminal-notifier checks
J. StateStore default lower=80 vs dispatch=75

CANNOT FIX (external dependencies):
H. /usr/local/bin/battopt (vendor binary, closed source)
I. /Library/Application Support/battopt/ (vendor daemon)
