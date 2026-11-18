# Battery Commander — Stage C Readiness Package — 2026-11-16

**Status: BENCH / DOCS ONLY.** Prepared under Yousef's "keep working
as normal" (2026-11-16 00:08 EET) so the Stage C approval is one tap
and execution can start immediately after tonight's soak verdict
(soak ends 21:10, evaluation 21:52). **Nothing in this package is
deployed:** no install, no daemon reload or binary change, no plugin
move, no config change. The live state was verified untouched at the
end (§6).

Contents: §1 FR-007 implementation spec + the DRAFT bc-limit patch
(built and dry-run proven in a sandbox) · §2 cutover sequence ·
§3 rollback plan · §4 sleep-entry BCLM policy sketch (options, no
decision) · §5 the approval ask · §6 live-state verification.

Governing documents: `standalone-app-design.md` §3 (FR-007 as amended
2026-11-13) + §8.2 Stage C; `app-stage-b-note.md` §1 item 26 (applet
`on quit` deferred here); `app-redesign/menu-design.md`;
`full-audit-fix-session-20261115.md` F7/F9.

---

## 1. FR-007 implementation spec — the closed-flag contract

FR-007 (amended, Yousef 2026-11-13): quitting the app closes the tool
COMPLETELY — the enforcer releases the charge limit and the Mac
returns to stock charging behaviour; enforcement silently staying
alive after the owner closes the tool is not acceptable. The contract
below implements exactly that, with no sudo at quit time: the app
leaves a flag, the (root) daemon performs and verifies the release
itself.

### 1.1 The flag

- **File:** `.tool_closed`, in the state dir
  `~/.battery-commander/` — resolved by the daemon **next to the
  `--config` file**, the established sibling pattern of `.apg_paused`,
  `.discharge_session`, and `.calibration_run`. (Production
  invocation, from the live plist: `bc-limit --config
  /Users/Yousef/.battery-commander/config --write`.)
- **Signal = existence.** The daemon never parses the file, so a
  partially written or hand-created flag behaves identically: closed
  is closed.
- **Content (informational only**, for humans and logs; written by
  the app): two lines, `CLOSED_AT=<epoch>` and
  `BY=BatteryCommander.app (Quit)`.
- **Why not `.user_shutdown`:** that name belongs to the legacy
  dispatch "Stop ALL Services" path (housekeeping clears it at
  launch; its semantics are services teardown, not daemon release).
  A separate name keeps the two contracts unambiguous.

### 1.2 Who writes it, who clears it

- **Writer: the app, only on Quit.** In the redesigned sources the
  Quit item (`MenuModel.swift`, `special: "quit"`) reaches
  `AppDelegate.swift`'s quit path (`case "quit": NSApp.terminate(nil)`,
  and the second terminate call site in the same file). Stage C app
  delta: **write the flag first** — atomically (write
  `.tool_closed.tmp` in the state dir, rename to `.tool_closed`) —
  **then** terminate. No dispatch action writes the flag, and the
  SwiftBar plugin cannot (SwiftBar owns its process; it has no Quit)
  — so the flag can only ever originate from the native app's Quit.
- **Clearer: the app's launch housekeeping.** `Housekeeping.swift`'s
  run-once sequence, Step 1 — the step that already clears
  `.user_shutdown` / `.disabled` / `.paused` — also removes
  `.tool_closed`, **before** Step 7's `dispatch reapply_limit`. That
  ordering is the resume: flag cleared → config reapplied → the
  daemon's next run enforces again.

### 1.3 How the daemon polls it, and the exact release actions

bc-limit is a one-shot program: launchd runs it every 60 s and each
run is one decision cycle. "Polling" therefore means: **every run
checks the flag immediately after the state read** (backend, battery
%, control key) **and before** the discharge-session check, the
decision computation, the gauge-jump deferral, and the APG gate — so
no enforcement-protection gate can delay or suppress a release.

On a run that sees the flag (toggle backends; BCLM here):

- **BCLM ≠ 100** (a hold is in force) → perform the release: **one
  write of the backend's resume value (BCLM=100)** through the
  existing single write path (`backend_write_value` →
  `smc_write_bclm`), which **read-back verifies**. Log lines:
  `tool closed (.tool_closed): releasing limit — WRITE BCLM=100`,
  then `RELEASE OK: BCLM=100 verified by read-back (FR-007);
  enforcement idle while .tool_closed stands`. Exit 0.
- **BCLM already = 100** → no write. Log: `tool closed (.tool_closed):
  limit already released (BCLM=100); enforcement idle`. Exit 0.
- **Write failure** → log the error, exit 1; the next launchd run
  (60 s later) retries — one attempt per run, preserving the
  project's no-retry-loop rule for SMC writes.
- **While the flag stands:** no other writes, no session/APG
  processing, and the gauge state file (`.bc-limit-last-pct`) is not
  updated (the first post-relaunch run re-records it; a one-cycle
  gauge deferral may then apply, exactly as after any daemon gap —
  protective and self-correcting).

**Config:** the config file stays on disk, byte-untouched
(86/85, md5 `69c6c438…`). Enforcement stops; the file is the memory
that lets a relaunch restore 86/85 exactly. **End state = stock:**
BCLM=100 is the machine's unmanaged value, and this Intel Mac has no
native charge limit — stock means "charges to 100% whenever plugged
in", which is precisely what FR-007 asks for.

### 1.4 Resume semantics

Relaunch the app (manually, or automatically at login — the app
remains a login item) → housekeeping clears the flag and reapplies
the config → the daemon resumes normal enforcement on its next run,
**≤ 60 s** later. Bounded quirk of that window: until the run lands,
the battery is still unmanaged; if % sits between lower and upper it
charges as stock in the meantime. **Quit ≠ disable:** quitting
closes the tool until the app next launches; at the next login the
login item relaunches it and the limit returns. Staying closed
across logins is the existing "Launch at Login" toggle's job. This
is stated plainly so there is no surprise either way.

### 1.5 Edge cases

1. **App crash / force-quit (SIGKILL) / power loss:** only the Quit
   path writes the flag, so a crash writes nothing and the daemon
   keeps enforcing. A crash can never silently release the limit
   (design §9's "app crash affects nothing else" is preserved).
2. **Flag written, machine reboots before the next daemon run:**
   BCLM persists across reboot on this Mac; the daemon's first
   post-boot run sees the flag and performs the release then. Until
   that run, the pre-reboot hold value stands.
3. **Daemon (re)started while the flag stands:** same as (2) —
   release-if-needed on the first run, idle lines thereafter.
4. **Flag present while the app is running:** only the seconds
   between the Quit handler's write and process exit — or a
   hand-created file. The daemon treats both identically (closed is
   closed); if Yousef hand-creates the flag while the app runs, the
   limit releases and stays released until the app is relaunched
   (housekeeping clears only at launch). Documented, deliberately
   not guarded: the flag is an intentional signal.
5. **Quit during a discharge or calibration session:** the release
   wins (the flag check precedes session logic). Session/run files
   are **not** deleted — bc-limit never deletes them (established
   contract); they expire under their own bounds (session ≤
   DISCHARGE_MAX_MINUTES; calibration heartbeat ≤ 600 s) and the
   watchdog owns their lifecycle. On relaunch, an unexpired user
   session simply resumes its contract; Yousef can cancel it from
   the menu.
6. **Quit while APG-paused:** the release still happens — the flag
   check precedes the APG gate. Quit is not an enforcement decision
   and no enforcement-protection gate applies to it.
7. **Config invalid or missing:** the daemon errors out before the
   flag check, exactly as v1.3 errors today (a corrupt config
   already breaks every run). The app never writes the config except
   through dispatch's validated writers, so this corner requires
   independent config corruption.
8. **The soak's two-icon world cannot produce the flag:** the
   installed Stage B app's Quit is a plain exit (no flag write) and
   the live v1.3 daemon has no flag check. The contract becomes live
   only when **both** halves land, **daemon first** (§2 step 2
   before step 4). If the app landed first, its Quit would write a
   flag a v1.3 daemon ignores and enforcement would silently
   continue — the exact FR-007 violation — so the ordering is a hard
   requirement, not a preference.

### 1.6 The deferred applet `on quit`, mapped

The retired applet's handler was `on quit → dispatch shutdown
--force` (+ 5 s delay): a shell-level teardown whose release step
depended on dispatch's daemon check — the user-domain bug class that
audit item F7 fixed on 2026-11-15 (shutdown itself was deliberately
not redesigned then). The Stage C mapping replaces that chain
end-for-end: **app Quit → flag write → daemon-side release with
read-back verify.** Same intended end state (tool closed, limit
released, stock behaviour), achieved without the app shelling out,
without sudo, and with the release performed and verified by the
only component that ever writes BCLM. `dispatch shutdown` ("Stop ALL
Services") is unchanged: it remains the deeper services teardown and
does not write `.tool_closed`. The stray applet process (PID 21524)
is untouched by all of this — §2 step 6.

### 1.7 The DRAFT bc-limit patch (built + proven, NOT deployed)

- **File:** `bc-limit-v1.4-stagec-DRAFT.c` — Mac repo
  `battopt-project/bc-build/` + local `~/workspace/bc-build/`,
  md5 `2289586a6cd4d429e361e842f482cd15` both sides (48,991 B;
  v1.3 source is 44,407 B, md5 `71fac1d9…`).
- **Delta from v1.3 (the ONLY delta):** header comment block;
  `BC_VERSION` → `1.4-stagec-DRAFT`; a `tool_closed()` helper
  (sibling-path existence check, mirroring the `.apg_paused` /
  session pattern); one branch in `main()` at the §1.3 poll point.
  Nothing else — no change to probing, config parsing, the session
  contract, the decision rules, the deferral, the APG gate, or the
  write path.
- **Sandbox proof** (2026-11-16 00:14 EET, `stagec-sandbox/` in the
  Mac bc-build; every invocation `--dry-run`; the live binary and
  config untouched):
  - Standalone compile (`clang -Wall -Wextra`, CoreFoundation +
    IOKit): **rc=0, zero warning bytes**.
  - `test_bc_limit_calibrate.sh` compiled against the draft:
    **PASS=15 FAIL=0** (gauge 86 — the decisive lines fired for
    real, e.g. `WOULD WRITE BCLM=100 (pct=86% <= lower=94)`).
  - `test_bc_limit_discharge.sh` compiled against the draft:
    **PASS=11 FAIL=0**.
  - **Flag proof** (draft binary, scratch config 86/85 + a
    `.tool_closed` beside it, live battery state pct=86 BCLM=10):
    `bc-limit 1.4-stagec-DRAFT starting` → `state: backend=bclm
    upper=86 lower=85 pct=86% BCLM=10 charging=0 external=1` →
    **`DRY-RUN: WOULD WRITE BCLM=100 (FR-007 tool-closed release).
    No write performed.`**
  - **Control** (same, no flag): `decision: nothing to do (pct=86%,
    BCLM=10 already correct)` — v1.3 behaviour preserved exactly.
  - Not provable in dry-run: the "already released" branch (needs
    BCLM=100 live) and the real write itself. Both reuse the
    read-back-verified write path unchanged from v1.3; the branch
    structure is inspection-covered and the live Quit test (§2
    step 9) is the real proof, under Yousef's tap.
- **App-side delta** (written at cutover execution, §2 step 3 — not
  in this package): (a) AppDelegate quit path writes the flag before
  terminate (both call sites); (b) Housekeeping Step 1 also clears
  `.tool_closed`; (c) Housekeeping Steps 2 (restore plugin from
  `disabled/`), 8 (launch SwiftBar if absent), and 9 (plugin
  presence verify) are retired — the app no longer depends on the
  plugin or SwiftBar — replaced by a "plugin retired (Stage C)" log
  line and a self-check of the app's own bundle; (d) the Stage A/B
  header comments that say "Quit is a plain exit" are updated.

---

## 2. Cutover sequence (execution day, after approval)

**Preconditions:** soak verdict delivered; Yousef's Stage C approval;
Mac awake, tunnel up; no discharge session or calibration run active
(if one is, let it finish or cancel it from the menu first —
Yousef's call).

0. **Pre-flight reads:** GET /info; daemon's last state line; config
   md5 (expect `69c6c438…`); plugin md5 (expect `5db2957e…`);
   /Applications app exe md5 (expect `5739955e…`); bench build exe
   md5 (expect `5dcbd56f…`); login item resolves to
   `/Applications/BatteryCommander.app` (System Events).
1. **Backups — before anything changes:**
   - /Applications bundle → `ditto` to
     `~/.battery-commander/backups/BatteryCommander-stageb-backup-20261116.app`
     AND repo `app/BatteryCommander-stageb-backup-20261116.app`;
     verify exe md5 `5739955e…` in both.
   - Daemon binary `battopt-project/bc-build/bc-limit` →
     `bc-limit.pre-stagec-20261116` (same dir); verify md5
     `c9ddf76a…`.
   - Plugin file → **copy** to
     `~/.battery-commander/backups/battery-commander.10s.sh.pre-stagec-20261116`;
     verify md5 `5db2957e…`.
   - The Stage B applet backups (`app/BatteryCommander-applet-
     backup-20261114.app` + state-dir copy) are not touched.
2. **Daemon first (FR-007 ordering, §1.5.8):** finalize the draft as
   v1.4 (`BC_VERSION` → `1.4-stagec`; content otherwise identical);
   zero-warning compile; re-run both matrices against the final
   source (expect 15/15, 11/11); install the binary onto
   `battopt-project/bc-build/bc-limit` (the path the plist runs);
   `launchctl kickstart -k system/com.batterycommander.bclimit`;
   verify ≥ 3 runs: `bc-limit 1.4-stagec starting`, state line
   86/85, BCLM=10, "nothing to do". (Flag absent ⇒ v1.4 behaves
   identically to v1.3; this step is independently safe and
   reversible via the step-1 backup.)
3. **App build with the FR-007 delta:** apply the §1.7 app-side
   delta to the redesign sources in `app-redesign-src/`; rebuild
   with `build-app-native.sh` (zero errors/warnings); re-run
   `--dump-menu` parity against the plugin's final render (redesign
   structure; action coverage 48 both directions; Smart Discharge +
   Sleep Mode identity per `menu-design.md`); promote the sources to
   `src/app/` (the pre-cutover `src/app/` is preserved as
   `src/app.pre-stagec-20261116/`).
4. **Install the app — needs one click from Yousef:** he quits the
   running Stage B app from its menu (a plain exit in that build —
   no side effects; the new app cannot take over while the old
   instance holds the launch lock). Then: `mv`
   /Applications/BatteryCommander.app →
   /tmp/BatteryCommander-stageb-live-20261116.app (parking copy, the
   Stage B pattern); `ditto` the new build to
   /Applications/BatteryCommander.app; verify `diff -r` vs the bench
   build, exe md5, codesign; launch the new app from /Applications;
   verify the login item still resolves to the same path (it was
   never touched — same path, same bundle id
   `com.batterycommander.launcher`).
5. **Retire the plugin:** **move** (never delete)
   `~/SwiftBar/battery-commander.10s.sh` →
   `~/.battery-commander/backups/battery-commander.10s.sh.retired-stagec-20261116`.
   SwiftBar itself stays installed and running (it may host other
   plugins; removing it is Yousef's separate call — design §8.2).
   Verify: ~/SwiftBar no longer contains the plugin; the only BC
   menu-bar icon is the app's.
6. **Stray applet PID 21524 — do not disturb:** do NOT kill it and
   do NOT quit it (a graceful quit fires its legacy
   `dispatch shutdown --force` handler). No step above touches its
   process or its parked bundle
   (`/tmp/BatteryCommander-applet-live-20261114.app`). It exits on
   its own at the next logout/restart and can never relaunch (no
   login item points at the parked path). Verify only that it is
   unchanged (same PID, ~0% CPU).
7. **Sentinel + health expectation updates** (same session as the
   plugin move):
   - `bc-watchdog-sentinel.sh` (repo `battopt-project/bc-build/` +
     deployed `~/.battery-commander/bc-watchdog-sentinel.sh`,
     together): **delete the plugin pair line** —
     `_pair plugin "$HOME/SwiftBar/battery-commander.10s.sh"
     "$REPO/src/plugin/battery-commander.10s.sh"` (line 219) —
     pairs go **14 → 13**. Left in place, the pair would report
     `missing:plugin` and raise an integrity alert ~5 min after the
     move, for a retirement that was intentional. The repo plugin
     source stays in `src/plugin/` (it is the rollback source);
     only the pair goes. Run the sentinel test suite against the
     updated source before deploying it; after deployment, confirm
     ≥ 2 clean sentinel cycles in its log.
   - `project_health.sh` (repo `src/daemon-helpers/` + deployed
     copy, together): the check at ~line 71 ("plugin file exists in
     ~/SwiftBar" = yes) is replaced by a check that
     `/Applications/BatteryCommander.app/Contents/MacOS/BatteryCommander`
     exists. The "SwiftBar.app exists" / "SwiftBar running" checks
     stay as they are. Re-run the health check: expect FAIL 0.
   - Execution-time sweep: grep the state dir and repo `src/` for
     any other literal `SwiftBar/battery-commander` expectation and
     update only plugin-presence expectations of the same kind.
8. **First-launch verification (read-only):** actions.log shows the
   full housekeeping sequence (`LAUNCH START` → … → `LAUNCH
   COMPLETE`) including the new flag-clear step; header correct
   ≤ ~4 s; 10 s ticks; the §2 step-3 dump parity on file; daemon
   state line fresh (86/85, BCLM=10); watchdog heartbeat fresh;
   sentinel clean (step 7); health FAIL 0; verify-install re-run;
   exactly one BC menu-bar icon. Menu clicking itself is Yousef's
   eyes (it cannot be automated — OS restriction, known since
   Stage A).
9. **The Quit test — Yousef's tap, the FR-007 proof:**
   - He clicks **Quit Battery Commander** in the app menu.
   - Expected: the BC icon disappears; within ≤ ~70 s the daemon
     log shows the release lines ending `RELEASE OK: BCLM=100
     verified by read-back`; plugged in and below 100%, the battery
     visibly starts charging past 86% (stock behaviour); the config
     file is unchanged (86/85); no BC icon remains.
   - He relaunches the app from /Applications: housekeeping clears
     the flag (actions.log), the icon returns with the correct
     header, and within ≤ ~70 s the daemon is enforcing 86/85
     again.
   - Pass = both directions observed in the logs and in the menu
     bar. Fail = §3 rollback (or fix-forward if the failure is
     app-side only — the daemon release is the critical half).

---

## 3. Rollback plan (restore tonight's exact setup)

Trigger: any material failure in §2 step 8 or 9, or Yousef says
revert. Order is UI-ward first, daemon last — the reverse of the
cutover — and every artifact needed was created in §2 step 1.

1. **Daemon binary:** copy `bc-limit.pre-stagec-20261116` back onto
   `battopt-project/bc-build/bc-limit`; `launchctl kickstart -k
   system/com.batterycommander.bclimit`; verify `bc-limit
   1.3-calibrate starting` + state line + "nothing to do" at 86/85,
   BCLM=10. (v1.3 ignores the flag entirely, so enforcement resumes
   regardless of flag state.)
2. **Flag cleanup:** remove `~/.battery-commander/.tool_closed` if
   present. (Inert under v1.3 and under the Stage B app — whose
   housekeeping does not clear it — but no stale state is left
   behind.)
3. **App:** quit the Stage C app if running (if a release already
   happened, step 1 has already restored enforcement); move the
   Stage C bundle to /tmp parking; `ditto`
   `~/.battery-commander/backups/BatteryCommander-stageb-backup-20261116.app`
   → /Applications/BatteryCommander.app; verify exe md5
   `5739955e…`; launch it; verify housekeeping + header + 10 s
   ticks. The login item was never touched.
4. **Plugin:** move
   `~/.battery-commander/backups/battery-commander.10s.sh.retired-stagec-20261116`
   back to `~/SwiftBar/battery-commander.10s.sh`; `chmod +x`;
   verify md5 `5db2957e…` and a fresh SwiftBar render identical to
   the pre-cutover render.
5. **Expectation updates reverted:** sentinel plugin pair restored
   (14 pairs; repo + deployed copies), project_health plugin check
   restored (repo + deployed). Re-run: sentinel one clean cycle,
   health FAIL 0.
6. **Rollback verification:** two BC icons again (app + plugin),
   daemon v1.3 ticking, hold at 86/85, sentinel clean, config md5
   `69c6c438…`.

Exposure note: at no point in the cutover or the rollback is battery
state at risk. The worst case throughout is a window where the limit
is released (stock charging) until enforcement is restored — the
same exposure as an ordinary daemon restart.

---

## 4. Sleep-entry BCLM policy — design sketch (options, NOT a decision)

**The structural behaviour (proven, not theory):** while the Mac
sleeps, the enforcer sleeps too — launchd does not run bc-limit in
sleep — so **BCLM keeps whatever value it had at sleep entry.** Both
directions are in the evidence: the S3 night (2026-11-12→13) the lid
closed at 89% in hold (BCLM=10); the charger was attached *during*
sleep at 76% and the battery **held 76%** — it did not charge in
sleep even though it was below the lower limit. Mirror case: close
the lid while charging (BCLM=100) and it charges in sleep
unsupervised, past the upper limit, to 100%.

- **Option A — sleep-entry release (naive).** A powerwatch WillSleep
  hook: if BCLM=10 and pct < lower, write BCLM=100 just before sleep
  so the Mac can charge while closed. *Trade-off:* charging in sleep
  is then **unbounded** — nothing is awake to re-apply the hold at
  the upper limit, so a lid closed at 84% wakes at **100%** and sits
  there: the exact wear pattern the limit exists to prevent, traded
  for morning availability. The SMC write also races the sleep
  transition itself (the hook must finish before sleep; a slow write
  stresses exactly the path with a kernel-panic history on this
  machine).
- **Option B — release + scheduled mid-sleep wake.** As A, plus a
  `pmset`-scheduled wake near the estimated time to reach the upper
  limit, so the daemon can tick and re-apply the hold. *Trade-offs:*
  the estimate rests on charge-rate guesswork; scheduled wakes on
  Catalina are best-effort; every failure mode degrades to A anyway.
  High complexity, low guarantee. **Not recommended.**
- **Option C — status quo + explicit intent (recommended).** No
  automatic policy: the state at lid-close is the state through
  sleep — predictable, and already the documented behaviour. If
  Yousef wants a closed-lid charge-up, he presses "Charge to 100% &
  Hold" (or any action that leaves BCLM=100) **before** closing: the
  100% outcome is then his explicit choice — identical in result to
  Option A, never a surprise. Optional garnish, display-only: a menu
  note while on AC in hold — "closing the lid keeps this state
  during sleep" — no behaviour change.

**Recommendation: adopt C.** Revisit A only if Yousef decides
morning availability outweighs the charge-to-100-in-sleep outcome.
(One honesty note: a firmware-% reading of BCLM exists for some
Intel models in the compatibility research, but all live evidence
on this Mac — Phase B/C and months of ticks — shows toggle
behaviour, 10/100. A sleep policy built on the % theory would need
its own approved experiment; nothing here assumes it.) **Nothing in
this section is implemented.**

---

## 5. The Stage C approval ask (show with the soak verdict)

> **Stage C — the final cutover (needs your OK after tonight's soak verdict):**
> • The redesigned app becomes the only Battery Commander icon; the SwiftBar plugin retires (moved to backups — restorable in minutes).
> • Quit becomes real: closing the app releases the limit (the battery then charges as stock) until you relaunch the app, which restores 86/85.
> • The daemon gets a small, pre-tested update (v1.4) that only adds this Quit contract — it passed the full test matrices tonight (15/15, 11/11) and behaves identically while you don't quit.
> • During the cutover I need one click from you: quit the old app from its menu when I say.
> • Risks: brief windows (≤ ~1 minute) with the limit unmanaged during the swap and at each quit/relaunch; everything is backed up before anything changes.
> • Rollback: tonight's exact setup (old app + plugin + current daemon) restores in minutes, rehearsed in the plan.
> Nothing else changes: limits stay 86/85, every button and action stays the same, SwiftBar itself stays installed.

**Open decisions for Yousef:** (1) Stage C go / no-go, with the soak
verdict. (2) Later, not blocking: the §4 sleep-entry policy —
adopt C, or direct an experiment toward A. (3) Whether the §4
Option-C menu note line is wanted.

---

## 6. Live-state verification (end of this package, 2026-11-16 00:17 EET)

Verified by direct read after all sandbox work finished:

- Daemon ticking: `[2026-11-16 00:17:11] decision: nothing to do
  (pct=86%, BCLM=10 already correct)`.
- Live daemon binary `bc-limit` md5 `c9ddf76a…` — v1.3, unchanged;
  never reloaded; the DRAFT exists only as a source file and in
  `stagec-sandbox/`.
- Config md5 `69c6c4384223e8ba6163d37c6917de6b` — 86/85, unchanged.
- Plugin in ~/SwiftBar md5 `5db2957e…` — unchanged, not moved.
- /Applications app exe md5 `5739955e…` — the Stage B build; the
  soaking app process (PID 12066) still running it; the stray applet
  process (PID 21524) still idling, untouched.
- No `.tool_closed` exists in the state dir.
- New files created by this package, all inert: repo bc-build
  `bc-limit-v1.4-stagec-DRAFT.c`, `stagec-sandbox-run.sh`,
  `stagec-sandbox/` (sandbox copies + logs + the dry-run-only draft
  binary), and this note.

---

## Addendum — 2026-11-16 ~00:49 EET: FR-007 draft rebases onto v1.4-apggate → v1.5

Since this package was written, bc-limit **v1.4-apggate** was approved
(Yousef, 2026-11-16 00:26), built, deployed, and live-proven (see
`apggate-fix-note.md`): the M6 APG resume gate now honours the
watchdog's `.apg_pause_reason` — a `load` pause no longer suppresses a
resume write; `thermal`/unknown still does. The live daemon is
therefore v1.4-apggate (binary md5 `a74e7022…`), not v1.3-calibrate.

Consequences for Stage C:

- The FR-007 draft in this package (`bc-limit-v1.4-stagec-DRAFT.c`,
  based on v1.3) **rebases onto the v1.4-apggate source** and the
  Stage C daemon becomes **v1.5** (FR-007 `.tool_closed` release +
  APG reason gate). The two deltas are disjoint: the FR-007 flag check
  sits right after the state read, before the session/gauge/APG gates,
  exactly as specced in §2 of this package; the M6 change does not
  interact with it.
- The draft's sandbox results (matrices 15/15 + 11/11, flag dry-run
  proof) carry over in substance, but at Stage C the matrices and the
  flag proof **must be re-run against the rebased v1.5 source** before
  deployment, and a v1.5 case should be added: `.tool_closed` present
  **while** `.apg_paused` has reason `load` → the release write still
  wins (flag check precedes the APG gate by construction).
- Everything else in this package (cutover sequence, rollback, the
  mid-sequence click, sleep-entry options) is unchanged.

## Addendum — 2026-11-16 (button/jump repair session)

The FR-007 version chain moved during the day: bc-limit shipped **v1.5-gauge** (14:10, confirm-before-write + second-signal gate) and **v1.6-ac** (14:16, the on-AC discharge actuator) in the Yousef-approved button/jump repair session. The FR-007 DRAFT patch therefore now rebases onto **v1.6-ac**, and the Stage C daemon becomes **v1.7** (not v1.6 as this package's earlier drafts assumed — the actuator took that number). The DRAFT's structure is unchanged (one `tool_closed()` helper + one branch in main, before all gates); re-verify its anchors against `bc-limit-v1.6.c` (Mac bc-build, source md5 `f0600db3…`) during the cutover, and run the v1.6 matrix set (calibrate/discharge/apg + gauge + ac suites) against the v1.7 build. Everything else in this package stands.

## Addendum — dry-verification 2026-11-16 ~16:35 EET (Stage C vs current live state)

Read-only re-verification of this package against the live system after
today's deploys (bc-limit **v1.6.1-ac** latency fix; icon-classification
fix in display_state/plugin/StatusProvider; release-prep docs). Nothing
was installed, deployed, or changed on the Mac; only this document was
updated. Result: **13 MATCH · 6 CORRECTED.** The cutover (§2) and
rollback (§3) stand with the corrections below applied.

### MATCH (verified 2026-11-16, values as the package expects)

- Config md5 `69c6c438…` (86/85) — unchanged.
- /Applications app exe md5 `5739955e…` — the Stage B build, never
  reinstalled; the §2 step-0/1 and §3 step-3 expectations hold (login
  item path + bundle id untouched with it).
- Bench build exe md5 `5dcbd56f…` (built 2026-11-15 23:10) — the
  §2 step-0 pre-flight reference / parity baseline, as specced.
- Daemon plist ProgramArguments → repo `battopt-project/bc-build/bc-limit`
  + `--config` — the binary path §1.1/§2/§3 operate on is correct.
- Sentinel: **14 pairs**; the plugin pair stands at **line 219**,
  verbatim as §2 step 7 quotes it (delete → 13 pairs). Repo sentinel
  == deployed copy (md5 `2698d4c5…`).
- `project_health.sh`: the plugin-presence check is at **line 71**,
  exactly where §2 step 7 replaces it; the SwiftBar.app checks stay.
- display_state pair (sentinel line 211) is consistent after today's
  icon fix: repo `src/plugin/display_state.sh` == deployed, both
  md5 `f8ba2fed…`. No cutover change needed; the pair survives Stage C.
- FR-007 draft file identity (§1.7): md5 `2289586a…`, 48,991 B, both
  copies — unchanged.
- Redesign AppDelegate: the two `NSApp.terminate` call sites (§1.2)
  are at lines 65 and 209 — as specced.
- Redesign sources AppDelegate / Housekeeping / main / Shell are
  byte-identical to `src/app/` — the §1.7 app-side delta applies to
  the code it was written against.
- Soak log: local == Mac copy, md5 `1fb2021e…`, current through
  today's deploys — tonight's 21:52 evaluation reads the right file.
- Addendum-2 anchor: `bc-limit-v1.6.c` source md5 `f0600db3…` — as cited.
- **FR-007 ↔ v1.6.1 overlap check — none.** In `bc-limit-v1.6.1.c`
  the §1.3 poll point is the window between the state log (line 1387)
  and the discharge-session check (line 1396). The entire v1.6→v1.6.1
  delta (70 diff lines) sits in the header comment, the version
  string, a new monitor-armed helper (lines ~774–812), and the
  discharge engagement/supervision block (lines ~1511–1645) — all
  downstream of the poll point. The draft's one-branch design carries
  over unchanged.

### CORRECTED (apply these over the body text at execution)

1. **Live daemon:** §6/§2 step 1 name v1.3-calibrate (md5 `c9ddf76a…`).
   Current: **v1.6.1-ac, binary md5 `7ec16c8d…`** (daemon log:
   `bc-limit 1.6.1-ac starting`). §2 step 1's backup-verify md5 →
   `7ec16c8d…`; §3 step 1's rollback verify string →
   `bc-limit 1.6.1-ac starting`.
2. **Plugin md5:** §2 step 0, §2 step 1, §3 step 4 expect
   `5db2957e…`. Current (icon-classification fix; repo copy ==
   ~/SwiftBar copy): **`86c718e5…`**.
3. **FR-007 base + final version:** the version chain in §2 step 2
   and the earlier addenda (v1.4 → v1.5 → v1.6-ac) is superseded.
   Final: **v1.7, rebased onto `bc-limit-v1.6.1.c` (source md5
   `8c331494…`)**, `BC_VERSION` → `1.7-stagec`. §2 step 2's matrix
   re-run = the v1.6.1 set (calibrate 15 · discharge 11 · apg 9 ·
   gauge · ac) plus the FR-007 flag cases, including addendum-1's
   `.tool_closed` + `load`-pause case.
4. **§5 approval ask:** "(v1.4)" → **v1.7**; "passed the full test
   matrices tonight (15/15, 11/11)" described the v1.3-based draft.
   Current wording should say: the update adds only the Quit
   contract on top of the live v1.6.1 (which passed today's full
   battery: matrices 15/15 · 11/11 · apg 9/9 · ac 14 PASS/1 SKIP ·
   discharge 36/36 · charge 51/51 · calibration 98/98 · sentinel
   41/41 · bc-verify VERIFIED · health 17/0), and the v1.7 build
   re-runs the matrix set at cutover step 2 before install.
5. **§2 step 3 build base — one sync first:** the bench .app is a
   parity baseline, never the installable artifact (step 3 rebuilds
   — unchanged). But `app-redesign-src/StatusProvider.swift` is
   md5 `b1078620…` (label-fix era) and lacks today's
   icon-classification fallback. Before applying the §1.7 delta:
   **sync `src/app/StatusProvider.swift` (md5 `f1a78470…`) over
   `app-redesign-src/StatusProvider.swift`**, then rebuild.
   MenuModel needs no sync: redesign `c18412bd…` is the intentional
   grouped menu (src/app `b564f576…` is the Stage B menu).
6. **New required rebase delta (from the overlap check):** in
   v1.6.1 the discharge-mode supervision / orphan-clear block
   (lines ~1614–1635) sits *downstream* of the poll point, so a
   v1.7 branch that returns at the poll point never clears an
   engaged discharge mode. Corner: Quit while discharge mode is
   engaged (ACEN=0) would leave the adapter path dropped until
   relaunch — not stock. **The v1.7 `tool_closed` branch must
   therefore also disengage discharge mode** (if ACEN==0, issue the
   same `discharge(0)` manager call the supervision block uses,
   and log it) as part of the release. Verified alongside it:
   §1.3's gauge claim holds on v1.6.1 — the gauge state read
   (line 1432) and write (line 1472) both sit after the poll point,
   so a flag run touches no gauge state, exactly as specced.

---

## Addendum — decisions 2026-11-16 ~16:58 EET (Yousef)

### A. Sleep-entry BCLM policy — DECIDED: §4 Option C adopted

§4's **Option C (status quo + explicit intent) is adopted as
designed.** No WillSleep hook, no scheduled wake, no automatic
sleep-entry policy of any kind: the state at lid-close is the
state through sleep, and a closed-lid charge-up happens only
when Yousef explicitly leaves BCLM=100 (e.g. "Charge to 100% &
Hold") before closing. **Nothing to implement for the policy
itself.** The §4 display garnish IS in the Stage C build scope:
a display-only menu note while on AC in hold — "closing the lid
keeps this state during sleep" — no behaviour change. §4's
header ("options, NOT a decision") is superseded by this
addendum; A and B stay rejected unless Yousef reopens them.

### B. FR-007 Quit/return test protocol — STRENGTHENED (binding)

Yousef's requirement (2026-11-16 16:58 EET): Quit must return
the Mac to stock — **as if the tool does not exist**, the
system itself managing charging — the step must be executed
carefully and **tested more than once**, including the return
(relaunch) step. The §2 verification therefore runs **at least
three full quit/relaunch cycles** at cutover, one per state:

1. **Quit at hold** (86/85, BCLM=10): Quit writes
   `.tool_closed` → daemon idles on the flag → BCLM=100
   verified by read-back → a plug-in charge then proceeds
   **unimpeded by the tool** (charges past 86% as stock).
2. **Quit while charging toward a limit** (BCLM=100, below
   upper): same release verification — daemon idles on the
   flag, BCLM stays/goes 100 by read-back, charging continues
   to 100% as stock with no tool interference.
3. **Quit while discharge mode is engaged** (ACEN=0): the
   v1.7 branch's discharge(0) release is verified — **ACEN
   back to normal and ExternalConnected restored** — plus
   BCLM=100 by read-back; the Mac is stock with the adapter
   path live again.

After **each** quit: relaunch the app → housekeeping Step 1
clears the flag **before** reapply → enforcement resumes
within one daemon tick → 86/85 re-applied and holding → no
double management (exactly one actor at all times).

**Stage C does not close unless all three cycles pass.**
Any failure in any cycle → stop, follow the §3 rollback path,
and report; the cutover is not declared complete on a partial
pass.
