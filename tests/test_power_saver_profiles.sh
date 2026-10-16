#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
POWER_SAVER="$ROOT/src/daemon-helpers/power_saver.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/.battopt-swiftbar"

cat > "$TMP/bin/sudo" <<'SUDO'
#!/bin/bash
[ "$1" = "-n" ] && shift
exec "$@"
SUDO
chmod +x "$TMP/bin/sudo"

cat > "$TMP/bin/pmset" <<'PMSET'
#!/bin/bash
printf '%s\n' "$*" >> "$PMSET_LOG"
PMSET
chmod +x "$TMP/bin/pmset"

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export PMSET_BIN="$TMP/bin/pmset"
export PMSET_LOG="$TMP/pmset.log"

assert_profile() {
    local profile="$1"
    local expected="$2"

    : > "$PMSET_LOG"
    "$POWER_SAVER" apply-delays "$profile"
    diff -u <(printf '%s\n' "$expected") "$PMSET_LOG"
}

assert_profile default "$(cat <<'EXPECTED'
-b standbydelayhigh 2700
-b standbydelaylow 2700
-b autopoweroffdelay 1800
-b standbydelay 2700
-c standbydelayhigh 3600
-c standbydelaylow 3600
-c autopoweroffdelay 3600
-c standbydelay 3600
-c sleep 90
EXPECTED
)"

assert_profile long "$(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 1800
-b standbydelay 3600
-c standbydelayhigh 7200
-c standbydelaylow 7200
-c autopoweroffdelay 3600
-c standbydelay 7200
-c sleep 90
EXPECTED
)"

assert_profile travel "$(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 1800
-b standbydelay 3600
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
EXPECTED
)"

: > "$PMSET_LOG"
"$POWER_SAVER" apply-delays travel
"$POWER_SAVER" enforce-sleep-policy
diff -u <(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 1800
-b standbydelay 3600
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-b standbydelayhigh 2700
-b standbydelaylow 2700
-b autopoweroffdelay 1800
-b standbydelay 2700
-c standbydelayhigh 3600
-c standbydelaylow 3600
-c autopoweroffdelay 3600
-c standbydelay 3600
-c sleep 90
EXPECTED
) "$PMSET_LOG"

echo "Power Saver profile tests passed."
