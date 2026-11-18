# Power Saver Profiles — Distinct long / travel Values (DESIGN ONLY)

**Date:** 2026-11-11. **Status:** DESIGN ONLY — no change applied, no pmset touched.
**Approved by Yousef 2026-11-11 17:26 EET:** "ايوه بس ظبط الحاجات دي" (yes, but fix/adjust
these things). The values below must be presented to him for approval before any change is
applied (pmset changes are Red).

## 1. Why this design exists

- W4.3 (approved decision 5, 2026-11-09) REMOVED the `long`/`travel` profiles from
  `power_saver.sh` because they were dead duplicates: in the repo copy they were exact
  copies of `default` (300/300/900, sleep 20); in the installed copy `travel` differed
  only in battery high/low (3600 vs 600). Yousef now wants DISTINCT values for them.
- This design redefines `long` and `travel` as genuinely distinct profiles, grounded in
  (a) the user-facing Travel Mode dialog in `dispatch.sh` (the only in-tool definition of
  what "travel" means), (b) the original intent in commit `134379a` ("feat: add
  source-aware sleep delay profiles", 2026-10-16) and its test
  `tests/test_power_saver_profiles.sh`, and (c) the current W4.3 default as the baseline.

## 2. Current state (baseline — unchanged)

**`power_saver.sh` (W4.3, repo = deployed, md5 `3bdf5ebe…`):** exactly ONE profile,
`default`. `apply_delays()` sets (battery `-b`, AC `-c`):

| | battery high | battery low | battery auto | AC high | AC low | AC auto | AC sleep |
|---|---|---|---|---|---|---|---|
| **default** | 600 | 600 | 1800 | 10800 | 10800 | 3600 | 90 |

- `high`/`low` = `standbydelayhigh`/`standbydelaylow` (seconds after sleep before the Mac
  enters standby). `auto` = `autopoweroffdelay` (seconds after sleep before autopoweroff /
  deep hibernate). `sleep` = AC system-sleep idle time (minutes). `disksleep 10` on both.
- `enforce_sleep_policy()` calls `apply_delays default`. `arm_sleep.sh` hardcodes
  `APPLY_PROFILE=default`. Unknown profiles fall back to `default` with a log line.
- **Live `pmset -g` (2026-11-11, read-only) matches default exactly:** battery
  standbydelayhigh/low 600, autopoweroffdelay 1800; AC 10800/10800/3600, sleep 90;
  hibernatemode 25, standby 1, autopoweroff 1, powernap 0, womp 0, acwake 0, lidwake 1,
  disksleep 10. (Battery `sleep 18` is the macOS default; `power_saver.sh` does not set
  battery sleep and this design does not add it.)

## 3. What "travel" and "long" mean

### travel — "Short trips: keep the session alive on battery"
- **The definition comes from the tool itself.** `dispatch.sh` `sleep_mode_travel` shows
  this dialog (user-facing, unchanged): "Battery hibernates after 4h instead of 30min.
  Drains battery ~3% more overnight. Keeps session state alive longer. Only affects
  battery (AC unchanged). Best for: short trips, keeping state alive."
- So travel = **delay hibernation on battery** (stay in regular sleep / standby longer,
  wake fast, session alive) at the cost of more drain. AC is **unchanged**.
- **Reachability:** already reachable — plugin menu "Travel" → `dispatch.sh`
  `sleep_mode_travel` → `power_saver.sh apply-delays travel`. (Since W4.3 removed the
  profile, that call currently falls back to `default` with a log line — Travel Mode
  is silently doing nothing distinct right now.)

### long — "Long work sessions: keep the Mac ready on both battery and AC"
- **No user-facing definition exists yet** (no `sleep_mode_long` in `dispatch.sh`, no
  menu item; `arm_sleep.sh` hardcodes `default`). The definition below follows the
  original intent in commit `134379a` and its test: `long` delays standby on BOTH
  battery and AC (longer than `default` on both), while `travel` delays it on battery
  only. In `134379a`: long = battery 3600/3600/1800, AC 7200/7200/3600; travel =
  battery 3600/3600/1800, AC 10800/10800/3600 (AC = default). The test file
  `tests/test_power_saver_profiles.sh` encodes exactly those values.
- So long = **delay standby/hibernate on both power sources** (fast wake everywhere
  during a long day/session). Use case: a long work day / conference where you
  open/close the lid frequently on battery and AC and want no hibernate lag.
- **Reachability gap (must be fixed as a follow-up, not in this design):** `long` is
  currently reachable ONLY via terminal (`power_saver.sh apply-delays long`). To make
  it usable, add a `sleep_mode_long` dispatch action + a "Long" menu item in the plugin
  (and optionally wire `arm_sleep.sh`'s `APPLY_PROFILE` to `.sleep_mode`). Until then,
  defining the values alone would leave `long` as dead code again — the follow-up is
  required for the values to matter.

## 4. Proposed values

| Profile | battery high | battery low | battery auto | AC high | AC low | AC auto | AC sleep |
|---|---|---|---|---|---|---|---|
| **default** (unchanged) | 600 | 600 | 1800 | 10800 | 10800 | 3600 | 90 |
| **travel** (NEW) | **3600** | **3600** | **14400** | 10800 | 10800 | 3600 | 90 |
| **long** (NEW) | **3600** | **3600** | **3600** | **14400** | **14400** | **7200** | 90 |

All three profiles are distinct from each other, and each differs from `default`:
- travel vs default: battery high/low 600→3600, battery auto 1800→14400. AC identical
  (by design — "only affects battery").
- long vs default: battery high/low 600→3600, battery auto 1800→3600; AC high/low
  10800→14400, AC auto 3600→7200.
- travel vs long: battery auto 14400 vs 3600; AC high/low 10800 vs 14400, AC auto
  3600 vs 7200. (Battery high/low are the same 3600 in both — the difference is in
  how long each delays the deep power-off and in AC.)
- AC `sleep` stays 90 in all three (as in the original `134379a` test, where all three
  profiles had ac_sleep=90). The profiles differ in the standby/autopoweroff delays,
  which is what they control; `sleep` is not part of the distinction.

### 4.1 travel — reasoning per value
- **battery high/low = 3600 (1 h, was 600 / 10 min):** delays entering standby on
  battery from 10 min to 1 h. The Mac stays in regular sleep (fast wake, session
  alive) for an hour after lid-close — the "keep session state alive longer" for
  short trips. This value is taken from the installed copy and the `134379a` test
  (both used 3600 for travel battery standbydelay).
- **battery auto = 14400 (4 h, was 1800 / 30 min):** delays autopoweroff (deep
  hibernate / power-off) on battery from 30 min to 4 h. This is what makes the
  dialog's promise true: "hibernates after 4h instead of 30min". **Correction:**
  the installed copy had auto=1800 (30 min) — it did NOT deliver the 4 h the dialog
  promises. This design corrects that so the values match the user-facing dialog.
  (The Mac enters standby at 1 h, then powers off at 4 h — a sensible progression.)
- **AC = default (10800/10800/3600, sleep 90):** unchanged, per the dialog ("Only
  affects battery (AC unchanged)"). When plugged in at a hotel, normal behavior.
- **Tradeoff:** more drain on battery. The dialog says "~3% more overnight" — that
  is consistent with ~0.5 W standby draw over the extra ~3.5 h before power-off
  (~1.75 Wh ≈ 3% of the ~58 Wh usable capacity). The user accepts this explicitly
  (Travel Mode is a menu action with a confirmation dialog).

### 4.2 long — reasoning per value
- **battery high/low = 3600 (1 h, was 600 / 10 min):** same as travel — delays
  standby on battery so the Mac wakes fast during a long day of frequent
  lid-open/close. (Taken from `134379a` / the test, which used 3600 for long battery
  standbydelay.)
- **battery auto = 3600 (1 h, was 1800 / 30 min):** delays autopoweroff on battery
  from 30 min to 1 h — a moderate delay (less aggressive than travel's 4 h). Rationale:
  `long` is for a work day, not a trip; you still want the Mac to power off
  eventually to save battery, just not after 30 min. This is also what makes `long`
  distinct from `travel` on battery (auto 3600 vs 14400).
- **AC high/low = 14400 (4 h, was 10800 / 3 h):** delays standby on AC from 3 h to
  4 h. On AC the Mac is plugged in, so drain is not a concern; the delay keeps it in
  regular sleep (fast wake) longer during a long session. (Note: `134379a` used 7200
  for long AC, but that was relative to its then-default of 3600; the CURRENT default
  AC is 10800, so 7200 would now be SHORTER than default — the opposite of "long".
  14400 is longer than the current default 10800, which is what "long" requires.)
- **AC auto = 7200 (2 h, was 3600 / 1 h):** delays autopoweroff on AC from 1 h to
  2 h, consistent with the longer AC standby (14400). (Taken from `134379a`, which
  used 7200 for long AC auto — that value is still longer than the current default
  3600, so it is kept.)
- **AC sleep = 90 (unchanged):** same as default (and as in the `134379a` test, where
  all profiles had ac_sleep=90). The distinction is in the delays, not the idle-sleep
  time.
- **Tradeoff:** more drain on battery (same mechanism as travel, milder: autopoweroff
  at 1 h instead of 4 h) and the Mac stays responsive longer on AC. `long` is for a
  deliberate choice (a long day), not the everyday default.

## 5. Safety notes

- All values are within standard `pmset` ranges (standbydelay / autopoweroffdelay
  0–86400 s; sleep 0–180 min). No extreme values.
- `standbydelay` 3600 (1 h) on battery is safe: the Mac stays in regular sleep for an
  hour; the BC protections (APG guard, overshoot UPPER+2, Prepare warning, post-wake
  delay) are unaffected — this design changes only the standby/autopoweroff timing,
  not the charge limit (86/85) or any SMC behavior.
- `autopoweroffdelay` 14400 (4 h, travel) is safe: the Mac powers off after 4 h in
  standby. If the battery is low, macOS still protects it (and Travel Mode is a
  deliberate user choice with a warning dialog). The "never combine % below lower +
  attached charger + sleep" rule is not violated: these profiles do not change the
  charge limit, and `travel` only affects battery (AC unchanged).
- The `default` profile is UNCHANGED — the everyday drain-conscious behavior is
  untouched. `long`/`travel` are opt-in (menu actions), not the default.
- **Sleep-drain note:** these profiles delay standby/hibernate, so they INCREASE
  overnight drain while active (that is the explicit tradeoff in the travel dialog).
  They are NOT a fix for the sleep drain (~1.6%/h, root-cause plan S1–S4). The
  `default` profile remains the drain-conscious one. Do not confuse the two goals.

## 6. How to apply (when Yousef approves — NOT done now)

1. In `src/daemon-helpers/power_saver.sh`, add `long)` and `travel)` cases to
   `apply_delays()` with the values in §4 (keep `default` byte-identical; keep the
   unknown-profile fallback to `default`).
2. Update `tests/test_power_saver_profiles.sh` with the new expected values (the test
   currently encodes the `134379a` values, which are stale relative to the W4.3
   default) and run it.
3. `bash -n` OK, transfer, redeploy via `deploy-populate.sh`, verify repo = deployed
   (md5), run `power_saver.sh apply-delays long` / `travel` in a dry-run (pmset stub)
   and confirm the values, then a live `pmset -g` read-only check after Yousef
   enables the mode once.
4. Follow-up (separate, needed for `long` to be usable): add `sleep_mode_long`
   dispatch action + "Long" menu item in the plugin (and optionally wire
   `arm_sleep.sh` `APPLY_PROFILE` to `.sleep_mode`). `travel` needs no wiring — it is
   already reachable via the Travel sleep mode.

## 7. Approval needed

Yousef must approve the values in §4 before anything is applied (pmset changes are
Red). The question to him: approve `travel` (battery 3600/3600/14400, AC unchanged)
and `long` (battery 3600/3600/3600, AC 14400/14400/7200, sleep 90) as defined above?
If he approves, apply per §6. If he wants different values, say which and why.

## 8. Sources

- `src/daemon-helpers/power_saver.sh` (W4.3, repo = deployed, md5 `3bdf5ebe…`).
- `battopt-project/bc-build/power_saver.sh.pre-w4` (repo copy before W4.3: long/travel
  exact duplicates of default 300/300/900, sleep 20; `conservative` 3600/3600/3600,
  sleep 30; `enforce_sleep_policy` called `conservative`).
- Commit `134379a` (2026-10-16, "feat: add source-aware sleep delay profiles") +
  `tests/test_power_saver_profiles.sh` (long = battery 3600/3600/1800, AC 7200/7200/3600,
  sleep 90; travel = battery 3600/3600/1800, AC 10800/10800/3600, sleep 90; default
  then = battery 2700/2700/1800, AC 3600/3600/3600, sleep 90).
- `src/daemon-helpers/dispatch.sh` `sleep_mode_travel` dialog (the user-facing travel
  definition) + `sleep_mode_default` (AC sleep 120) + `sleep_mode_presentation` /
  `sleep_mode_download`; plugin menu (Normal / Presentation / Long Tasks / Travel —
  no "Long" item).
- Live `pmset -g` / `pmset -g custom` (2026-11-11, read-only): matches W4.3 default
  exactly (battery 600/600/1800, AC 10800/10800/3600, sleep 90, hibernatemode 25).
- `~/workspace/bc-build/w4-completion-note.md` (W4.3: long exact duplicate of default;
  travel differed only in battery 3600 in the installed copy; distinct values can be
  redefined later).
- Sleep-drain root-cause plan (`~/workspace/bc-build/sleep-drain-root-cause-plan.md`):
  drain ~1 W in regular sleep; delaying standby increases drain (the tradeoff here).
