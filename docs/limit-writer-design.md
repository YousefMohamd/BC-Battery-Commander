# Limit Writer Design (Battery Commander)
## Status: DRAFT v2 — awaiting user approval before building
## Date: 2026-11-08 (v2: runtime probing added; v1 2026-11-07)
## Based on: Deep RE findings (deep-re-notes.md) + live observation (hold → discharge → charge → hold cycle) + Mac compatibility research (research_notes/mac-battery-charge-limit-compatibility-20261107-2035/report.md) + full audit (audit-report.md)

### 1. Goal
An independent program (`bc-limit`) that enforces a charge limit (upper/lower %) by toggling the charge-control key the machine actually has — without using battopt. On this Mac (MacBook Pro 9,1, Catalina) that key is BCLM; on other Macs it is a different key or Apple's native limit (see §2). It mirrors battopt's proven mechanism but is implemented independently from public SMC documentation.

### 2. Runtime probing (NEW — multi-Mac support)
No published model-year → SMC-key table exists. The tool must probe keys/firmware at runtime and branch on architecture + firmware, not model ID. This is what bclm, batt, AlDente, and the Asahi driver do.

#### 2.1 Probe order
At startup (and on every invocation before acting), `bc-limit` probes in this order and selects the FIRST working backend:
1. **BCLM exists (readable)** → Intel backend (§2.2, row 1). This Mac.
2. **CHLS exists** → Apple Silicon firmware-limit backend (§2.2, row 5).
3. **CHWA exists** → Apple Silicon fixed-80 backend (§2.2, row 4).
4. **CHTE exists, else CH0B/CH0C exist** → Apple Silicon legacy-toggle backend (§2.2, row 3).
5. **Apple native Charge Limit available** (macOS 26.4+, Apple Silicon, via powerd) → native backend (§2.2, row 6).
6. **Adapter toggle available** (ungated wall-power key) → adapter backend (§2.2, row 7).
7. **Nothing available** → monitor-only mode: report status, enforce nothing, exit 0 with a clear log line. Never guess a key, never write a key that was not probed present and writable.

Probing is read-only: key existence is tested by an SMC read (KeyInfo). A key that reads is not automatically writable — writability is established by the first real write attempt and its read-back verification (§5). If a write fails with a privilege error (`kIOReturnNotPrivileged`), the backend is marked unavailable for this run and the next backend is tried; the failure is logged.

#### 2.2 Per-family mechanism table

| Family | Key(s) | Values | How a % limit is enforced | Persistence |
|---|---|---|---|---|
| Intel (this Mac, 9,1) | BCLM (ui8) + optional BFCL (LED) | 10 = hold, 100 = resume (bc-limit writes only 10/100; the % lives in config) | Daemon loop: % ≥ upper AND BCLM=100 → write 10; % ≤ lower AND BCLM=10 → write 100 | Persists across sleep/reboot; SMC reset clears it |
| Intel ≤2015 ("classic" key) | Unknown FourCC — NOT in any source; do NOT invent it | — | NOT SUPPORTED in v1. If BCLM is absent on an Intel Mac, fall through to monitor-only and log it. A later phase may identify the classic key from hardware testing. | — |
| Apple Silicon, firmware <13.0 / early | CH0B + CH0C (ui8; 00 allow / 02 inhibit) or CHTE fallback (ui32; 00000000 allow / 01000000 inhibit) | On/off only — no % in hardware | Daemon polls % and toggles inhibit: % ≥ upper → inhibit; % ≤ lower → allow. Both CH0B and CH0C written together (redundancy). | Volatile — reset on sleep/wake/reboot; needs the daemon running |
| Apple Silicon, firmware ≥13.0 | CHWA (flag) | 80 or 100 only | Set the flag for an 80% ceiling (or clear for 100%). Limits other than 80 are NOT achievable with CHWA alone — if the user sets a different limit, bc-limit clamps to 80 and logs that the firmware only supports 80/100. | Resets on reboot |
| Apple Silicon, newer firmware (macOS 27-era, 20xxx) | CHLS (u16; low byte = end %) | Write 0x100 \| value (value = end %, min 10) | Write the end % directly; firmware enforces it including during sleep. Read-back: charge_limit = (CHLS & 0xff) − 5. | Firmware-enforced incl. sleep |
| Apple Silicon, macOS 26.4+ | Apple's native Charge Limit (powerd/PowerUIAgent) | 80–100% in 5% steps (Settings); batt native mode 10–99% on macOS 27 Beta 4+ | Set the native limit via the private client interface (`pmset -g battlimit` to verify). No SMC write by the tool. | Enforced by powerd incl. sleep; suspended ~every 3 weeks for a calibration full charge (~12 h) — the tool cannot prevent this |
| Apple Silicon, gated firmware (macOS 27 Beta 4+, some 15.x/26.x security updates) | All SMC charge keys gated behind com.apple.private.iokit.soc-limit (kIOReturnNotPrivileged even as root) | — | SMC backends unavailable. Fall back to native limit (≥80%) or adapter toggle only. | — |
| Apple Silicon, macOS 15.x with late firmware that removed CHTE (e.g. 15.8), before 26.4 | No SMC inhibit, no native limit | — | MONITOR-ONLY. Log it clearly. | — |

#### 2.3 Backend selection and fallback
- The selected backend is recorded in the log on every invocation (key probed, backend chosen, reason).
- If the selected backend's write fails (privilege error, key not found on write, read-back mismatch), bc-limit logs the failure, marks that backend unavailable for this invocation, and tries the next backend in the probe order. It never retries the same failed write in a loop.
- The user can force a backend with `--backend <name>` (for testing only); in normal operation the probe decides. Forcing a backend that was not probed present is rejected.

#### 2.4 Hard limits (do not cross)
- **No SMC writes on macOS ≥15 where the kernel gates them.** Direct SMC writes are dead on macOS ≥15.0 (kernel entitlement enforcement; the only workaround is disabling SIP — NOT acceptable for a published tool). If the probe finds the keys gated (`kIOReturnNotPrivileged`), bc-limit must NOT attempt SMC writes; it falls back to the native limit or adapter toggle, or monitor-only.
- **No SMC writes on gated firmware (macOS 27 Beta 4+, some 15.x/26.x security updates).** Same rule: fall back, never force.
- **No invented keys.** The Intel ≤2015 "classic" key is unnamed in every source — do NOT invent a FourCC. If BCLM is absent on Intel, monitor-only.
- **Intel has NO Apple native limit ever.** Do not offer the native backend on Intel.
- **CH0C inhibit value is unsettled** (02 in most macOS tools, 01 in the Asahi LKML driver, 2-or-3 in BatFi). v1 writes 02 (the macOS-tools consensus) and verifies by reading back the charging state (IsCharging). If verification fails, the backend is marked unavailable and the next backend is tried. This is an open question to resolve on hardware (§9).
- **CHTE vs CH0B/CH0C generation order is conflicting between tools.** Probe CHTE first, fall back to CH0B/CH0C, or vice versa — never assume by model. The probe order in §2.1 tries CHTE before CH0B/CH0C; if a machine has both, either works (both are on/off inhibit).
- **Monitor-only is a valid outcome.** On machines/firmwares with no working mechanism, bc-limit reports status and enforces nothing. It must say so clearly in the log and in `bc-limit status` output — never pretend to enforce.

### 3. Mechanism (proven on this Mac; per-family in §2)
- The limit % (e.g. 86) is NEVER written to the SMC. It is stored in a config file.
- A control loop watches battery %.
  - % >= upper limit AND charging enabled → write the backend's "hold" value (BCLM=10 on this Mac).
  - % <= lower limit AND charging disabled → write the backend's "resume" value (BCLM=100 on this Mac).
  - Otherwise → do nothing (no write).
- On this Mac, BCLM is a binary toggle: 10 = charging disabled (hold), 100 = charging enabled. Proven by Deep RE (disable_charging hardcodes BCLM=10; enable_charging writes 100) and confirmed by live observation (BCLM=10 in both hold states, 100 in both non-hold states, 4-for-4).
- CHLC, BATP, CHGC are NOT written by battopt (0 string matches); they are read-only indicators / system side effects. We do not write them.

### 4. Components (updated)
- `bc-limit` (C binary, in bc-build/): probes the backend (§2), reads % (ioreg), reads the control key (SMC read), writes the control key (SMC write, only on state change), logs everything. Takes upper/lower from config or args.
- `bc-probe` (part of bc-limit, or a `--probe` flag): prints the probed keys, the selected backend, and the reason. Read-only; used for diagnostics and for building the empirical model→key table (log the probed keys per model).
- `limit.conf` (config, in bc-build/): LAST_UPPER, LAST_LOWER (same format as the existing config).
- Control loop: `bc-limit` runs once per invocation (probe + check + write-if-needed + exit). A launchd plist (or a simple loop) calls it every 60 seconds. For v1, a simple periodic invocation (not a long-running daemon) — simpler, safer, each run independent. Note: on Apple Silicon with volatile keys (CH0B/CH0C/CHTE), the loop must run continuously (the daemon must stay alive) because the keys reset on sleep/wake/reboot — the launchd KeepAlive entry is required there, not optional.
- Logging: every probe result, check/decision/write to `bc-build/limit.log` with timestamp.

### 5. SMC Write (the sensitive part)
- The read path is proven (smc_reader_v6: correct 80-byte SMCKeyData_t, commands 9+5, no sudo needed).
- The write path must be implemented from PUBLIC SMC documentation (the standard SMC write command), written from scratch — NOT copied from battopt. The write function will be reviewed before any test.
- Write functions (one per backend, each restricted to its own key and values):
  - Intel: `smc_write_bclm(uint8_t value)` — only accepts 10 or 100; only key 0x42434c4d (BCLM). BFCL (MagSafe LED) is NOT written in v1.
  - Apple Silicon legacy: `smc_write_ch0b_ch0c(uint8_t value)` — only 00 (allow) or 02 (inhibit); writes both CH0B and CH0C. `smc_write_chte(uint32_t value)` — only 0x00000000 or 0x01000000.
  - Apple Silicon firmware: `smc_write_chwa(...)` — flag only (80/100). `smc_write_chls(uint16_t value)` — only 0x100 | end% (end% 10–100).
  - Native backend: no SMC write at all.
- Verification: after every write, read the key back and confirm it equals the intended value. If read-back fails or mismatches, log an error and exit (no retry loop). For CH0B/CH0C, verify by reading the charging state (IsCharging) as well, because the inhibit value (01 vs 02) is unsettled.
- If a write fails with a privilege error (`kIOReturnNotPrivileged`), the backend is marked unavailable and the next backend in the probe order is tried (§2.3). Never retry the same failed write.

### 6. Safety rules (hard, in code) — unchanged, now probe-aware
1. Only the probed key, only the documented values for that backend (BCLM 10/100; CH0B/CH0C 00/02; CHTE 0x00000000/0x01000000; CHWA flag; CHLS 0x100|end%). Any other key/value is rejected by the code. Never write a key that was not probed present.
2. Read before write: read % and the control key first. If either read fails, or % is outside 0–100, or the key is not in its expected state → do NOT write, log and exit.
3. Only write on state change: if the key already equals the desired value → do nothing.
4. Never write the "resume" value if % > upper limit (prevents overcharging). Only write resume if % <= lower limit.
5. Rate limit: at most one write per invocation; invocations at most once per 60 s.
6. No sudo: if the write needs sudo, STOP and tell the user (the user runs it). The assistant never runs sudo. Note: on Catalina, SMC writes require root — the enforcer will run as a minimal root LaunchDaemon (see audit-report.md §4.3); the UI and the sleep watcher stay unprivileged.
7. Dry-run mode: v1 ships with a --dry-run flag (default in testing) that logs what it WOULD write without writing. --dry-run also logs the probe result and the selected backend.
8. (NEW) Never write on a gated machine: if the probe reports `kIOReturnNotPrivileged`, no SMC write is attempted in that invocation.
9. (NEW) Monitor-only is not an error: if no backend is available, exit 0 with a clear log line. Do not fake enforcement.

### 7. Testing (phased, each needs its own approval) — unchanged
- Phase A (read-only / dry-run): Build bc-limit with --dry-run. Run it across states (hold, charging, discharging) and verify it makes the correct decisions (would write 10 / would write 100 / would do nothing) without writing anything. Also verify the probe: run `--probe` and confirm it selects BCLM on this Mac and logs the reason. Pass = decisions match the expected state in every sample, and the probe selects the right backend.
- Phase B (single controlled write, separate approval): After Phase A passes, ONE write test in a safe state. Safest first write: when BCLM is already 10 (holding) and % is at the limit, write BCLM=10 (same value — tests the write path without changing state). Read back immediately to confirm. Monitor % and charging state after. If anything unexpected happens, stop and report.
- Phase C (full cycle, separate approval): After Phase B passes, test a full cycle (let % drop to lower, confirm BCLM=100 is written and charging resumes; let % rise to upper, confirm BCLM=10 is written and charging stops). Daytime only, user present.
- Note: Phases A–C run on this Mac (BCLM backend). Other backends (CHLS/CHWA/CHTE/CH0B/CH0C/native/adapter) are validated by probe + dry-run on hardware that has them, when such hardware is available — they are NOT tested by writing to keys on this Mac, which does not have them.

### 8. What needs approval
- This design (now, v2).
- Build (Phase A) — after design approval.
- First write test (Phase B) — separate approval, with a specific test plan.
- Full cycle test (Phase C) — separate approval.

### 9. Open questions (updated)
- Does the SMC write need sudo on this Mac? (Read does not. The first write test will reveal it. If yes, the user runs it — and the enforcer runs as a minimal root LaunchDaemon; see audit-report.md §4.3.)
- The exact SMC write command number (from public docs; to be confirmed in the build, before any test).
- Poll interval: 60 s is the starting point (matches the observation cadence). May be tuned later. On Apple Silicon with volatile keys, the loop must stay alive (KeepAlive) — 60 s polling is still the cadence, but the daemon must not exit between polls.
- CH0C inhibit value: 02 (macOS tools) vs 01 (Asahi LKML) vs 2-or-3 (BatFi). v1 writes 02 and verifies via charging state. Resolve on hardware that has CH0B/CH0C.
- CHLS vs CHWA firmware cutover: no published mapping; the probe decides per machine. Log the probed keys per model to build the table empirically.
- Does BCLM work before Catalina (10.15.5)? Disputed in sources; treat pre-Catalina as untested, not supported-by-design.
- The native-limit backend (macOS 26.4+, Apple Silicon) is driven through reverse-engineered private interfaces (`pmset battlimit` / private client class) — no documented public API. Its exact call sequence needs a separate small research/build step before implementation; it is NOT in the v1 build scope (v1 = BCLM backend on this Mac + probe + monitor-only fallbacks).
- The adapter-toggle backend (ungated wall-power key) needs the exact key identified per firmware; it is a fallback only, not in the v1 build scope.

### 10. Files
- Design: battopt-project/bc-build/limit-writer-design.md (this file)
- Audit: battopt-project/bc-build/audit-report.md
- Spec/plan: (Spec Kit spec + Superpowers plan to be written after design approval)
- Source: battopt-project/bc-build/bc-limit.c (to be written after approval)
- Config: battopt-project/bc-build/limit.conf
- Log: battopt-project/bc-build/limit.log

### 11. What changed vs v1 (2026-11-07)
- NEW §2 (runtime probing): probe order, per-family mechanism table, backend selection/fallback, hard limits. v1 was BCLM-only for this Mac.
- §1 goal: now "the key the machine actually has", not just BCLM.
- §4 components: added `bc-probe` / `--probe` flag; noted the KeepAlive requirement for volatile Apple Silicon keys.
- §5 SMC write: one write function per backend, each restricted to its key/values; privilege-error fallback to the next backend.
- §6 safety rules: added rules 8 (never write on a gated machine) and 9 (monitor-only is not an error); rule 1 is now probe-aware; rule 6 notes the root LaunchDaemon for the enforcer.
- §7 testing: Phase A now also verifies the probe selects BCLM; other backends validated by probe + dry-run on their own hardware, not by writing on this Mac.
- §9 open questions: added CH0C value, CHLS/CHWA cutover, pre-Catalina BCLM, native-limit and adapter-toggle scope notes.
- Unchanged: the BCLM mechanism itself, all v1 safety rules (1–7), the three testing phases, the approval gates, the file list.
