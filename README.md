# BattOpt Control Center

A menu bar battery charge limiter and sleep optimizer for macOS 10.15+.
Bridges the [battopt](https://battopt.buddha-path.top) CLI and
[SwiftBar](https://github.com/swiftbar/SwiftBar) into a friendly menu bar
control center with seven defense layers and self-healing logic.

---

## What It Does

- **Charge cap** — stops charging at 80-85% to extend battery lifespan.
- **Sailing Mode** — oscillates between lower and upper bounds.
- **Sleep Modes** — Normal / Presentation / Long Tasks / Travel.
- **Power Modes** — Fast Sleep / Balanced / Always Awake / Deep Only.
- **Smart Discharge** — drains the battery to a target percentage.
- **Calibration** — periodic full-cycle for accurate percentage readings.
- **Clamshell Control** — allow or block lid-closed operation.
- **Auto Cleanup** — pauses Spotlight/Photos/Time Machine when idle.
- **Proactive Alerts** — temperature, health, low battery.
- **Sleep & Battery Report** — daily summary of wake reasons and drain.

---

## Requirements

- macOS 10.15 Catalina or later (tested on MacBookPro9,1).
- [SwiftBar](https://github.com/swiftbar/SwiftBar) 1.4 or later.
- `battopt` CLI (installed separately).
- `terminal-notifier` (bundled).
- Xcode Command Line Tools (only to rebuild `powerwatch.c`).

### Installing battopt CLI

Follow the official instructions at <https://battopt.buddha-path.top>.
Binary installed at `/Library/Application Support/battopt/battopt`.

Verify:

    sudo battopt status

---

## Installation

From the release DMG:

1. Double-click `BattOpt-Installer.dmg`.
2. Drag `BattOpt.app` to `/Applications`.
3. Run the installer:

       sudo bash /Volumes/BattOpt/install.sh

The installer copies helper scripts to `~/.battopt-swiftbar/`, installs
LaunchAgents and LaunchDaemons, writes `/etc/sudoers.d/battopt-nopasswd`,
and places the SwiftBar plugin in `~/SwiftBar/`.

---

## Usage

Click the battery icon in the menu bar. The dropdown is organized as:

- **Header** — charge %, mode, health, temperature, trial days.
- **Quick Actions** — Power Mode and Sleep Mode submenus.
- **Charge Limits** — custom upper/lower, sailing toggle, gap size.
- **Battery Care** — Calibration, Clamshell Mode, Schedule.
- **System Resources** — CPU and RAM.
- **Shutdown** — clean stop with auto-restore via BattOpt.app.

All actions are one-click and idempotent.

---

## Architecture

    SwiftBar (menu bar UI)
        │
        ▼
    battopt.30s.sh  ──► dispatch.sh  ──►  30 helper scripts
        │                  │
        │                  └──► battopt binary (SMC keys)
        │
        └──► state files (~/.battopt-swiftbar/)

    powerwatch (C binary, root daemon)
        └──► sleep/wake scripts

    launchd — runs scheduled helpers every 1-60 minutes.

The **battopt binary is third-party** and controls the SMC charge keys
directly. This project wraps it; it does not replace it.

---

## Seven Protection Layers

1. **Input Validation & Persistence** — `.last_inputs`.
2. **Emergency Stop & Audit** — `emergency-stop.sh` + `.audit.log`.
3. **Auto-recovery** — `ensure_limit.sh` + `swiftbar_watchdog.sh`.
4. **Strict Backup Snapshots** — timestamped copies before edits.
5. **Self-Healing Daemon** — `self_healing.sh` every 5 minutes.
6. **Guardian Heartbeat** — `guardian.sh` every 2 minutes.
7. **Config Validator** — validates state files; auto-fixes safe corruption.

---

## Configuration Files

Runtime state lives in `~/.battopt-swiftbar/`.

| File | Purpose |
|------|---------|
| `config` | User limits (LAST_UPPER, LAST_LOWER, SAILING, SAIL_GAP) |
| `.sleep_mode` | `default` / `presentation` / `download` / `travel` |
| `.current_power_mode` | `fast` / `balanced` / `awake` / `deep` / `custom` |
| `.last_inputs` | Last dialog values |
| `.status_cache` | Cached `battopt status` (10s TTL) |
| `actions.log` | All user actions |
| `.healing.log` | Self-healing interventions |
| `.guardian.log` | Guardian heartbeat |

---

## Troubleshooting

### Menu bar shows an old percentage

    rm -f ~/.battopt-swiftbar/.status_cache

### "Charge limit is suspended"

    sudo battopt limit 85 80

### SwiftBar plugin disappears

    ~/.battopt-swiftbar/launch_swiftbar.sh

Or reopen `BattOpt.app`.

### powerwatch not running

    sudo launchctl list | grep powerwatch
    sudo launchctl load -w /Library/LaunchDaemons/com.battopt.powerwatch.plist

### Daemon not responding

    sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist
    sudo launchctl load -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist

---

## Uninstallation

    sudo bash /Applications/BattOpt.app/Contents/Resources/uninstall.sh

Or manually:

    sudo launchctl unload /Library/LaunchDaemons/com.battopt.powerwatch.plist
    sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist
    for p in ~/Library/LaunchAgents/com.battopt.*.plist; do launchctl unload "$p"; done
    rm -rf ~/.battopt-swiftbar
    rm -f ~/SwiftBar/battopt.30s.sh
    sudo rm -f /etc/sudoers.d/battopt-nopasswd
    rm -rf /Applications/BattOpt.app

---

## License

- Wrapper scripts, plugin, launcher: MIT (see `LICENSE`).
- battopt binary: third-party, proprietary; not distributed here.
- SwiftBar: MIT, separate project.
- terminal-notifier: MIT, bundled separately.

---

## Credits

- Original design and development: Yousef.
- Built on top of `battopt` by Buddha Path.
- Uses SwiftBar by Jed Fox and contributors.
- Notifications via terminal-notifier by Julien Blanchard.

## Version

Current: **v1.3.0**
Release date: 2026-10-11
Device tested: MacBookPro9,1 (MacBook Pro 15-inch mid-2012)
macOS tested: 10.15.8 (Catalina, Build 19H2036)
