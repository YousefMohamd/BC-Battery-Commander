# BattOpt Control Center — The Deep Dive & Field Notes

**Target:** MacBook Pro 9,1 (Mid-2012), macOS 10.15.8 Catalina
**Purpose:** To explain the project architecture, the battles fought, the self-healing logic, and the field tests, in plain language.

---

## Chapter 1: The Battle Log (How we survived)

At the start of this journey, the system was in a "zombie" state:
1. **The 4-Hour Hang:** Two `shutdown` scripts were stuck in a deadlock, keeping the system in a half-shutdown state. We had to manually kill them and clear the `.user_shutdown` flag.
2. **The Dead App:** `/Applications/BattOpt.app` was a Bash script trying to act like a native Mac app. Finder refused to open it. We rebuilt it as an AppleScript Applet that silently launches the shell script.
3. **The Broken Installer:** `install.sh` was a disaster. It only deployed 1 out of 19 plists, ignored extensionless scripts (like the daemon-restart helper), and couldn't build the C-based `powerwatch` daemon. We completely rewrote it to be a true "zero-to-hero" installer.
4. **The Missing UI:** The SwiftBar plugin (the menu bar interface) was lost. We restored it to 734 lines, complete with dynamic colors and correct menus.

**AI Models in the Arena:**
- **GPT-6 Astra:** Attempted the "Sentinel Architecture" (v1.7), a complete rewrite. It failed with 25 defects, proving that over-engineering can kill a stable system. We rolled it back.
- **Claude Opus 5-5 & Sonnet 5:** Used for deep static analysis. They discovered the hidden race conditions, missing `sudoers` grants, and the exact line where the app bundle was failing.
- **Aider:** Used as the coding engine. We learned a hard lesson: Aider sometimes outputs code but fails to save it, or corrupts files with bad Python regex. We adopted a strict rule: **"Aider writes in the chat, the human executes in the terminal."**
- **MiniMax M2.1:** Brought in at the end to design the self-maintenance script.

---

## Chapter 2: Feature Set & Protection Mechanisms

### 1. Battery Charge Control (The Core)
- **Custom Limit:** Sets the upper (e.g., 85%) and lower (e.g., 80%) thresholds in the SMC.
- **Hold Mode:** Freezes the battery at the current percentage.
- **Sailing Mode:** Allows the battery to drop to the lower limit, then recharge to the upper limit, keeping the battery in a healthy cycle.
- **Calibration:** Fully discharges then charges to 100% to recalibrate the gas gauge.

### 2. Sleep & Hibernation Control
- **Hibernatemode 25:** Forces macOS to write the RAM to disk (`/var/vm/sleepimage`) and cut power to the RAM. This prevents the notorious "overnight battery drain" on old MacBooks.
- **RTW Suppression:** Disables `powernap`, `womp` (Wake on Magic Packet), and TCP keepalive to stop the Mac from waking up randomly to check for emails.

### 3. Security & Sudoers
- All background scripts run using `sudo -n` (non-interactive).
- The `/etc/sudoers.d/battopt` file is strictly locked down. It only allows specific paths (e.g., `/usr/local/bin/battopt-daemon-start`) and a highly specific `rm` command for the trial-reset script. It does *not* grant blanket root access.

---

## Chapter 3: The Self-Maintenance System (`self_maintenance.sh`)

We added a new layer of protection: a script that runs every 5 minutes via `com.battopt.selfmaintenance.plist`. It acts as a "watchdog for the watchdogs."

**What it checks:**
1. **Daemon Alive:** Runs `battopt status`. If it hangs or fails, it alerts you.
2. **SMC Hold State:** If your config says 85%, and the battery is at 85% on AC power, but the SMC is *not* holding (`NotChargingReason != 14`), it alerts you.
3. **Hung Shutdown:** Checks if `dispatch.sh shutdown` has been running for too long.
4. **Disk Space:** Ensures `/var/vm` has at least 20GB free (for the 16GB sleepimage).
5. **Process Storm:** Ensures `guardian.sh` hasn't spawned multiple runaway instances.

**How it notifies you:** It stays completely silent if everything is `[PASS]`. If something fails, it sends a macOS Notification (via `terminal-notifier`) with the exact reason.

---

## Chapter 4: Analysis of Field Test (The "Weird" Behavior)

**Observation 1: LED Flashing Green/Orange after full charge & lid close.**
- **Why:** You charged to 100%. The system config (saved in `config`) is 85/84. When you closed the lid, the system entered sleep. Upon waking, `guardian.sh` saw the battery at 100%, exceeding the 85% limit. It immediately triggered a `discharge` (Orange LED). Once it hit 85%, it triggered a `hold` (Green LED). The flashing is the physical SMC switching between "charging allowed" and "charging blocked."
- **Verdict:** This is the protection working exactly as intended.

**Observation 2: Custom Limit jumped from 85 to 100, then back to 85.**
- **Why:** You activated "Charge to 100%". The plugin wrote `100/99` into the transient state. But `guardian.sh` reads the permanent config (`85/84`). Within 2 minutes, the Guardian forced the SMC back to 85.
- **Verdict:** The Guardian successfully prevented the "100% override" from becoming permanent.

**Observation 3: Shutdown saved 100% instead of 85%.**
- **Why:** The `shutdown` action backs up the *current* `config` file. If you trigger shutdown while a transient 100% override is active, it saves the transient state as your new normal.
- **Fix Required:** We need to modify `dispatch.sh shutdown` to back up the *last known stable* config, not the transient one. (To be fixed tomorrow with MiniMax).

**Observation 4: LaunchAgents dropped to 0 after reopening the app.**
- **Why:** The `shutdown` script intentionally unloads all 18 agents (`launchctl unload -w`). When you reopened the app, the Launcher (`BattOpt.app`) did not reload them correctly. It seems the `launchctl load -w` command inside the launcher is failing silently or only loading a few.
- **Fix Required:** Modify `BattOpt-launcher.sh` to explicitly loop through all plists in `~/Library/LaunchAgents/com.battopt.*.plist` and `launchctl load` them. (To be fixed tomorrow).

---

## Chapter 5: Pending Fixes (The To-Do List for Tomorrow)

We will use MiniMax M2.1 to implement these 5 exact fixes:

1. **Icons:**
   - Discharge: Show 🔋 clearly.
   - On Battery: Keep 🔴.
2. **Remove Green UI:**
   - Remove `color=#30D158` from `Sleep Report: OPTIMIZED` and `Auto Cleanup: ON`.
3. **Remove Trial:**
   - Delete the Trial line from the plugin.
   - Remove the `Renew Trial` button.
4. **Shutdown State Bug:**
   - Fix `dispatch.sh` so `shutdown` copies `.last_stable_config` instead of the transient `config`.
5. **Launcher Agents Bug:**
   - Fix `BattOpt-launcher.sh` to properly reload all 18 agents upon app launch.

---

## Chapter 6: The Golden Rules (For Future Maintenance)

1. **Never touch `battopt` vendor binary:** It is closed-source and manages the SMC.
2. **Always use `sudo -n`:** If a script hangs on a password prompt, the system will deadlock.
3. **Bash 3.2 Only:** Do not use `declare -A` (associative arrays) or `${var,,}`.
4. **Always run `bash -n`:** Before executing any script.
5. **Verify with `verify-install.sh`:** After any major change, run this script. If it doesn't say 13/13, revert immediately.

*Documented on the night of Oct 21, 2026. Sleep well, the Mac is safe tonight.*

## Chapter 7: Morning After Report (Oct 22, 2026)

**Sleep Test Results:**
- Drain: 84% -> 71% over 9.5 hours (1.36%/hr). Success.
- DarkWake loop detected (RTC/Maintenance). This is a macOS feature, not a bug. To minimize, we cancel RTC schedules in `arm_sleep.sh`.
- Hibernatemode 25 successfully engaged.

**Fixes Applied (Oct 22):**
1. **UI Glitch:** Buttons required double-clicks due to SwiftBar's 10s refresh loop and daemon latency. Fixed by adding `sleep 1` before triggering `refresh_swiftbar` in `dispatch.sh`.
2. **Icons:** Discharge now shows 🔋, On Battery shows 🔴.
3. **Colors:** Removed bright green `#30D158` from Sleep Report and Auto Cleanup.
4. **Trial:** Removed the Trial line and "Renew Trial" button.
5. **Shutdown State:** Fixed `dispatch.sh` to restore `.last_stable_config` on shutdown, preventing transient 100% charges from becoming permanent.
6. **Launcher Agents:** Fixed `BattOpt-launcher.sh` to forcefully reload all 18 agents using `launchctl unload -w` and `launchctl load -w`.

## Chapter 8: The Path to Independence (Oct 22, 2026)

**The Vendor Dependency:**
The current system relies on a closed-source binary (`/usr/local/bin/battopt`) which has a 30-day trial. Once expired, the SMC limits stop working. 

**The Strategic Decision:**
We will not be held hostage by this license. The SMC (System Management Controller) on Intel Macs can be accessed via IOKit. Open-source tools like `bclm` and `smcutil` prove this is feasible. 

**Action Plan (v2.0):**
1. Finish the 7-Day Test using the current trial.
2. Research and compile a minimal C-based SMC writer (using `IOKit` and `AppleSMC` service) to replace the vendor's limit/charge functions.
3. Integrate the new C daemon into `src/powerwatch/` and update `install.sh` to deploy it.
4. Deprecate the `/usr/local/bin/battopt` dependency entirely.

**Current Trial Status:**
- 15 days remaining.
- The "Renew Trial" button has been restored to the menu bar as a safety net.
- 7-Day test countdown has been initialized.

**MiniMax Feedback Applied:**
- Added fallback for `.last_stable_config` in `dispatch.sh`.
- Reviewed the `trap` logic and added a 1s delay to fix UI double-click glitches.
