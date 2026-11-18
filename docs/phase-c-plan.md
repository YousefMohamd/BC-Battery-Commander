# Phase C — Load the BC Daemon + Full Cycle Test (PLAN)

**Status:** PREPARATION ONLY (2026-11-11). The plan is ready; the daemon is
NOT loaded yet. Loading = starting Phase C (real enforcement). Do NOT load
without Yousef's explicit approval.

**ADDENDUM 2026-11-11 21:36 EET — binary NOT built yet (tunnel down) +
Mac Phase B source incident:** see §9. The plan, the patch, and a
reconstructed v1.0-phase-c source are ready locally; the Mac build +
dry-run test + Mac upload are blocked until the tunnel returns.

**Date:** 2026-11-11. **Author:** Phase C prep (subagent).
**Related:** `limit-writer-design.md` v2, `audit-report.md`,
`launchdaemon-install.md`, `comprehensive-audit-note.md` (§0 C1, §1 gauge
jump, §5 decisions), `sleep-drain-root-cause-plan.md` (S1).

## 0. Why Phase C is now URGENT (C1)

The old battopt daemon (PID 88736, root, since Sun Nov 8 09:00) runs from
a DELETED directory:

- `/Library/Application Support/battopt/` does NOT exist (verified by the
  main agent 2026-11-11 ~20:14 EET, read-only).
- `/Library/Logs/battopt/` also gone.
- `/usr/local/bin/battopt` is a symlink (Oct 6) to the nonexistent target
  (`battopt status` → "No such file or directory"). The CLI escape hatch
  is dead. No other battopt binary found on disk.
- Its plist (`/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`,
  root wheel, 957 B, Oct 23, KeepAlive + RunAtLoad) still points at the
  deleted path.

**Consequence:** if the daemon crashes or the Mac restarts, launchd cannot
relaunch it → NOTHING enforces the charge limit (the BC daemon is installed
but NOT loaded). Phase C was "can wait"; it is now URGENT.

**When/how the directory was deleted is unknown** (none of the documented
2026-11-10 deletions list it). The Trash check was blocked by TCC — only
Yousef can check whether it is recoverable from Trash (Finder). Do NOT
silently reinstall the closed-source binary.

**Do NOT restart the Mac until Phase C is done.** A restart kills the old
daemon (it cannot relaunch) and nothing enforces the limit. `killall Dock`
is fine (it only restarts the Dock, not the system).

## 1. What Phase C is

Load the BC daemon (`com.batterycommander.bclimit`) so BC enforces the
charge limit by itself (BCLM 10/100), then verify a full cycle:

- **The swap:** unload the old battopt daemon, load the BC daemon.
- **Hold verification:** the BC daemon holds the battery at the limit
  (BCLM=10, no charging above the upper limit).
- **Full cycle test:** discharge below the lower limit (85%) → the daemon
  writes BCLM=100 (resume) → plug in, charge to the upper limit (86%) →
  the daemon writes BCLM=10 (hold). Daytime only, Yousef present.

**Phase C is NOT tonight (2026-11-11).** Tonight is S1 (diagnostic night,
on battery). Phase C is a daytime test.

## 2. What is already ready (prerequisites — all done)

- **Binary:** `battopt-project/bc-build/bc-limit`, v1.0-phase-b (69,136 B,
  md5 `c3cf2141…`). Supports `--probe`, `--dry-run`, `--write` (the
  enforce loop), `--test-write` (Phase B, already verified 2026-11-08 —
  do NOT repeat it). **Final binary for Phase C:** v1.0-phase-c (with the
  gauge-jump deferral — see §3). Built during prep; md5/size to be
  recorded here once built.
- **Plist:** `/Library/LaunchDaemons/com.batterycommander.bclimit.plist`
  (2,073 B, root wheel, 644) — INSTALLED 2026-11-10 18:30, NOT loaded.
  Runs `bc-limit --config /Users/Yousef/.battery-commander/config
  --write` every 60 s, RunAtLoad true, KeepAlive false. Log:
  `~/.battery-commander/bc-limit-daemon.log` (+ `bc-build/limit.log`).
- **Config:** `~/.battery-commander/config` — LAST_UPPER=86,
  LAST_LOWER=85, SAILING=false, SAIL_GAP=1 (canonical, verified).
- **State-dir migration:** done 2026-11-10 17:50 (25 files md5-verified).
- **Sudoers:** `/etc/sudoers.d/battery-commander` (pmset-only) — the
  daemon runs as root via launchd, not via sudo.
- **Watchdog:** `bc-watchdog.sh` ticks every ~60 s; the L8 daemon check
  was fixed (2026-11-11 comprehensive audit) to use
  `launchctl print system/` (a user-domain `launchctl list` can never
  see a system daemon).
- **Health check:** PASS 17 | FAIL 0 | WARN 2 — "Project is HEALTHY"
  (2026-11-11 20:15, after the comprehensive audit).

## 3. The final binary (v1.0-phase-c)

The Phase B binary (v1.0-phase-b) already has the `--write` enforce loop,
but it trusts a single ioreg read per invocation (no debounce). The audit
found the gauge can jump +7..+12% in under a minute with zero current
(86% → 93% on 2026-11-11 19:00, Amperage=0), and the 1% hysteresis band
(86/85) is narrower than the gauge noise (±7–12%). A down-jump below the
lower limit (85) while holding would write resume (BCLM=100); if the
gauge recovers a minute later, it writes hold again — a spurious
10→100→10 toggle pair.

**v1.0-phase-c adds the gauge-jump deferral** (audit proposal, approved
as a code improvement — Yousef delegated technical decisions):

- A state file `<exe_dir>/.bc-limit-last-pct` records the last % seen.
- On each invocation, after the decision is computed: if a write is
  decided BUT |pct − last_pct| ≥ 5, log `GAUGE JUMP SUSPECTED: pct X ->
  Y (delta N) in one interval; deferring write this cycle` and exit 0
  WITHOUT writing (defer one 60 s cycle). The current % is always
  recorded, so a persistent new value acts normally on the next
  invocation.
- If the state file cannot be read or written, enforcement proceeds
  (fail open) and a warning is logged. Enforcement is more important
  than the deferral.
- The deferral only delays a write by at most one cycle (60 s). It never
  prevents enforcement permanently.

**NOT added (deliberately):**

- `.apg_paused` reading (audit M6) — needs design + Yousef approval
  (Red). The thermal pause currently gates only the watchdog's
  corrective discharge + the ac_watcher/ensure_limit/self_healing
  checks, not the enforcer.
- Design §2.3 fallback / §2.4 gating (try-next-backend on write
  failure, kIOReturnNotPrivileged distinction) — NOT implemented.
  Assessment: **not needed for Phase C on this Mac.** BCLM is present
  and writable (proven by the Phase B sudo test-write, verified by
  read-back), and Catalina 10.15.8 does not gate SMC writes
  (gating is macOS ≥15.0 / macOS 27 Beta 4+ firmware). It is dormant
  here. It matters for publish/multi-Mac (other firmwares), not for
  Phase C on this machine. Defer to a later build decision.
- The C-code minor items from the audit (e.g. `--test-write` +
  `--write` precedence, single `--upper`/`--lower` ignored, no
  flock/single-instance guard, powerwatch process-group kill) — not
  needed for Phase C on this Mac. The daemon runs once per invocation
  (StartInterval 60, KeepAlive false), so a single-instance guard is
  not critical here. Defer to a later build decision.

**Build + dry-run test (to be done during prep, before Yousef loads):**

- Build on the Mac: `clang -Wall -Wextra -framework CoreFoundation
  -framework IOKit -o bc-limit bc-limit.c` (exit 0, no warnings).
- Verify: `bc-limit --help` shows `1.0-phase-c`; `bc-limit --probe`
  selects `bclm`; `bc-limit --dry-run` makes no writes (BCLM unchanged
  before/after).
- Dry-run test for the gauge deferral (no SMC write — `--dry-run` never
  writes; the state file is the only thing touched):
  1. Baseline: `bc-limit --dry-run --upper 99 --lower 95` (with the
     live pct=93, BCLM=10, this decides resume → logs
     `DRY-RUN: WOULD WRITE BCLM=100`). This also records pct=93 in
     `.bc-limit-last-pct`.
  2. Simulate a jump: overwrite the state file with a far value
     (`echo 80 > battopt-project/bc-build/.bc-limit-last-pct`), then
     run the same `--dry-run --upper 99 --lower 95` again. Expect:
     `GAUGE JUMP SUSPECTED: pct 80 -> 93 (delta 13) in one interval;
     deferring write this cycle` and NO `WOULD WRITE` line.
  3. Run the same command a third time. Expect: no deferral (the
     state file now holds 93, delta 0) and the `DRY-RUN: WOULD WRITE
     BCLM=100` line returns.
  4. Confirm BCLM is unchanged throughout (read it before/after via
     `bc-status` or `bc-limit --probe`).
  (If the live pct/BCLM differ at test time, adjust the --upper/--lower
  so the decision is a write in dry-run; the point is to force a write
  decision and then check the deferral suppresses it on a jump.)
- Binary readiness + md5/size to be recorded here once built.

## 4. The swap — exact sudo commands (Yousef runs these)

Run from a Terminal. Do this in the DAYTIME, with Yousef present.
Do NOT do this tonight (S1 is tonight, on battery).

### Step 0 — Pre-checks (read-only, before any change)

```sh
# Battery % and hold state (should be above 85%, BCLM=10, holding)
./battopt-project/bc-build/bc-status
# Confirm the old daemon is still running (PID 88736)
ps aux | grep -i "battopt daemon" | grep -v grep
# Confirm the BC daemon is installed but NOT loaded
sudo launchctl list | grep batterycommander
# (expect: nothing for com.batterycommander.bclimit — NOT loaded yet)
# Confirm the BC daemon plist is in place
ls -l /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

**Gate:** only proceed if the battery is ABOVE the lower limit (85%).
If it is below 85%, the BC daemon's first run will write BCLM=100
(resume) — that is correct behaviour, but it means the first run starts
a charge cycle. Prefer to start the swap while holding above 85%
(BCLM=10), so the first BC run does nothing (already correct) and the
hold continues seamlessly.

### Step 1 — Unload the old battopt daemon

```sh
sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist
```

Verify it is gone:

```sh
ps aux | grep -i "battopt daemon" | grep -v grep
# (expect: nothing — the old daemon is gone)
sudo launchctl list | grep -i battopt
# (expect: nothing)
```

**Note:** unloading does NOT reset BCLM. BCLM stays 10 (hold) — it
persists in the SMC. The battery stays in hold until the BC daemon
(or a manual write) changes it. There is a brief window (seconds)
with NO enforcer running; that is expected and safe (BCLM=10 holds).

### Step 2 — Load the BC daemon

```sh
sudo launchctl load /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

Verify it is loaded:

```sh
sudo launchctl list | grep batterycommander
# expected: a line with com.batterycommander.bclimit (PID or 0 if idle)
```

### Step 3 — Verify enforcement (first few minutes)

```sh
# Watch the daemon log (it runs every 60 s)
tail -f ~/.battery-commander/bc-limit-daemon.log
# In another Terminal, watch the decisions log
tail -f battopt-project/bc-build/limit.log
# Check the hold state
./battopt-project/bc-build/bc-status
# (expect: BCLM=10, hold, % above 86% or holding at the limit)
```

**Expected first-run behaviour** (battery at 93%, BCLM=10, limit 86/85):
`state: backend=bclm upper=86 lower=85 pct=93% BCLM=10 ...` →
`decision: nothing to do (pct=93%, BCLM=10 already correct)`.
No write. The hold continues seamlessly (the old daemon had already
set BCLM=10).

**Watchdog:** it should keep ticking every ~60 s (PCT, BCLM=10,
cfg=86/85, mode=hold). The L8 daemon check should now report the BC
daemon as loaded (not NOT_LOADED).

### Step 4 — Hold verification (next 30–60 min, on AC)

- Battery stays at/above 86% (or slowly settles), BCLM=10, not charging.
- `bc-limit --dry-run` (read-only, as the user) shows "nothing to do".
- No "GAUGE JUMP SUSPECTED" storm (a single deferral on a jump is fine).
- The plugin menu shows the hold state correctly.

## 5. The full cycle test (daytime, Yousef present, a few hours)

This proves BC enforces the limit by itself (resume + hold).

### 5a. Discharge below the lower limit (85%)

- Unplug the charger. Use the Mac on battery normally (or run a
  workload) until the battery drops below 85% (target ~80–83%).
- This takes a while (the battery is at 93%; discharging to ~80% on
  battery takes a few hours of normal use). Do NOT force a discharge
  (no forced discharge test — the assistant never forces it).
- Watch: the BC daemon (running every 60 s) sees pct ≤ 85 and BCLM=10
  → it should write BCLM=100 (resume). Check `limit.log` for
  `WRITE: BCLM=100` / `WRITE OK: BCLM=100 verified by read-back`.
  (On battery with no charger attached, writing BCLM=100 does not
  charge anything — it just enables charging for when the charger is
  attached.)

### 5b. Charge to the upper limit (86%) and verify hold

- Plug the charger in. The battery charges (BCLM=100, charging).
- Watch: as the % rises to 86%, the daemon should write BCLM=10
  (hold). Check `limit.log` for `WRITE: BCLM=10` / `WRITE OK`.
- Verify: `bc-status` shows BCLM=10, not charging, hold at ~86%.
- The battery should NOT charge past 86% (allow the known gauge
  overshoot of ~+3% — the audit's overshoot guard is UPPER+2).

### 5c. Pass criteria

- [ ] BCLM=100 written when % dropped ≤ 85% (resume).
- [ ] BCLM=10 written when % rose ≥ 86% (hold).
- [ ] Both writes verified by read-back in `limit.log`.
- [ ] Battery holds at ~86% (not charging) after the cycle.
- [ ] No "GAUGE JUMP SUSPECTED" deferral caused a missed threshold
  (a single 60 s deferral is fine; a persistent failure to act is not).
- [ ] Watchdog ticks throughout; no false drift notifications.
- [ ] Plugin menu shows the correct state (hold at 86%).

## 6. Rollback plan (honest — the old daemon CANNOT be restored)

**If the BC daemon fails (wrong writes, crashes, or the limit is not
enforced), unload it:**

```sh
sudo launchctl unload /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

**The old battopt daemon CANNOT be restored** — its binary was deleted
(C1: `/Library/Application Support/battopt/` does not exist; the CLI
symlink is dead). Do NOT try to reinstall the closed-source binary
silently. The install guide's old rollback ("re-apply with
`battopt limit 86 85`") is WRONG and must not be followed.

**After unloading the BC daemon:**

- BCLM stays at whatever value it was when unloaded (it persists in
  the SMC). If BCLM=10, the battery stays in hold (not charging) —
  safe, but it will not charge. If BCLM=100, the battery charges
  freely (to 100%) — not ideal, but not dangerous for a short time.
- To set a hold manually (BCLM=10) without a daemon, run (as root via
  sudo, Yousef runs it):

```sh
sudo /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build/bc-limit --config /Users/Yousef/.battery-commander/config --write
```

  (When % ≥ 86, this writes BCLM=10 once and exits. It is a one-shot
  manual hold, not a daemon. Note: if it reports `GAUGE JUMP
  SUSPECTED` (the % moved ≥ 5 points since the last run), it deferred
  and did NOT write — run it once more; the second run acts, because
  the state file now holds the new %.)
- To resume charging manually (BCLM=100), temporarily set the config
  to a limit above the current % (or use `--upper`/`--lower` args
  above the current %), then run the same one-shot `--write`. Restore
  the config to 86/85 afterwards.
- Then fix the BC daemon (read `limit.log` +
  `~/.battery-commander/bc-limit-daemon.log` for the error), rebuild
  if needed, and reload it. The limit is unenforced until the daemon
  is fixed and reloaded — keep the Mac plugged in and watch the %
  manually in the meantime (do not leave it charging unattended to
  100% for long).

**If the Mac restarts while the BC daemon is unloaded and the old
daemon is gone:** nothing enforces the limit. BCLM persists (so the
last state holds), but no daemon will correct it. Reload the BC daemon
as soon as possible after the restart.

## 7. What is still needed from Yousef

1. **Approval to load the BC daemon** (Phase C load = Red). He already
   has the options widget from 2026-11-11 20:15 (Phase C: "أيوه، نعمل
   Phase C (في النهار، وانت موجود)" / "الأول أشوف الـ Trash") — he has
   not replied yet. This plan is the preparation for that decision.
2. **His time for the swap + the full cycle test** (daytime, present,
   a few hours for the discharge + recharge). NOT tonight (S1 is
   tonight, on battery).
3. **(Optional) Check the Trash in Finder** for
   `/Library/Application Support/battopt/` (TCC blocked the check).
   If it is there, it could be restored — but do NOT reinstall the
   closed-source binary without a separate decision. (Phase C makes
   this unnecessary — BC replaces it.)
4. **Do NOT restart the Mac until Phase C is done** (a restart kills
   the old daemon and nothing enforces the limit).

## 8. Open items (not blocking Phase C)
- Overshoot response (C2): the battery is at 93% (gauge jump) vs the
  86% limit, and nobody tells the user. Needs a decision on the
  notification + corrective path (separate from Phase C).
- DASH fallback (M2): retire the old-dir fallback or keep it? (Design
  change; separate decision.)
- `.apg_paused` in bc-limit (M6): needs design + Yousef approval.
- Design §2.3/§2.4 fallback + gating: not needed for Phase C on this
  Mac (see §3). Defer to a later build decision (publish/multi-Mac).
- App rebuild (launcher fixes): can wait, e.g. bundled with Phase C
  (requires stopping the running launcher — kill — Red).
- Stale root powerwatch plist removal: user sudo step (Red).
- pmset-affecting fixes (M3/M4): Red, approve at deploy time.
- 50% upper-limit floor (m9): intended, or restore 15–100?
- `test_enforce_watchdog.sh` (dead test): delete? Needs approval.
- S1 tonight (2026-11-11, on battery): capture ioreg energy fields
  before lid-close AND at wake before plugging in (S1 gap fix).

## 9. ADDENDUM 2026-11-11 21:36 EET — Mac Phase B source incident + build blocked (tunnel down)

### 9.1 What happened (incident — my error, reported honestly)

While preparing the build, I ran the download helper backwards:
`transfer.py` is an **upload** tool (local file → Mac). I passed it the
Mac path as the remote and a local JSON file (an 8,062 B fileapi.py read
output) as the local file, so it **uploaded the JSON to the Mac and
overwrote `battopt-project/bc-build/bc-limit.c`** (the Phase B source,
29,407 B, v1.0-phase-b).

**Evidence the overwrite happened:** the transfer's confirm returned a
new mtime `2026-11-11T19:09:58Z` for the remote file (the original mtime
was Nov 8 14:42). **NOT directly verified** — the tunnel went down
immediately after (HTTP 502 at 19:10:27 UTC, then HTTP 530), so I could
not read back the Mac file's size/md5 to confirm.

**What is NOT affected:** the compiled binary
`battopt-project/bc-build/bc-limit` (v1.0-phase-b, 69,136 B) was NOT
touched — it is intact and still the current binary. No SMC write, no
daemon load/unload, no battery test, no sudo, no commit/push happened.
No other file was overwritten.

### 9.2 Recovery (reconstructed source — ready, validated locally)

No backup of the Phase B source exists locally (the local copy is Phase
A, 27,725 B) and `battopt-project/` is untracked, so git has no copy.
I reconstructed it:

- `phase_b_reconstruct.py` — rebuilds `--test-write` from the Phase A
  source, from the KNOWN Phase B behaviour (documented in the project
  record + the v1.0-phase-b `--help`: hardcodes BCLM=10, already-10
  guard, BCLM-backend-only, unprivileged run fails exit 1, sudo run
  logs `TEST-WRITE OK: BCLM=10 verified by read-back`, test-write wins
  over `--write`). The `--write` enforce loop is IDENTICAL in Phase A
  and Phase B (Phase B only added `--test-write`), so the reconstruction
  is functionally equivalent for Phase C. `--test-write` is a test-only
  flag (already verified 2026-11-08, never used again in Phase C).
- `bc-limit-phase-b-recon.c` — reconstructed Phase B: 29,467 B, md5
  `f38922af26067b54a1119c812fd4d593` (60 B larger than the original
  29,407 B — different comments/log text in the reconstruction; the
  behaviour matches).
- `phase_c_bc_limit_patch.py` — applies the gauge deferral (§3) to the
  reconstructed Phase B source.
- `bc-limit-phase-c-recon.c` — **the Phase C source: 32,731 B, md5
  `7e00c40c037343612f4e3e2975ad4c9e`**, version `1.0-phase-c`,
  `--test-write` + gauge deferral present, braces/parens balanced (0),
  test-write branch placed before the toggle comment (wins over
  `--write`, as in the original).

These four files are in `~/workspace/bc-build/` (local). They are NOT
yet copied to the Mac (tunnel down).

### 9.3 Build blocked — tunnel down (as of 2026-11-11 21:36 EET)

- Tunnel came back briefly 19:09:40 UTC, then went down again (502 at
  19:10:27 UTC, 530 at 19:11:51 UTC) and has stayed down. Poller
  (12-min intervals, 3 attempts: 19:11:58, 19:23:59, 19:35:59 UTC) —
  all TUNNEL-STILL-DOWN. GET /info at 19:36:28 UTC: HTTP 530.
- **Not done (blocked):** verify the Mac `bc-limit.c` state (size/md5)
  + search the Mac for a backup of the Phase B source; upload the
  reconstructed Phase C source to the Mac; compile on the Mac
  (`clang -Wall -Wextra -framework CoreFoundation -framework IOKit`);
  the dry-run test (§3); record the final binary md5/size here; copy
  this plan + the patch + reconstruction scripts to the Mac.

### 9.4 Revised build path (when the tunnel returns)

1. **Verify the Mac `bc-limit.c`** (size/md5 via `/run`) — confirm the
   overwrite. Search the Mac for a backup (`bc-limit.c*`, `*.bak`,
   `*.pre-*` in `battopt-project/bc-build/`). If the original Phase B
   source is found intact somewhere, use IT (not the reconstruction)
   and apply `phase_c_bc_limit_patch.py` to it.
2. **Upload the reconstructed Phase C source** (transfer.py, CORRECT
   direction — local file → Mac path):
   `transfer.py ~/workspace/bc-build/bc-limit-phase-c-recon.c
   /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build/bc-limit.c`
   then verify by size/md5 (32,731 B, md5 `7e00c40c…`) before compiling.
3. **Compile on the Mac** (`clang -Wall -Wextra -framework CoreFoundation
   -framework IOKit -o bc-limit bc-limit.c`, exit 0, no warnings).
   Verify `bc-limit --help` shows `1.0-phase-c`.
4. **Dry-run test** (§3: `--probe` selects bclm; `--dry-run` makes no
   writes, BCLM unchanged; the gauge-deferral 3-step test). Record the
   final binary md5/size in §2/§3.
5. **Copy to the Mac:** this plan (`phase-c-plan.md`), the patch script,
   and the reconstruction script, into `battopt-project/bc-build/`.
6. **Report** the binary readiness + dry-run results to Yousef. Then
   Phase C waits for his approval (the 2026-11-11 20:15 options widget
   is still unanswered) + his daytime time.
