# Security Policy
## 1. Trust Model
BattOpt runs as a local single-user macOS control center. The user is trusted; the threat model is accidental misuse, stale state, and local privilege escalation via misconfigured sudoers or LaunchDaemons. No remote trust boundary is assumed. All components run on the local machine under the user's HOME and system LaunchDaemons.

## 2. Sudoers Scope
Observed `sudo -n` invocations in this repository are limited to `battopt`, `pkill`, `launchctl`, and `pmset`. TODO: verify /etc/sudoers.d/battopt exact entries against the deployed file before release; do not add entries beyond those four commands without review.

## 3. State File Permissions
Runtime state lives under `~/.battopt-swiftbar/` and is written via `atomic_write` (`printf > tmp && mv`) to avoid partial writes. TODO: verify chmod/ownership of state files and directories (`~/.battopt-swiftbar/`, `/Library/Application Support/battopt/`) to ensure only the user and root can write.

## 4. Session Isolation
Session isolation uses `SG_DIR` (default `~/.battopt-swiftbar`) with a `mkdir` lock at `.state_guard.lock` (pid file inside) and shared files `.active_token` and `.active_mode` with values `idle|charge_full|discharge|hold|calibration`. Callers must hold the guard lock for mutations; `guard_session_active` gates enforcement helpers.

## 5. Threat Surface
Threat surface is local: shell scripts writing state files, LaunchAgents/LaunchDaemons executing helpers, and `sudo -n` wrappers for power management. No network service is exposed by these scripts. Risk is limited to local file tampering, daemon spoofing via pid reuse, and stale lock/token files blocking actions.
