# Menu Audit — Full BC Menu + Sleep Mode Submenu Fix (2026-11-11 18:47–19:05 EET)

Yousef sent a screenshot of the Sleep Mode submenu (18:46 EET) and asked to fix
the menu because the buttons look duplicated, and to check the whole tool: which
buttons work, which are duplicated, which are misplaced.

## 1. The Sleep Mode confusion (the reported problem)

The submenu had two items whose names collide:
- **"Long Tasks"** = `sleep_mode_download` — an OLD sleep mode: keeps the Mac
  fully awake with the lid closed, AC required, `disablesleep=1`, never sleeps.
  (Best for: large downloads, long exports, backups.)
- **"Long"** = `sleep_mode_long` — the NEW power_saver profile (added 2026-11-11
  18:25): delays standby/hibernate on battery + AC so the Mac stays ready
  longer. (Best for: long work sessions.)

They are DIFFERENT functions, so neither was deleted. The fix is naming +
placement so they can never be confused.

## 2. Full menu map (item -> dispatch action -> function -> works?)

### Power Mode submenu — all work
| Item | Action | Function | Works? |
|---|---|---|---|
| Fast Sleep | power_mode_fast | power_mode.sh fast | YES |
| Balanced | power_mode_balanced | power_mode.sh balanced | YES |
| Always Awake | power_mode_awake | power_mode.sh awake | YES |
| Deep Only | power_mode_deep | power_mode.sh deep | YES |
| Set Custom Values… | power_mode_custom | dialogs -> power_mode.sh custom | YES |

### Sleep Mode submenu — all work (renamed, see §4)
| Item | Action | Function | Works? |
|---|---|---|---|
| Normal | sleep_mode_default | restores defaults, .sleep_mode=default | YES |
| Presentation | sleep_mode_presentation | AC only, sleep 0 | YES |
| Stay Awake (Lid Closed) [was "Long Tasks"] | sleep_mode_download | AC only, disablesleep=1, lid-closed awake | YES |
| Travel | sleep_mode_travel | apply-delays travel | YES |
| Long Day [was "Long"] | sleep_mode_long | apply-delays long | YES |
| Prepare for Sleep | arm_sleep | arm_sleep.sh | YES |

### Charge actions
| Item | Action | Function | Works? |
|---|---|---|---|
| Stop Charging Now | stop_now | hold at current % (limit CUR/CUR-1) | YES |
| Charge to 100% & Hold | charge_full | limit 100/99 | YES |
| Smart Discharge... | smart_discharge | sets limit to target, natural drain | PARTIAL — honest stub; no forced discharge yet (later phase) |
| Stop Discharge | kill_discharge | stops the discharge session | YES |
| Force Reset | force_reset | force_reset.sh (BC recovery) | YES |
| Reset to Defaults | reset_defaults | resets to 86/85 etc. | YES |

### Charge Limits
| Item | Action | Function | Works? |
|---|---|---|---|
| Custom Limit | limit_custom | dialog -> bc_apply_limit | YES |
| Remove Hold (return to X%/Y%) | remove_limit_hold | clear_hold -> configured limit | YES (label now dynamic, was hardcoded 86/85%) |
| Disable All Limits | disable_limit | limit 100/99 | YES |

### Battery Care
| Item | Action | Function | Works? |
|---|---|---|---|
| Start Calibration | calibrate | stub — "Calibration not in BC yet" | NOT IN v1 (honestly labeled in the menu) |
| Stop Calibration (API) | cal_stop | kill_calibrate (no-op) | REMOVED (dead) |
| Force Stop Calibration | kill_calibrate | no-op, only shown when calibration active (never) | KEPT (conditional, invisible now) |
| Clamshell Off / On / On+screen | clam0/1/2 | stubs — "not supported in BC yet" | REMOVED (dropped by approved decision) |
| Schedule Enable / Disable | sched_on/sched_off | stubs — "not supported in BC yet" | REMOVED (dropped by approved decision) |

### Reports / tools
| Item | Action | Function | Works? |
|---|---|---|---|
| Refresh Now | (SwiftBar built-in) | | YES |
| Show Full Status... | details | dialog with bc-status + agents | YES |
| Sleep & Battery Report | sleep_report | generates + opens report | YES |
| Overnight Report | overnight_report | opens the morning report | YES |
| Save Report (silent) | sleep_report_save | saves report to reports/ | YES (kept — single place) |
| Open Reports Folder | open_reports | opens reports/ in Finder | YES (kept — single place) |
| Open Battery Commander (BC) Logs | open $DASH | opens state dir | YES |
| Open Actions Log | open_actions_log | opens actions.log | REMOVED (duplicate of Logs -> Actions Log) |
| Launch at Login | login_toggle | toggles the login item | FIXED (was broken — see §3) |
| Open Battery Commander.app | open_app | opens /Applications/BatteryCommander.app | FIXED (was broken — see §3) |
| About Battery Commander (BC)... | about | About dialog | YES |

### Sleep Report submenu
| Item | Action | Function | Works? |
|---|---|---|---|
| Disable/Enable Power Saver | power_saver_off/on | | YES |
| Show Full Report | power_saver_report | dialog + Save/Toggle | YES |
| Save Report to File | sleep_report_save | | REMOVED (duplicate of top-level) |
| Open Reports Folder | open_reports | | REMOVED (duplicate of top-level) |

### Auto Cleanup / Developer Tools / Logs
| Item | Action | Works? |
|---|---|---|
| Run Cleanup Now | pre_sleep_now | YES |
| Restore Services | post_wake_now | YES |
| Disable/Enable Auto Cleanup | auto_cleanup_toggle | YES |
| Project Health Check | project_health | YES |
| Conflict Detection | conflict_check | YES |
| Predictive Analysis | predictive | YES |
| Process Monitor | process_monitor | YES |
| AI Diagnostic Bundle | logs_ai_bundle | YES |
| Actions Log | logs_actions | YES (kept — single place) |
| Sailing History | logs_sailing | YES |
| Arm Log | logs_arm | YES |
| Daemon Logs | logs_daemon | YES |
| Reports Folder | logs_reports | REMOVED (duplicate of top-level Open Reports Folder) |

### System Resources
| Item | Action | Works? |
|---|---|---|
| Stop ALL Services (full shutdown) | shutdown | FIXED (see §3; verified by inspection, NOT run live) |

## 3. Broken buttons found (all fixed)

These are buttons that did NOT work — found by the audit, verified live:

1. **"Open Battery Commander.app" (open_app) — BROKEN.** dispatch.sh used
   `_APP="/Applications/Battery Commander.app"` (WITH a space) — that path
   never existed. It fell back to `/Applications/BattOpt.app`, which was
   deleted on 2026-11-10. So the button opened nothing. Fixed to
   `/Applications/BatteryCommander.app` (no space). Same wrong path in
   `login_toggle` and `resume`.
2. **"Launch at Login" (login_toggle) — BROKEN (showed the wrong state).**
   The plugin and dispatch checked login items with
   `grep -c "BattOpt\|Battery Commander"`. The live login item is named
   "BatteryCommander" (NO space), so the pattern never matched: the menu
   showed "Launch at Login" WITHOUT the ✓ even though it IS a login item,
   and clicking it would have added a DUPLICATE login item. Fixed the pattern
   to `"BattOpt\|BatteryCommander\|Battery Commander"` in both files.
   Verified live: after clearing the 1 h login cache, the menu now renders
   "✓ Launch at Login".
3. **"Stop ALL Services" (shutdown) — BROKEN (would not have stopped BC).**
   Step 3 unloaded `com.battopt.*.plist` and step 9 verified with
   `grep -c "com.battopt"`. After the 2026-11-11 rename the live agents are
   `com.batterycommander.*`, so shutdown would have unloaded nothing and
   reported COMPLETE while all 15 BC agents kept running. It also killed
   `/Applications/BattOpt.app` (gone) instead of BatteryCommander.app, and
   removed the "BattOpt" login item instead of "BatteryCommander". Fixed all
   three (agent loop, verification gate, app/login-item names).
4. **resume / restore (not a menu button, called by the launcher) — BROKEN.**
   Same stale `com.battopt.*` loop: it would have RE-LOADED the retired
   guardian/enforce/consolidated/adaptive-governor agents and NOT reloaded
   the 15 live BC agents. Fixed to `com.batterycommander.*`.
5. **verify-install.sh (not a menu item, but a broken check) — BROKEN.**
   Its LaunchAgents check expected the 17 old `com.battopt.*` labels, so it
   reported FAIL even though everything is healthy; its SUDOERS path pointed
   at the deleted `/etc/sudoers.d/battopt`; its APP path was
   "/Applications/Battery Commander.app" (space) and its launcher name was
   "Battery Commander-launcher.sh" (space) — neither exists (real names have
   no space). Fixed all four. Now: **ALL CHECKS PASSED (11/11)**.

## 4. What was fixed (labels + placement)

- **"Long Tasks" -> "Stay Awake (Lid Closed)"** (menu item, SM_TITLE header,
  and the dispatch dialogs/notifies: "Enable Stay Awake (Lid Closed)?",
  "Stay Awake: ON — disable when done", "Stay Awake: OFF",
  "Stay Awake: FAILED to start"). Subtitle now "Lid closed · AC required ·
  never sleeps". The action name `sleep_mode_download` is unchanged.
- **"Long" -> "Long Day"** (menu item, SM_TITLE header, dispatch dialog
  "Enable Long Day?" and notify "Sleep Mode: Long Day"). Action name
  `sleep_mode_long` unchanged.
- **Group label added** in the Sleep Mode submenu: a separator + "Hibernate
  timing — after the Mac sleeps" above Travel / Long Day, separating the
  sleep-behaviour modes (Normal / Presentation / Stay Awake) from the
  hibernate-timing profiles (Travel / Long Day).
- **"Remove Hold" label is now dynamic**: "Remove Hold (return to
  ${DISP_UPPER}%/${DISP_LOWER}%)" — it renders 86%/85% now, and stays correct
  if the limit ever changes (was hardcoded 86/85%).
- **Removed the Clamshell section (3 buttons) and the Schedule section
  (2 buttons)** from the menu. Both were DROPPED by Yousef's approved
  wrapper decision 4 (2026-11-09); the buttons only showed a "not supported"
  notification. The dispatch stubs (clam0/1/2, sched_on/sched_off) stay in
  place as a safety net (a stale SwiftBar cache clicking one just notifies).
- **Removed 4 duplicated menu items** (each action keeps exactly one place):
  "Save Report to File" (Sleep Report submenu), "Open Reports Folder"
  (Sleep Report submenu), "Reports Folder" (Logs submenu), "Open Actions Log"
  (top level). Kept: top-level "Save Report (silent)" + "Open Reports Folder",
  Logs submenu "Actions Log".
- **Removed "Stop Calibration (API)"** (dead — calibration is not in v1, so
  there is nothing to stop; `kill_calibrate` is a no-op). "Start Calibration"
  stays with its honest "Not in v1 yet — arrives in a later phase." note;
  the conditional "Force Stop Calibration" stays (only shows when a
  calibration is active, which can never happen now).

## 5. Verification

- `bash -n` OK on plugin (924 lines), dispatch.sh (2108 lines),
  verify-install.sh.
- Repo = deployed = installed (md5): plugin `ad7b6a08…`, dispatch `6ddb6f3…`.
- Render test (installed plugin, exit 0): Sleep Mode renders Normal ✓ /
  Presentation / Stay Awake (Lid Closed) / Hibernate timing label / Travel /
  Long Day / Prepare for Sleep; no "Long Tasks", no Clamshell, no Schedule,
  no "Stop Calibration"; Save Report ×1, Open Reports Folder ×1,
  Actions Log ×1, "✓ Launch at Login" (after clearing the stale 1 h cache),
  "Remove Hold (return to 86%/85%)".
- verify-install.sh: **ALL CHECKS PASSED (11/11)** (was FAIL 1 before the
  agent-list fix).
- Health check after deploy: **PASS 16 | FAIL 0 | WARN 3 — "Project is
  HEALTHY"** (WARNs are the known ones: enforcer not loaded — Phase C,
  expected; Load; Swap — both not BC).
- Live state: watchdog heartbeat PCT=86 BCLM=10 cfg=86/85 mode=hold;
  bc-status 86.1%.
- Backups on the Mac (repo): `*.pre-menu-audit` next to each edited file.
- Incidents: tunnel flapped (HTTP 502 then 530) mid-task; backed off and
  retried, no work lost. The edit script failed twice on asserted anchors
  (clamshell block start matched a header comment; a duplicate-count
  assumption) — fixed the script, restored the plugin from its backup, and
  re-ran clean. One real bug caught by verification: the script wrote
  literal `\u2014` / `\u00b7` escape text into two menu lines; fixed with a
  second script (real em-dash / middle dot now in place).

## 6. What still needs Yousef's decision

Nothing from this audit. Everything found was fixed, or is already a decided
later-phase item (real Smart Discharge mechanism, Calibration — both already
approved as later phases, not v1). Two notes:
- The shutdown/resume fixes were verified by code inspection + grep, NOT by
  running shutdown (running it unloads all agents + kills SwiftBar — it is
  disruptive and only Yousef would run it if he ever wants a full shutdown).
- The dropped native Swift app (`src/native/Sources/BattOpt/MenuBuilder.swift`)
  still says "Long Tasks · lid closed, AC required" — that app was DROPPED
  (W0 verdict) and is dead code; left untouched.
