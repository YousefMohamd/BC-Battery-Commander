#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
POWER_SAVER="$ROOT/src/daemon-helpers/power_saver.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/.battery-commander"

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
-b standbydelayhigh 600
-b standbydelaylow 600
-b autopoweroffdelay 1800
-b standbydelay 600
-b disksleep 10
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-c disksleep 10
EXPECTED
)"

assert_profile long "$(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 3600
-b standbydelay 3600
-b disksleep 10
-c standbydelayhigh 14400
-c standbydelaylow 14400
-c autopoweroffdelay 7200
-c standbydelay 14400
-c sleep 90
-c disksleep 10
EXPECTED
)"

assert_profile travel "$(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 14400
-b standbydelay 3600
-b disksleep 10
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-c disksleep 10
EXPECTED
)"

# Unknown profile falls back to default.
assert_profile bogus "$(cat <<'EXPECTED'
-b standbydelayhigh 600
-b standbydelaylow 600
-b autopoweroffdelay 1800
-b standbydelay 600
-b disksleep 10
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-c disksleep 10
EXPECTED
)"

: > "$PMSET_LOG"
"$POWER_SAVER" apply-delays travel
"$POWER_SAVER" enforce-sleep-policy
diff -u <(cat <<'EXPECTED'
-b standbydelayhigh 3600
-b standbydelaylow 3600
-b autopoweroffdelay 14400
-b standbydelay 3600
-b disksleep 10
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-c disksleep 10
-b standbydelayhigh 600
-b standbydelaylow 600
-b autopoweroffdelay 1800
-b standbydelay 600
-b disksleep 10
-c standbydelayhigh 10800
-c standbydelaylow 10800
-c autopoweroffdelay 3600
-c standbydelay 10800
-c sleep 90
-c disksleep 10
EXPECTED
) "$PMSET_LOG"

echo "Power Saver profile tests passed."
