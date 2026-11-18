# DMG Packaging Spec — 2026-11-16

**Status: SPEC ONLY.** No image is built by this document.
The DMG is a publish-step artifact: it is built after Stage C,
the final re-test and the local commit, and published LAST
(GitHub connection is Yousef's own step). Everything below is
grounded in the project's designs and the live install as
verified 2026-11-16; undecided product calls are collected in
§7 (three questions maximum).

## 1. What the DMG ships — the Stage C end-state, not today's state

The published bundle must contain the tool as Stage C leaves
it — **one UI (the native app), the FR-007 daemon, no SwiftBar
plugin dependency** — not today's soak state (app + plugin
side by side, pre-FR-007 daemon). Concretely:

| Component | Ships as | Install target |
|---|---|---|
| `BatteryCommander.app` (redesigned menu, FR-007 Quit) | In the DMG root, drag-install | `/Applications/` |
| `bc-limit` daemon binary (**v1.7**, FR-007 rebased on v1.6.1-ac) | Inside the app bundle's Resources (single distribution unit) | A root-owned system location (see §3) |
| `com.batterycommander.bclimit.plist` | With the daemon | `/Library/LaunchDaemons/` |
| Helper set (the deployed `~/.battery-commander/` scripts: `bc-watchdog.sh`, `dispatch.sh`, `display_state.sh`, `pre_sleep_cleanup.sh`, `bc-status`, sentinel + episode tracker + morning-report sidecar) | Inside the app bundle's Resources, versioned with the app | `~/.battery-commander/` (installed/updated by the setup step, §3) |
| User LaunchAgents (`com.batterycommander.watchdog`, `.watchdogsentinel`, `.morning-report`, and the renamed agent set from `src/agents/`) | With the helper set | `~/Library/LaunchAgents/` |
| Sudoers rules (`src/sudoers/battery-commander` — pmset/launchctl NOPASSWD for the agents) | With the daemon payload | `/etc/sudoers.d/battery-commander` |
| `README` (install, Gatekeeper, support matrix §5, uninstall) | DMG root + repo | — |
| Uninstaller (§4) | A menu action in the app **and** a standalone script in the DMG | — |

**Required relocation:** today the production daemon runs
from inside the development repo
(`battopt-project/bc-build/bc-limit`, the path the live plist
names) and its plist source lives only in bc-build. That is a
dev-machine accident, not a shippable layout. The packaged
daemon binary + plist move to standard system locations
(binary: `/Library/PrivilegedHelperTools/bc-limit`), the plist
source takes a canonical home in `src/` with the other agents,
and the plist's program path is rewritten at packaging time.
Nothing about the daemon's behaviour changes — same binary,
same `--config` contract, state dir unchanged.

## 2. State-dir bootstrap

- First setup creates `~/.battery-commander/` and writes the
  shipped default config (the values this project standardized
  on: **86/85, SAILING=false, SAIL_GAP=1**) plus empty
  verification store scaffolding.
- **An existing state dir is never overwritten.** Upgrade =
  helpers/plists refreshed, config + verification history +
  logs preserved byte-for-byte. (The 2026-11-10 migration and
  every deploy since have followed this rule; the shipped
  installer inherits it.)
- Bootstrap is idempotent: re-running setup on a healthy
  install changes nothing and says so.

## 3. Install flow

1. User drags the app to /Applications and opens it (Gatekeeper
   flow in §5).
2. On first launch the app detects the missing privileged
   pieces and runs **one** admin-authorized setup step that:
   installs the daemon binary + plist to §1's locations,
   installs the sudoers file, loads the LaunchDaemon, installs
   the helper set + user agents, bootstraps the state dir (§2),
   and verifies (daemon tick + state line within ~70 s,
   watchdog heartbeat, `verify-install` equivalent checks).
   One prompt, one time; later launches need no admin.
3. **Legacy plugin retirement:** if
   `~/SwiftBar/battery-commander.10s.sh` exists (pre-Stage C
   installs), setup **moves** it to
   `~/.battery-commander/backups/` (never deletes) and logs the
   move — the Stage C cutover step, generalized. SwiftBar
   itself is never touched.
4. The app registers itself as the login item (same bundle id,
   `com.batterycommander.launcher`).

## 4. Uninstaller behaviour

Uninstall must return the Mac to stock, provably, in this
order — and must **abort rather than strand a held limit**:

1. **Release first:** write `.tool_closed` (the FR-007
   contract) and wait for the daemon's verified release
   (`RELEASE OK: BCLM=100 verified by read-back`). If a
   discharge session is engaged, the same path disengages it
   (the v1.6 orphan rule is the backstop: discharge mode can
   never outlive its session).
2. **Verify stock:** read back BCLM=100 and ACEN at rest
   before removing anything. If verification fails, the
   uninstaller stops, leaves the daemon in place, and tells
   the user the limit is still held and why.
3. **Remove:** bootout + delete the LaunchDaemon and its
   binary, the user agents, the sudoers file, the login item,
   and the app itself.
4. **State dir:** kept by default (config + verification
   history make a reinstall seamless); a clearly-labelled
   purge option removes it. Keeping it is safe: with the
   daemon gone, nothing reads it.

## 5. Platform reality (from the compatibility research, 2026-11-07)

- **Reference platform:** Intel Mac, macOS Catalina 10.15 —
  the tool is built and proven there (clang/Swift 5.3.2,
  Command Line Tools; no full Xcode in the toolchain).
- **Mechanism is probed at runtime, never assumed:** the
  daemon selects its backend by probing (BCLM on Intel), and
  the research's order — BCLM → CHLS → CHWA → CHTE/CH0B·CH0C →
  native limit → adapter toggle → monitor-only — is the
  support story. Machines with no working mechanism get
  **monitor-only** behaviour and the README says so; BC never
  claims control it does not have.
- **Known cliffs the README must state honestly:** direct SMC
  writes are dead on macOS ≥ 15.0 (kernel entitlement);
  macOS 26.4+ offers Apple's native Charge Limit on Apple
  Silicon (Intel never gets one); macOS 27-era firmware gates
  the SMC charge keys behind a private entitlement. First
  release support claim = **Intel + BCLM, fully verified**;
  everything else is probe-and-report (see §7 Q2).
- **Unsigned distribution:** the build is ad-hoc signed (no
  paid developer identity exists in this project). A
  downloaded DMG is quarantined by Gatekeeper: first open is
  blocked with the standard warning. The README carries the
  exact flow (right-click → Open, or Security & Privacy →
  Open Anyway) with screenshots described in text. This is a
  known, accepted friction for v1 unless §7 Q1 decides
  otherwise.

## 6. Verification checklist — a built DMG must pass ALL before publish

On a clean user account (and, where possible, a machine or VM
that has never had BC installed):

**PUBLISH GATE (Yousef, 2026-11-16 — hard precondition, before
any item below counts): NO publish until BOTH hold — (a) the
comprehensive final retest (final-retest plan) passes in full,
and (b) the redesigned UI is installed via the Stage C cutover
and tested live on this Mac, after the calibration live run.
A DMG built before that gate is an internal artifact only and
must never be linked or announced as a release.**

- [ ] Publish gate above is satisfied and recorded (soak
      verdict + Stage C closed + calibration live run done +
      final retest green).
- [ ] DMG mounts; contents match §1's manifest exactly; no
      dev files (no `.pre-*`, no bc-build, no RE artifacts).
- [ ] Quarantined-download flow: Gatekeeper blocks, README
      instructions open the app successfully.
- [ ] First-launch setup: exactly one admin prompt; daemon
      loaded and ticking (state line ≤ ~70 s); watchdog +
      sentinel heartbeats fresh; verify-install equivalent
      all-pass.
- [ ] Default limit holds: on AC, charging stops at 86%
      (BCLM=10) and resumes below 85% (BCLM=100), read-back
      verified in the daemon log.
- [ ] FR-007: Quit releases (BCLM=100 verified, stock charging
      past 86%); relaunch restores enforcement ≤ ~70 s.
- [ ] Upgrade path: install over a state dir with a custom
      limit (e.g. 90/89) and verification history → config and
      history preserved, helpers updated.
- [ ] Legacy path: with a SwiftBar plugin present pre-install,
      it is moved to backups, one menu-bar icon remains.
- [ ] Uninstall: release verified **before** removal; after
      removal — no launchd jobs, no sudoers file, no login
      item, battery charges to 100% as stock; state dir kept
      (default) / removed (purge) as chosen.
- [ ] Reinstall after uninstall works with no residue issues.
- [ ] The full automated regression (final-retest plan) is
      green against the exact binaries inside the DMG.

## 7. Decisions (Yousef, 2026-11-16 — recommendations adopted)

The three former open questions are DECIDED. Yousef's words
2026-11-16 16:58 EET: "اتبع ترشيحاتك او توصيتاتك بخصوص اسئلة
النشر" — follow your recommendations on the publish questions.

1. **Signing — v1 ships UNSIGNED.** The DMG ships with the
   README Gatekeeper right-click-open flow documented. No paid
   Apple Developer account, no notarization for v1 — the paid
   route stays closed under Yousef's standing no-purchase rule.
2. **Support claim — Intel-only for v1.** Intel (the BCLM path)
   is the only fully verified platform and the only one v1
   claims. On other machines the tool probes at runtime and is
   honestly labelled probe-and-monitor-only, per the 2026-11-07
   compatibility research; no Apple Silicon support is claimed
   until it is tested on real hardware.
3. **Plugin in the box — app-only.** The DMG ships the
   standalone app (the Stage C end-state) and NOT the SwiftBar
   plugin. One UI surface to test and maintain for v1; the
   plugin can return as an optional extra in a later release
   only on a new decision.
