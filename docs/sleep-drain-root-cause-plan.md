# Sleep-Drain Root-Cause Plan — Battery Commander

**Date:** 2026-11-11. **Status:** PLAN ONLY — no fix applied, no settings changed.
**Problem:** Overnight battery drain ~1.44–1.64%/h on battery in standby (the known unsolved baseline 1.2–1.7%/h).
Yousef reported 2026-11-11 13:18 EET that last night's drain was "very big". His numbers (15:46 EET):
closed the Mac at ~20:30 at 85% — confirms ~1.44%/h (85% at 20:30 → 70% at 06:54).
Yousef's order (15:46 EET): (1) keep the current state stable/coherent, (2) solve the problems that
appeared (the sleep drain is the main one), (3) standalone app away from SwiftBar, (4) continue to
publishing + DMG.

---

## 1. What is known (evidence base)

### 1.1 Measured drain
- 2026-11-11 (diagnosis): 85% at 20:30 (Yousef) → 70% at 06:54 = 15% / 10.4 h = **1.44%/h**.
  70% → 60% (06:54–13:00) = **1.64%/h**. Overall ~1.5–1.6%/h.
- Baseline (01-PROJECT.md): 2026-10-27/28: 1.69%/h, 9 DarkWakes. v2 night 1 (2026-10-28/29):
  1.66%/h, 12 DarkWakes — baseline-identical (the v2 sleep settings did NOT change it). Informal
  battery sleep 2026-10-30: ~1.18%/h.
- **Power draw (estimate):** Usable capacity ≈ 6900 mAh × 75.9% ≈ 5237 mAh ≈ 58 Wh.
  1.6%/h ≈ 0.93 Wh/h ≈ **~0.9–1.0 W average**. Deep standby (hibernate) should be ~0.05–0.15 W;
  regular sleep is ~0.5–1.5 W. So the Mac is drawing ~1 W overnight — consistent with
  REGULAR SLEEP, not deep standby (or with a gauge artifact — see H8).

### 1.2 Overnight behaviour (2026-11-11 diagnosis, pmset -g log)
- Mac in Standby on BATTERY all night/morning. DarkWakes (RTC/Maintenance, bluetoothd-blueavengers)
  at 06:54 (70%), 09:54 (65%), 11:24 (62%), 12:24 (61–62%). AC attached 13:00 (60%).
  Lid open 13:15 (60%).
- Mac slept normally (standby + maintenance DarkWakes). No BC wake. No discharge loop.
  No process keeping it awake overnight (only brief maintenance wakes).
- Gauge jump: 60% at lid-open (13:15) → 72% by 13:20 (watchdog) — the % reading is unreliable
  by ~10% on this aged battery.

### 1.3 Current pmset settings (live, 2026-11-11)
- standbydelaylow 10800, standbydelayhigh 10800 (AC); battery standbydelay 600 (per power_saver -b,
  confirmed by health check Bat=600). autopoweroffdelay 3600 (AC) / 1800 (battery).
  hibernatemode 25. standby 1. autopoweroff 1. powernap 0. womp 0. acwake 0. lidwake 1.
  sleep 90 (AC). disksleep 10. networkoversleep 0. highstandbythreshold 50.
- power_saver is ENABLED (flag present) and the live values match. The v2 settings are applied.
  Yet the drain persists at baseline rate — so the settings are NOT the (sole) cause.
- sleep_manager (Layer 13) is profiler-only: it records the profile name (.sleep_profile =
  active_ac) and applies NO pmset. Its profile names (long_battery, etc.) reference the removed
  long/travel profiles (stale log messages only, inert).

### 1.4 The known loop + protection layers (01-PROJECT.md)
- Loop (AC/charging, NOT the overnight drain): charge overshoots → guardian LAYER2 discharge →
  SMC ExternalConnected flips → hold → AC returns → ac_watcher reapplies → % falls → daemon
  charges → overshoots again.
- Protection layers are mitigations, NOT root fixes (agreed 2026-10-30). Blockers: (1) closed-source
  battopt is the only SMC path; (2) enforcement pauses in sleep; (3) aging battery.
- Hard test gate: no sleep tests until problems are solved OR protection layers are in place.
  A formal overnight test needs separate explicit approval on a named night, unchanged v2 settings.
- "Never combine % below lower + attached charger + sleep — enforcement pauses in sleep,
  charging continues."

### 1.5 The battery
- MacBook Pro 9,1 (Mid-2012), Catalina 10.15.8. Design 6900 mAh, Health 75.9%, Cycle 568.
  Aged battery; gauge jumps proven (83→90% in 1m38s; 60%→72% in 5 min).

---

## 2. Hypotheses (ranked)

### H1 — Bluetooth maintenance DarkWakes (bluetoothd-blueavengers) — HIGH
- **Claim:** Bluetooth requests periodic maintenance wakes (RTC/Maintenance), and each wake keeps
  the Mac awake long enough (plus the 10-min standby re-entry) to drain the battery.
- **For:** DarkWakes are all bluetoothd-blueavengers ("Toggle beacon state", "Roll beacon
  advertisement"). The baseline explicitly counts DarkWakes (9, 12). Bluetooth is the only
  recurring wake trigger in the log.
- **Against:** Rate does NOT correlate with DarkWake count (9 vs 12 → same ~1.66–1.69%/h).
  DarkWakes are brief (0 secs) and 1.5–3 h apart. A brief wake cannot explain a steady 1.6%/h
  by itself.
- **Test:** (a) Count DarkWakes + their durations over a full diagnostic night (pmset log).
  (b) One controlled night with Bluetooth OFF (user action; needs approval) — compare the rate.

### H2 — Mac not achieving deep standby (constant ~1 W background draw) — TOP (mechanism)
- **Claim:** The Mac spends most of the night in regular sleep (not deep standby/hibernate),
  drawing ~1 W, OR deep standby itself draws ~1 W on this hardware.
- **For:** The ~1 W average draw matches regular sleep, not hibernate (~0.1 W). The rate is
  steady and independent of DarkWake count — consistent with a constant background draw. The Mac
  DOES enter standby (log shows "Wake from Standby"), but it may cycle in/out (each DarkWake
  resets the 600 s standby timer, so it spends ~10 min in regular sleep after each wake).
- **Against:** The log shows "Wake from Standby", so standby IS entered. The standbydelay
  (600 s) is short, so the regular-sleep fraction from DarkWake cycling is small (~40 min/night).
- **Test:** (a) Full-night pmset log: measure time in each state (sleep vs standby vs DarkWake)
  + the interval from sleep entry to standby. (b) Check disk free space + /var/vm/sleepimage
  (if the disk is full, hibernation fails and the Mac stays in regular sleep). (c) Check
  overnight assertions (any process holding a sleep preventer). (d) Measure ioreg amperage /
  energy (mWh) in sleep vs. the % drop (distinguishes real draw from gauge artifact).

### H3 — Aging battery (high internal resistance + gauge miscalibration) — MEDIUM (modifier)
- **Claim:** The aged battery (Health 75.9%, Cycle 568) has high internal resistance, so the %
  drops faster under load, and the gauge is miscalibrated (jumps prove it).
- **For:** Gauge jumps (60%→72%, 83%→90%) prove the % is unreliable. The battery is 14 years old.
  01-PROJECT.md lists "aging battery" as a blocker.
- **Against:** Chemical self-discharge alone is ~1–2%/month, not 1.6%/h — there must be an active
  load. So the battery amplifies the % drop but is not the sole cause.
- **Test:** (a) Compare % drop vs. actual energy (ioreg: CurrentCapacity/MaxCapacity in mAh +
  Amperage) over a night. (b) Gauge recalibration (full discharge + charge — the Calibration
  phase, Red, separate approval). (c) Long-term: battery replacement (hardware, out of scope).

### H4 — USB wireless device (kernel USB assertion) — HIGH (testable)
- **Claim:** The attached USB "Wireless Device" (likely a mouse/keyboard receiver) holds a kernel
  USB assertion (0x4=USB) that prevents deep standby and/or draws power.
- **For:** Assertions (14:47) show "Kernel Assertions: 0x4=USB, id=519, level=255,
  description=com.apple.usb.externaldevice.14100000, owner=Wireless Device". It is a constant
  factor (always attached), consistent with the steady rate. USB devices are a known sleep-drain
  cause (they keep the USB bus powered).
- **Against:** The assertion was observed in the daytime; not confirmed overnight. Many Macs have
  USB receivers without 1.6%/h drain.
- **Test:** One controlled night with the USB device unplugged (user action; needs approval) —
  compare the rate. Check the pmset log for USB wake reasons overnight.

### H5 — Time Machine / Spotlight (mds_stores) running overnight — LOW-MEDIUM
- **Claim:** Time Machine backups or Spotlight indexing run during the night (during DarkWakes)
  and drain the battery.
- **For:** Daytime: mds_stores holds a BackgroundTask; Time Machine (backupd) ran 4× during the
  day (13:24–14:25); pmset shows "sleep prevented by mds_stores, UserEventAgent" (daytime).
- **Against:** Overnight DarkWakes are bluetoothd, not backupd. No Time Machine wake reason in
  the overnight log. Backups are daytime (when the user is active).
- **Test:** Check pmset log + Time Machine log for an overnight backup; check if Spotlight is
  indexing (mds_stores) overnight.

### H6 — BC component / old battopt daemon keeping the Mac awake — RULED OUT
- **Claim:** (Ruled out.) The watchdog (60 s), powerwatch, or the old daemon wakes the Mac or
  discharges it overnight.
- **Against:** Diagnosis (2026-11-11) found no BC wake (DarkWakes are RTC/Maintenance +
  bluetoothd only), no discharge loop (monotonic % decline on battery), watchdog does not run
  during standby (LaunchAgent). The drain rate predates BC (baseline Oct 2026, before BC
  deployment). The old daemon holds only on AC.
- **Test:** None needed (already ruled out). If a future night shows a BC wake reason, re-open.

### H7 — Battery standbydelay 600→300 s (tighten) — LOW impact
- **Claim:** Tightening the battery standbydelay from 600 s to 300 s reduces the regular-sleep
  window.
- **For:** 01-PROJECT.md line 32 lists it as a "post-average candidate only, battery only".
- **Against:** Saves ~5 min of regular sleep per night (negligible vs. a 10-h night).
  Not the root cause.
- **Fix:** pmset -b standbydelay 300 (and standbydelaylow/high 300) — a pmset change (Red,
  needs approval). Low risk, low impact. Consider only as a minor tweak alongside the real fix.

### H8 — Gauge artifact (the % drop overstates the real energy drain) — MEDIUM (modifier)
- **Claim:** The % reading drops faster than the actual energy (miscalibrated gauge on an aged
  battery), so the "1.6%/h" overstates the true drain.
- **For:** Gauge jumps (60%→72% in 5 min; 83%→90% in 1m38s) prove the % is unreliable by ~10%.
  The true overnight drain may be ~15% (86.8%→~72%) not ~27%.
- **Against:** The % decline is steady and monotonic (not random noise), and the user perceives
  a real effect (the battery is lower in the morning). So there IS real drain; the gauge may
  amplify it.
- **Test:** Compare % vs. ioreg energy (mWh / mAh) over a night. Recalibrate the gauge
  (Calibration phase).

---

## 3. Diagnostic plan — Phase S1 (confirm the cause)

**Goal:** Measure a full night and distinguish H1/H2/H4/H8. **Read-only** (no settings changed).
**Needs approval** (formal overnight test on a named night, unchanged v2 settings — per the hard
test gate, 01-PROJECT.md line 52).

### 3.1 The diagnostic night (named night, unchanged settings)
- Yousef closes the lid at a known time + % (he records: time, %, plugged/unplugged). He does NOT
  change any settings. He sleeps normally.
- In the morning, he opens the lid and records: time, % (immediately at wake, before charging),
  plugged/unplugged.
- The next morning (tunnel up), read: (a) full pmset -g log for the night (all Sleep/Wake/DarkWake
  + the % at each event + assertion entries), (b) the watchdog log (the overnight % timeline —
  capture it FIRST thing, before it rotates; the log only retains ~4 h, so read it promptly),
  (c) pmset -g assertions (current), (d) ioreg AppleSmartBattery (CurrentCapacity, MaxCapacity,
  Amperage, Voltage, CycleCount, Health), (e) disk free space (df -h) + /var/vm/sleepimage size,
  (f) the USB device state (is the wireless receiver attached? ioreg / system_profiler SPUSBDataType),
  (g) Bluetooth state (is Bluetooth on? system_profiler SPBluetoothDataType), (h) Time Machine last
  backup time (tmutil latestbackup or the backupd log).

### 3.2 What each measurement distinguishes
- Time in each state (sleep vs standby vs DarkWake) + DarkWake count/durations → H1 vs H2.
- Assertions overnight (USB, Bluetooth, Time Machine, mds) → H4, H5.
- Disk free + sleepimage → H2 (hibernation failing).
- ioreg energy (mWh) vs. % → H8 (gauge artifact) and the true power draw (W).
- The % at sleep entry vs. wake (Yousef's numbers) → the exact rate.

### 3.3 Data gaps (what is still needed)
- A FULL night of pmset log (the 2026-11-11 diagnosis only had the tail from 06:54; the
  sleep-entry time + % are missing).
- Whether the USB wireless device was attached overnight (not confirmed).
- Whether Bluetooth was on overnight (not confirmed).
- Whether Time Machine ran overnight (not confirmed).
- The ioreg energy (mWh) vs. % (to test the gauge artifact).
- Disk free space + sleepimage (to test hibernation).

---

## 4. Fix options (per cause)

| Cause | Fix (exact change) | Risk | Approval |
|---|---|---|---|
| H1 Bluetooth DarkWakes | Turn off Bluetooth before sleep (user action each night, or a sleep-watcher script that disables Bluetooth on sleep + re-enables on wake). Or disable "Allow Bluetooth devices to wake this computer" (System Preferences > Bluetooth > Advanced). | Loses Bluetooth overnight (headphones, Apple Watch unlock, Handoff). Low risk (he is asleep). | YES — behaviour change; needs his approval. (A script that toggles Bluetooth is a system change.) |
| H2 Not deep standby | (a) Tighten battery standbydelay 600→300 s (`sudo -n pmset -b standbydelay 300` + standbydelaylow/high 300). (b) If hibernation is failing (disk full / sleepimage), free disk space. (c) If an assertion blocks standby, address the asserting process. | (a) Minimal (5 min/night saved). (b) Freeing disk is safe. (c) Depends on the process. | YES — (a) is a pmset change (Red). (b) and (c) need his approval (they change the system). |
| H3/H8 Aging battery / gauge | Recalibrate the gauge (Calibration phase: full discharge + charge). Long-term: battery replacement (hardware, out of scope). | Calibration is a full discharge (Red, stresses an aged battery). Replacement is a hardware repair. | YES — Calibration is a separate phase + Red (full discharge). Replacement is his decision (not BC). |
| H4 USB device | Unplug the USB wireless receiver before sleep (user action each night). Or use a Bluetooth mouse/keyboard instead (but that conflicts with H1). | Loses the wireless mouse/keyboard overnight (he is asleep — no impact). Very low risk. | YES — it is a user habit change; needs his agreement (but it is his action, low risk). Test first (one night unplugged) to confirm. |
| H5 Time Machine / Spotlight | Disable automatic Time Machine backup during sleep (Time Machine preferences) or ensure indexing is complete before sleep. | Might delay backups (they will run when awake). Low risk. | YES — a settings change; needs his approval. |
| H7 standbydelay tweak | pmset -b standbydelay 300 (see H2a). | Minimal. | YES — pmset change (Red). |

---

## 5. Phases (each needs its own separate approval)

- **Phase S1 — Diagnose (confirm the cause).** One formal diagnostic night (named night, unchanged
  v2 settings) + the full-night capture (Section 3.1) + analysis. Read-only.
  **Needs approval** (formal overnight test — hard test gate, 01-PROJECT.md line 52).
- **Phase S2 — Test the top fix (single variable).** Apply the single most likely fix from S1
  (e.g., unplug USB for one night, OR Bluetooth off for one night — ONE variable at a time) and
  measure the drain over 1–2 nights. **Needs approval** (it changes the setup; if it is a pmset
  change, it is Red).
- **Phase S3 — Apply + verify.** Apply the confirmed fix (the setting/script change) and measure
  over 2–3 nights to confirm the drain is reduced (target: well below 1.2%/h, ideally <0.5%/h).
  Update the docs (01-PROJECT.md sleep-drain section). **Needs approval** (the fix goes live;
  if pmset, Red).
- **Phase S4 (optional) — Gauge recalibration.** If H8 is significant (the gauge is misreporting),
  run the Calibration phase (full discharge + charge). **Separate approval** (Red — full discharge
  on an aged battery).
- **Workaround (already in effect, no approval needed):** Leave the Mac plugged in overnight — it
  holds at 86% (BCLM=10) and does not drain. This is the practical mitigation until the root cause
  is fixed. (Yousef was told this 2026-11-11 14:52 EET.)

---

## 6. Risks / constraints

- No pmset/sleep changes without Yousef's explicit approval (Red). No overnight tests without
  approval on a named night (hard test gate). No SMC writes, no daemon loads (Phase C),
  no commit/push.
- The tunnel flaps (it went down 3× on 2026-11-11). The diagnostic-night capture must be read the
  next morning while the tunnel is up; if it is down, the watchdog log may rotate before it is read
  (the log only retains ~4 h). Mitigation: read the pmset log (it persists) as the primary source;
  capture the watchdog log first thing.
- The gauge is unreliable (±10%), so %-based rates have an error bar. Use ioreg energy (mWh)
  alongside % to get the true drain.
- Do not conflate the overnight battery drain with the AC charging loop (they are different issues;
  the loop is an AC phenomenon, the drain is a battery-sleep phenomenon).

---

## 7. Files / references

- Investigation note: ~/workspace/bc-build/sleep-drain-investigation-note.md (local) + Mac copy
  (not made — tunnel down at the time).
- Diagnostics: ~/workspace/bc-build/sleep-drain-diag-20261111.txt (34,281 B),
  sleep-drain-diag2-20261111.txt (14,594 B).
- 01-PROJECT.md lines 32–33, 38–40, 48, 50–52, 66, 69–70, 116.
- power_saver.sh (src/daemon-helpers/, 6,228 B, W4.3) — default profile only (battery 600/600/1800,
  AC 10800/10800/3600, sleep 90); powernap 0, womp 0, tcpkeepalive 0, acwake 0, hibernatemode 25.
- sleep_manager.sh (src/daemon-helpers/, 2,741 B, Layer 13) — profiler-only, records
  .sleep_profile, applies NO pmset.

---

**Top hypothesis:** H2 (Mac not achieving deep standby — ~1 W background draw, consistent with regular
sleep) with H4 (USB wireless device) and H1 (Bluetooth DarkWakes) as the most testable contributors.
**Most testable first step:** a diagnostic night (S1) measuring time-in-state + assertions + ioreg energy,
followed by a single-variable USB-unplugged night (H4) and a Bluetooth-off night (H1).

**Data still needed:** a full diagnostic night (sleep-entry time + %, full pmset log, overnight
assertions, USB/Bluetooth state overnight, Time Machine overnight, disk free + sleepimage, ioreg energy
vs. %).
