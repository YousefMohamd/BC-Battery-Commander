# BattOpt Control Center — Future Development Log

**Last Updated:** 2026-10-08
**Current Version:** v1.2.0 (uncommitted)
**Device Tested:** MacBookPro9,1 + macOS 10.15.8 Catalina

---

## Part 1: Uncommitted Features (Since v1.1.0)

The following features were built after v1.1.0 was published and are not yet in a release:

### 1. Battery-Aware Hibernate
- **File:** `~/.battopt-swiftbar/adaptive.sh`
- **LaunchAgent:** `com.battopt.adaptive.plist`
- **Interval:** Every 5 minutes
- **Logic:** Battery < 25% → hibernatemode 3; Battery ≥ 30% → hibernatemode 25
- **Purpose:** Prevent Hibernate File corruption

### 2. Post-Update Recovery
- **File:** `~/.battopt-swiftbar/pmset_check.sh`
- **LaunchAgent:** `com.battopt.pmsetcheck.plist`
- **Interval:** Daily at 10:00
- **Logic:** Verify pmset values; restore if drifted
- **Purpose:** Recover after macOS updates

### 3. Temperature Guard
- **Location:** Inside SwiftBar plugin
- **Interval:** Every 30 seconds (via plugin refresh)
- **Logic:** Alert at ≥ 42°C; reset at < 38°C
- **Purpose:** Warn before heat damage

### 4. SwiftBar Plugin (15s → 30s)
- **Change:** Reduced refresh rate
- **Impact:** CPU 0.33% → 0.16%
- **Trade-off:** Slower UI response

### 5. Pre-Sleep Cleanup
- **File:** `~/.battopt-swiftbar/pre_sleep_cleanup.sh`
- **Purpose:** Pause Spotlight, iCloud Photos, Time Machine
- **Trigger:** Manual (or via SleepWatcher)

### 6. Post-Wake Restore
- **File:** `~/.battopt-swiftbar/post_wake_restore.sh`
- **Purpose:** Resume paused services
- **Trigger:** Manual (or via SleepWatcher)

### 7. Sailing Tracker
- **File:** `~/.battopt-swiftbar/sailing_tracker.sh`
- **LaunchAgent:** `com.battopt.sailing.plist`
- **Interval:** Every 5 minutes
- **Purpose:** Record battery transitions within sailing range
- **Output:** `.sailing_state`, `.sailing_history`

### 8. Sleep Report Enhancement
- **Location:** Inside SwiftBar plugin
- **Content:** Deep Hibernate status, Hibernate delay, Current pmset state

### 9. Low Battery Alert (61%)
- **Location:** Inside SwiftBar plugin
- **Logic:** Alert when on battery and ≤ 61%
- **Cooldown:** 30 minutes

---

## Part 2: Commercial Roadmap (v2.0 - v3.0)

### v2.0.0 (Medium-Term — 2-4 weeks)

#### 2.1 Native .app (Replace SwiftBar)
- **Effort:** 8 hours
- **Stack:** Swift + AppKit
- **Why:** Remove SwiftBar dependency
- **Deliverable:** NSStatusItem menu bar with all 26 features
- **Trade-off:** More code to maintain

#### 2.2 Protection Layer 5: Watchdog
- **Effort:** 2 hours
- **Purpose:** Monitor core daemon every 30 seconds
- **Action:** Auto-restart if unresponsive
- **Logs:** All incidents to `/Library/Logs/battopt/watchdog.log`

#### 2.3 Protection Layer 6: Command Validation
- **Effort:** 2 hours
- **Purpose:** Pre-execution state check
- **Action:** Abort if inconsistent
- **Prevents:** Cascading failures

#### 2.4 Branding
- **Effort:** 4 hours
- **Components:**
  - Logo (Arabic + English)
  - Icon set (menu bar, app, notifications)
  - Naming options: "BattOpt Studio", "Battery Steward", "Charge Keeper"
  - GitHub Pages website

#### 2.5 Arabic Full UI
- **Effort:** 60 minutes
- **Scope:** All menu items, dialogs, notifications
- **Layout:** RTL for dialogs
- **README:** Arabic as primary language

### v3.0.0 (Long-Term — 2-3 months)

#### 3.1 License Key System
- **Effort:** 2 hours
- **Design:**

Server-side:
HMAC-SHA256(bundle_id + user_email + secret_key)
→ Format: BATT-XXXX-XXXX-XXXX-XXXX

Client-side:
Recompute HMAC for user's bundle_id
Compare with entered key
text

- **Storage:** `~/.battopt-swiftbar/.license`
- **Trial:** 30 days, then require key

#### 3.2 Code Obfuscation
- **Effort:** 30 minutes
- **Layer 1:** Rename variables (a, b, c)
- **Layer 2:** Remove comments
- **Layer 3:** `shc -f dispatch.sh -o dispatch.bin`
- **Layer 4:** `openssl enc -aes-256-cbc`
- **Limitation:** Reversible by determined attackers

#### 3.3 Online Validation (VPS)
- **Effort:** 4 hours
- **Stack:** Flask/FastAPI + SQLite
- **Endpoint:** `/api/validate`
- **Cache:** 30 days client-side
- **Cost:** $5-10/month
- **Benefit:** True protection, revoke capability

#### 3.4 Profile System
- **Effort:** 3 hours
- **Purpose:** Multi-user scenarios
- **Storage:**

~/.battopt-swiftbar/profiles/
├── home.json
├── work.json
├── travel.json
└── current -> home.json
text

- **Authentication:** macOS user OR license key
- **Commercial Model:**
- Basic: 1 profile
- Pro: 5 profiles
- Enterprise: unlimited + LDAP

#### 3.5 Commercial Packaging
- **Effort:** 6 hours
- **Components:**
- Code signed .app
- Notarized (Apple Developer $99/year)
- Professional installer
- Screenshots
- Gumroad integration

---

## Part 3: Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Backend | battopt CLI (MIT) | SMC communication |
| UI | SwiftBar (MIT) | Menu bar rendering |
| Notifications | terminal-notifier (MIT) | Custom icon alerts |
| Daemon | launchd | Service management |
| Scheduler | cron | Weekly trial renewal |
| Config | Shell scripts | User data |
| Logs | Plain text | Diagnostics |
| Binary | C (clang) | Fast launcher with fork() |

---

## Part 4: Protection Layers

### Layer 1: `preflight`
- Before every command
- Check daemon responsive
- Restart if slow

### Layer 2: `run_with_retry`
- On "ongoing" errors
- Force kill, retry once

### Layer 3: `hold_at_current`
- For limits
- Verify, timeout, force

### Layer 4: `force_reset.sh`
- Emergency recovery
- Kill all clients, restart daemon

### Layer 5: Watchdog (planned)
- Continuous monitoring
- Auto-recovery without user

### Layer 6: Command validation (planned)
- Pre-execution checks
- State consistency

---

## Part 5: Background Features

### Running Continuously

1. **Battery-Aware Hibernate** (`adaptive.sh`) — every 5 min
2. **Post-Update Recovery** (`pmset_check.sh`) — daily 10:00
3. **Temperature Guard** (plugin) — every 30 sec
4. **Sailing Tracker** (`sailing_tracker.sh`) — every 5 min
5. **Trial Auto-Renew** (cron) — weekly
6. **Proactive Notifications** — on conditions
7. **Daemon KeepAlive** (launchd) — on crash

### Triggered on Events

1. **Pre-Sleep Cleanup** — before sleep (manual/SleepWatcher)
2. **Post-Wake Restore** — after wake (manual/SleepWatcher)
3. **Low Battery Alert** — on battery ≤ 61%
4. **Critical Battery Alert** — on battery ≤ 20%
5. **Temperature Alert** — on battery temp ≥ 42°C

---

## Part 6: Lessons Learned

### What Worked
- SwiftBar as UI layer (fast development)
- Bash for logic (portable, transparent)
- launchd for daemon (reliable)
- terminal-notifier for icons
- fork() in C launcher (non-blocking)

### What Didn't Work
- Swift native (SDK limitations on Catalina)
- pywebview (dependency conflicts)
- Platypus (limited UI)
- Tkinter (poor UX)
- Direct SMC key manipulation (risky)

### Key Decisions
- Minimum viable stack
- Shell over compiled for logic
- Compile only launcher (needs fork)
- Apple native frameworks (launchd, pmset)
- Integrate existing (battopt, SwiftBar)

---

## Part 7: Never To Do (Final List)

The following items are permanently rejected. Do not revisit:

| # | Item | Reason |
|---|------|--------|
| 1 | Fast Charging Mode | Physics impossible |
| 2 | Zone Awareness UI | No battery benefit |
| 3 | Smart Resume Calibration | Rare use case |
| 4 | Android Phone Integration | Out of scope |
| 5 | Global Keyboard Shortcuts | SwiftBar doesn't support |
| 6 | History Graph | Not necessary |
| 7 | Export Logs CSV | Rare |
| 8 | Bluetooth Battery Monitor | Out of scope |
| 9 | Smart Plug Integration | No benefit |
| 10 | Mac App Store Distribution | Apple ToS |
| 11 | Physical AC Disconnect | Opposite of goal |
| 12 | USB Hub Automation | No benefit |

---

## Part 8: Sailing Mode Reality (Important)

### Intel vs Apple Silicon

| Behavior | Intel Mac (yours) | Apple Silicon |
|----------|-------------------|---------------|
| At upper limit | Stops charging, runs from AC | Stops charging, may run from battery |
| Battery behavior | Static at 85% | Drifts down to 80% |
| Sailing visible? | No (mostly static) | Yes (cycling) |
| Transitions per day | 0-2 | 4-8 |

### Why Intel Doesn't Cycle

- SMC opens AC MOSFET when limit reached
- Power flows from AC directly to system
- Battery isolated (no charge, no discharge)
- Result: static hold at upper limit

### Verification

```bash
cat ~/.battopt-swiftbar/.sailing_history

If empty or few entries → normal for Intel.
If many entries → something unexpected.
Part 9: Commercial Viability
Target Markets

    Individual MacBook owners (5-8 years old)

    Small businesses with legacy Macs

    Battery-conscious users

    Privacy-focused (no telemetry)

Pricing
Tier	Price	Features
Free	$0	All 26 features (MIT)
One-time	$12.99	Lifetime + updates 1 year
Pro	$19.99	+ Support 1 year
Enterprise	$49.99	+ 10 devices + Priority
Protection Strategy

    Layer 1-2: Free tier

    Layer 3-4: Paid tier

    Layer 5-6: Enterprise

Part 10: Technology References
Primary Sources

    Apple pmset man page

    Apple launchctl man page

    Apple Power Management Guide

    battopt documentation

    SwiftBar plugin documentation

Verified Facts

    Hibernatemode 25 supported since macOS 10.10

    Safe on Catalina (verified on MacBookPro9,1)

    Crucial MX500 TBW: 360 TB

    Current write rate: ~1.9 TB/year

    5-year SSD usage: ~2.7% of TBW

Document Version: 1.0
Created: 2026-10-08
Status: Planning
Next Review: After v1.2 release


---

## Auto Cleanup (Idle-Triggered) — v1.3.0

### Purpose
Automatically pause background services (Spotlight, iCloud Photos, Time Machine, VLC)
when the system is idle for 15 minutes, reducing power consumption and preventing
unnecessary wakeups.

### How It Works
- `sleep_monitor.sh` runs every 30 seconds
- Checks system idle time via `HIDIdleTime`
- If idle > 15 minutes → runs `pre_sleep_cleanup.sh`
- If user returns (idle < 1 min) → runs `post_wake_restore.sh`

### What It Pauses
| Service | Action | Effect |
|---------|--------|--------|
| Spotlight | `mdutil -a -i off` + SIGSTOP mds | No indexing |
| iCloud Photos | SIGSTOP photolibraryd | No uploads |
| Time Machine | `tmutil stopbackup` | No backup |
| VLC | SIGSTOP (if running) | Media paused |

### Controls (from SwiftBar)
- **🧹 Auto Cleanup: ON/OFF** — Toggle automation
- **Run Cleanup Now** — Manual trigger
- **Restore Services** — Manual restore
- Shows current idle time and last cleanup state

### Why 15 Minutes?
- Allows reading, watching, or thinking without triggering
- Matches typical "user walked away" pattern
- Aligns with macOS sleep timeout behavior

### Safety
- Only runs when Power Saver is ON
- Only runs when user explicitly enabled Auto Cleanup
- Reverts automatically when user returns
- Can be disabled from SwiftBar menu

### Files
- `~/.battopt-swiftbar/sleep_monitor.sh`
- `~/.battopt-swiftbar/pre_sleep_cleanup.sh`
- `~/.battopt-swiftbar/post_wake_restore.sh`
- `~/Library/LaunchAgents/com.battopt.sleepmonitor.plist`
- `~/.battopt-swiftbar/.auto_cleanup` (state flag)


## v1.3.0 — Immediate (Next Session)

### 1. Keep Awake on AC Toggle
**Problem:** Current Power Mode splits AC/Battery but doesn't allow "never sleep on AC".
**Solution:** Toggle button in Quick Actions:
- ON: `pmset -c sleep 0 displaysleep 0 disksleep 0`
- OFF: Reapply current Power Mode
- State file: `.keep_awake`

### 2. Version Unification
- Plugin header: 13.0 → 1.2.0
- Info.plist: 1.0.0 → 1.2.0
- README: 1.3.0 → 1.2.0
- GitHub tag: v1.2.0

### 3. README Rewrite
- Arabic version for personal use
- English version for GitHub
- Screenshots of menu

### 4. .gitignore Cleanup
Exclude:
- `.last_inputs`
- `actions.log`
- `.healing.log`
- `.cleanup.log`
- `backups/`
- `.status_cache`, `.wake_cache`, `.usb_cache`
- `.paused`, `.disabled`, `.user_shutdown`

---

## v2.0 — Performance & Consolidation

### 1. Unified Daemon
Replace 4 LaunchAgents (sailing, adaptive, ensure-limit, system-guard) with 1:
- Single timer (10 min)
- Shared config read
- Reduces spawns from 4 to 1

### 2. Event-Driven Architecture
Replace polling with IOKit notifications:
- Battery state change → trigger
- Power source change → trigger
- Lid state change → trigger
- Eliminates periodic wakeups

### 3. Plugin Performance (further)
Current warm: 0.93s. Target: < 0.3s.
- Precompute values in daemon
- Plugin queries daemon (socket/IPC)
- No shell parsing on each run

### 4. Native .app
Full SwiftUI:
- Graphical settings
- Charts (battery history, temp, drain)
- No SwiftBar dependency

---

## v3.0 — Advanced Features

### 1. Anomaly Detection
- Detect unusual drain patterns
- Auto-notify user
- Suggest actions

### 2. Weekly Health Report
- Automated email/notification
- Battery trends
- Recommendations

### 3. Auto-Rollback
- If same error repeats 3 times
- Rollback to last-known-good snapshot

### 4. Multi-Mac Sync
- Sync settings via iCloud
- Personal config per machine

### 5. Companion iPhone App
- Remote control
- Notifications

### 6. Marketplace
- Plugin system
- Community power modes

---

## Notes / Bugs to Remember

### 2026-10-09 Issues Solved:
- ✅ `tac` not found (macOS) → `tail -r`
- ✅ `.disabled` conflicts with SwiftBar auto-disable
- ✅ Python regex on shell scripts — dangerous
- ✅ `defaults delete` doesn't always clear SwiftBar prefs
- ✅ SwiftBar nuclear reset needed sometimes

### Known Fragile Points:
- ⚠️ Sudoers file can be reset by macOS updates
- ⚠️ Watchdog needs to respect `.user_shutdown`
- ⚠️ Self-healing should NOT undo user-intended Shutdown
- ⚠️ SwiftBar 1.4.4 (old) has bug with `DisabledPlugins`

### Lessons Learned:
- **Regex on shell scripts:** unsafe. Use line-based edit.
- **bash -n after EVERY change.** Not after all changes.
- **Backup before each Python edit.**
- **Test immediately, don't wait.**

---



## v1.3.0 — Priority 2 (Event-Driven Architecture)

### P2.1 — Consolidate LaunchAgents (12 → 6) [IN PROGRESS]
**Impact:** -60% launchd spawns, -15% CPU idle
**How:** Merge sailing + adaptive + ensure-limit + system-guard into 1 agent
**Status:** Script ready in /tmp/consolidate-agents.sh

### P2.2 — Event-Driven Architecture (IOKit Notifications)
**Impact:** Instant response instead of polling
**How:**
- Use `pmset -g ps` + `NSDistributedNotificationCenter` for power source changes
- Replace periodic polling with event listeners
- Requires helper binary (Swift or C)

**Challenges:**
- macOS 10.15 API limitations
- Requires root privileges for IOKit power events
- Complex error handling

**Value:** Latency 0 vs 5 minutes → huge UX improvement

### P2.3 — Shared Cache Layer (IPC)
**Impact:** No redundant reads between dispatch + plugin
**How:**
- Small daemon runs as cache server
- Plugin/dispatch query via Unix socket
- TTL-based invalidation

**Value:** Further 100-200ms speedup

### P2.4 — Telemetry Dashboard
**Impact:** Visual battery/temp/load history
**How:**
- SQLite DB + simple HTTP server
- Charts via Chart.js or similar
- Accessible at localhost:8080/battopt

**Value:** Long-term trend analysis + predictive health

### P2.5 — Snapshot-based Rollback
**Impact:** Auto-recover if 3 identical errors within 1h
**How:**
- Track error signatures in .error_signatures
- If threshold exceeded → restore last snapshot
- Notify user of rollback

**Value:** Zero-day bug recovery

---

## v2.0 — Native .app

### V2.1 — SwiftUI Rewrite
- Graphical settings panel
- Real-time battery charts
- Drag-and-drop power modes
- No SwiftBar dependency

### V2.2 — Menu Bar Widget
- Native NSStatusItem
- Richer popovers
- Keyboard shortcuts

### V2.3 — iOS Companion
- Watch battery from phone
- Remote configuration
- Push notifications

---

## Performance Targets

| Metric | Current | Target v1.3 | Target v2.0 |
|---|---|---|---|
| Plugin speed | 839ms | < 400ms | < 100ms |
| RAM usage | 44 MB | 35 MB | 20 MB |
| CPU (idle) | 0.0% | 0.0% | 0.0% |
| LaunchAgents | 12 | 6 | 2 |
| Cold start | 2.9s | 1.5s | 0.5s |
| Warm response | 839ms | 400ms | 100ms |

---

## Known Fragile Points (from bug hunts)

### Race Conditions
- `.sleep_mode` writers: 4 cases in dispatch
- Mitigation: atomic_write helper
- Remaining gap: state ↔ pmset consistency (5 min window)

### State Machine Leaks
- If dispatcher killed mid-update: partial state
- Mitigation: self_healing every 5 min
- Improvement: state checksum in separate file

### Cache Coherence
- `.status_cache` (25s TTL) — stale if daemon restarts
- `.wake_cache` (600s TTL) — acceptable
- `.usb_cache` (300s TTL) — acceptable

### Sudo Dependencies
- 4 LaunchAgents use `sudo -n`
- Risk: sudoers reset by macOS update
- Fix: self_healing detects + notifies user

### Time-based Failures
- DST: `date +%H` OK with 24h format
- Arm_sleep hour check: 22:00-09:00 range safe

---

## Bug Hunt Checklist (run periodically)

1. **Syntax validation** — all scripts
2. **State file integrity** — config, .last_inputs, .sleep_mode, .apg_state
3. **Daemon responsiveness** — `sudo battopt status` < 1s
4. **Cache coherence** — TTLs respected
5. **LaunchAgent overlap** — no duplicate pmset writes
6. **Sudo dependencies** — NOPASSWD still works
7. **Input validation** — all dialogs check ranges
8. **Atomic writes** — no partial state files



## v1.3 — Roadmap (Post v1.2 release)

### Priority 1 — Speed Optimization
- [ ] Cache `pmset -g custom` (single read) ✅ done
- [ ] Unified config read ✅ done
- [ ] Lazy load Sleep Mode submenu (in progress)
- [ ] Target: < 400ms warm

### Priority 2 — Architecture
- [ ] Consolidate LaunchAgents (12 → 6) ✅ in progress
- [ ] Event-driven (IOKit notifications instead of polling)
- [ ] Shared cache layer (dispatch + plugin IPC)
- [ ] Telemetry dashboard (HTML report)

### Priority 3 — Advanced Features
- [ ] Native .app (SwiftUI)
- [ ] iOS companion
- [ ] Marketplace for power modes
- [ ] Weekly health report
- [ ] Anomaly detection + auto-rollback
- [ ] Multi-Mac sync

---

## Known Fragile Points

### Race Conditions
- `.sleep_mode` writers: 4 cases in dispatch
- Mitigation: atomic_write helper
- Remaining gap: state ↔ pmset consistency (5 min window)
- **Solution:** Add `.state.lock` per mode transition

### State Machine Leaks
- If dispatcher killed mid-update: partial state
- Mitigation: self_healing every 5 min
- **Improvement:** State checksum in separate file

### Cache Coherence
- `.status_cache` (25s TTL) — stale if daemon restarts
- `.wake_cache` (600s TTL) — acceptable
- `.usb_cache` (300s TTL) — acceptable
- **Solution:** Cache invalidation on daemon restart

### Sudo Dependencies
- 4 LaunchAgents use `sudo -n`
- Risk: sudoers reset by macOS update
- **Mitigation:** self_healing detects + notifies

### Time-based Failures
- DST: `date +%H` OK with 24h format
- Arm_sleep hour check: 22:00-09:00 range safe
- **Check:** Schedule test on DST boundary

---

## Bug Hunt Checklist (Run Periodically)

1. ✅ Syntax validation (all scripts)
2. ✅ State files integrity
3. ✅ pmset consistency (sleep_mode ↔ actual)
4. ✅ APG state valid
5. ✅ Daemon responsiveness < 2s
6. ✅ Cache TTLs respected
7. ✅ LaunchAgents < 10
8. ✅ Sleep blockers = 0
9. ✅ FORCE RESET count
10. ✅ Disk (backups < 200, log < 200KB)

---

## Lessons Learned (for future)

### What Went Well
- 5-layer defensive architecture
- Self-healing daemon
- Input persistence
- Radio submenu (single-select)
- Emergency stop

### What Was Painful
- SwiftBar auto-disable bug
- Python regex on shell scripts (unsafe)
- `pmset disablesleep` not supported on macOS 10.15
- Cache invalidation complexity

### Best Practices Applied
- `bash -n` after every change
- Backup before each edit
- Test immediately
- Small targeted changes
- Atomic writes for critical state



## 2026-10-10 — Session Summary

### ✅ Completed Today
- Fixed 20+ bugs (dispatcher, Power Mode, SD, zombies)
- Implemented APG (Adaptive Power Governor)
- Sleep Mode submenu (4 modes)
- SD persistence (5 keys)
- SD vs Hold race condition fixed (session isolation)
- hold_at_current fast return (60s → 2.5s)
- Consolidate LaunchAgents (12 → 9)
- Zombie killer + PowerWatch subreaper fix

### 🔄 Pending (Pre-release)
- [ ] README rewrite (AR + EN)
- [ ] Version unification (1.2.0)
- [ ] Uninstall script
- [ ] .gitignore cleanup
- [ ] Final night test

### ⏸️ Deferred (v1.3)
- [ ] Plugin speed optimization
  - Current: 840ms (Firefox bound)
  - Target: < 400ms
  - Approach: Daemon-cache architecture
- [ ] Event-driven architecture (IOKit notifications)
- [ ] Shared cache layer (dispatch + plugin IPC)
- [ ] Telemetry dashboard (HTML)
- [ ] Native .app (SwiftUI)
- [ ] iOS companion

### 🐛 Known Limitations
- Plugin speed: 840ms (not < 400ms target)
  - Cause: 73 forks × 10ms each
  - Firefox memory pressure worsens
  - Mitigation: close Firefox / restart Mac
- Firefox memory leak: 67 processes, 5.4 GB RAM
  - Not a BattOpt issue
  - Recommendation: reduce tabs or restart Firefox periodically
- Swap usage: > 3 GB when Firefox heavy
  - Slows all forked processes

### 📋 Recommended User Actions
1. Close Firefox heavy tabs periodically
2. Restart Mac weekly
3. Watch APG state in menu (colors follow temperature)
4. If plugin slow → check `sysctl vm.swapusage`
5. Run `/tmp/preflight.sh` weekly to verify

### 🔍 Bug Hunt Checklist (Run After Any Change)
1. Syntax: `bash -n ~/.battopt-swiftbar/*.sh`
2. State files: config, .last_inputs, .sleep_mode, .current_power_mode, .apg_state
3. Zombies: `ps -axo stat | grep -c '^Z'`
4. Health: `~/.battopt-swiftbar/project_health.sh`
5. SD + Hold race: verify limit stays after Stop Charging
6. Sleep Mode cycle: 4 modes must work
7. Power Mode cycle: 4 modes must work
8. APG state: green/yellow/red valid

### 🚧 Architectural Notes
- Dispatcher: 52 cases, 26 helpers
- Plugin: 633 lines, 73 forks (expensive on MBP9,1)
- Consolidation: sailing + adaptive + ensure-limit + system-guard → consolidated
- Session isolation: `.sd_session` prevents SD/Hold races

### 🎯 Decision Points for Next Session
1. **Ship v1.2 or improve further?**
   - APG works
   - SD/Hold/race fixed
   - Health 20/0/0 (when Firefox light)
   - Block: README + version
2. **Firefox strategy?**
   - Accept slowness
   - Reduce tabs
   - Restart Mac periodically
3. **Plugin speed?**
   - Accept 840ms
   - Or invest 3h in daemon-cache


---

## v1.3 — Conflict Prevention + Permissions

### P1: Button Conflict Prevention
- Detect state when pressing action
- Show confirmation if action will override existing state
- Cases:
  - `sail_on` while Hold active → warn
  - `stop_now` while Sailing active → warn
  - `smart_discharge` while SD running → warn
  - `hold_at_current` while target limit pending → warn

### P2: Onboarding Permissions
- On first app launch, request:
  - Browser permissions (Firefox/Safari/Chrome)
  - System events access
  - Notifications permission
  - Login items authorization
- Save user choices in config
- Show "Permissions" section in menu

### P3: Pause/Resume Sailing (implemented today)
- `pause_sailing` case: turn off but save gap
- `resume_sailing` case: restore saved gap
- Persistent via `.last_inputs` key `SAIL_GAP_PAUSED`


---

## v1.3 — Permissions + Conflict Prevention

### P1: Onboarding Permissions (First Launch)
**Goal:** Ask user for required permissions once.

**Required:**
- Browser automation (Firefox/Safari/Chrome)
- Notifications
- Login items (auto-start)
- Sudoers NOPASSWD (already configured)
- Full Disk Access (for reading system logs)

**Implementation:**

On first app launch → wizard:

    Notifications: check + request

    Login items: check + add

    Sudoers: verify + offer to install

    FDA: detect + guide to System Preferences

    Save completed permissions in .permissions_ok

text


**Menu item:** "Setup Permissions..." (visible if incomplete)

### P2: Button Conflict Prevention
**Goal:** Warn before overriding existing state.

**Cases:**
- `sail_on` while Hold active → "Will override hold, continue?"
- `stop_now` while Sailing active → "Will pause sailing, continue?"
- `smart_discharge` while SD running → "Already running, restart?"
- `limit_custom` while SD active → "Will cancel SD, continue?"

**Implementation:** `check_conflict(action)` function that inspects current state before each action.

### P3: Pause/Resume Sailing (Done ✅)
- `pause_sailing`: saves current gap to `SAIL_GAP_PAUSED`, turns off
- `resume_sailing`: restores saved gap
- Menu shows "Sailing paused (gap X% saved) ▶"

### P4: Cache Coherence
- ✅ Status TTL reduced 25s → 10s
- ⏳ Better: invalidate cache on state change events
- ⏳ Best: state version counter — cache invalidates when daemon restarts

