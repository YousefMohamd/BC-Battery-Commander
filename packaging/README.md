# Battery Commander 1.0

A menu-bar charge-limit tool for Intel Macs: hold your battery at a
limit you choose (default 86%), with Smart Discharge, sailing mode,
sleep/power profiles, and a verified release whenever you quit.

Battery Commander is an independent, clean-room tool. It enforces the
limit in software: a small root daemon (`bc-limit`) checks the battery
once a minute and toggles the SMC charge key (BCLM) between hold and
resume. The limit percentage itself is never written to the SMC.

## Requirements — read this first

- **Intel Mac required.** Version 1 is verified on an Intel MacBook
  Pro (Mid-2012) running **macOS Catalina 10.15**. That is the only
  platform v1 claims as fully supported.
- On other Intel Macs / macOS versions the daemon probes the charge
  mechanism at runtime (BCLM → CHLS → CHWA → CHTE/CH0B·CH0C → native
  limit → adapter toggle) and reports what it found. If no mechanism
  works, the tool runs **monitor-only** and says so — it never claims
  control it does not have.
- Known platform cliffs, stated honestly:
  - Direct SMC writes are blocked by the kernel on **macOS 15.0+**,
    so on those versions the tool is monitor-only.
  - macOS 26.4+ offers Apple's own Charge Limit on Apple Silicon;
    Intel Macs never received one — which is what this tool is for.
  - This build is **unsigned** (no paid developer identity). See the
    Gatekeeper note below.

## Install

1. Drag **BatteryCommander.app** to **Applications** (use the
   Applications shortcut in this DMG window).
2. Double-click **Install Battery Commander.command**. It asks for
   your admin password **once** and installs:
   - the daemon binary to `/Library/PrivilegedHelperTools/bc-limit`
     (root-owned — this is deliberate: a root daemon must never run
     from a user-writable path),
   - its launch daemon plist to `/Library/LaunchDaemons/`,
   - a pmset-only sudoers rule to `/etc/sudoers.d/battery-commander`,
   - the helper scripts and user agents (into `~/.battery-commander/`
     and `~/Library/LaunchAgents/`).
   Setup finishes by verifying a fresh daemon tick. Re-running it is
   safe: it refreshes helpers and **never overwrites** your existing
   config, history, or logs.
3. Open **Battery Commander** from /Applications. It adds itself as a
   login item. The default limit is **86/85** (hold at 86%, resume
   below 85%); change it from the menu at any time — the last limit
   you set is the one that stays.

### Gatekeeper (unsigned build)

Because v1 is unsigned, a downloaded copy is quarantined and the
first open is blocked with "Battery Commander cannot be opened
because it is from an unidentified developer." To open it:
**right-click the app → Open → Open**. (Or: System Preferences →
Security & Privacy → "Open Anyway".) You only do this once. The same
applies to the two `.command` files in this DMG.

## Quitting = stock behaviour

Choosing **Quit Battery Commander** from the menu fully releases the
limit: the daemon disengages any discharge mode, restores normal
charging (verified by read-back), and idles. Your config is left
untouched; reopening the app resumes enforcement within a minute.

## Uninstall

Double-click **Uninstall Battery Commander.command** in this DMG.
The uninstaller **first** makes the daemon release the limit and
verifies it (BCLM read-back) — if the release cannot be verified it
removes nothing and tells you why. After a verified release it
removes the daemon, agents, sudoers rule, login item, and the app.
Your state dir (`~/.battery-commander/`) is kept by default so a
reinstall picks up your config and history; run the uninstaller from
Terminal with `--purge` to remove it too.

## Files and state

- State, config, and logs: `~/.battery-commander/`
- Daemon log: `~/.battery-commander/bc-limit-daemon.log`
- The tool's own footprint is small: the menu app uses ~54 MB RAM;
  the daemon and agents together ~0.2 MB, and the daemon runs for a
  fraction of a second once a minute.

## Support

Verified: Intel + macOS Catalina 10.15 (BCLM backend). Everything
else is probe-and-report as described above. If the menu shows a
monitor-only state, that is the tool being honest about your
machine's firmware/OS, not a bug.
