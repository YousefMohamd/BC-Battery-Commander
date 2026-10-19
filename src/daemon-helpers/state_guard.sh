#!/bin/bash
# Shared Protocol: state_guard.sh
#
# Callers must acquire and release locks in the same shell execution context.
# Bash 3.2 retains $$ in subshells; a PID alone does not establish ownership.
# Acquisition tokens, not PIDs, authorize unlock.
#
# .desired_state is one pending slot. Equal-priority submissions replace it.
# Successful submission means accepted into that slot, not executed.
#
# Session publication spans separate files and is not a filesystem transaction.
# .session is authoritative and is published last.
#
# SG_NONBLOCKING=1 selects a single lock attempt for functions that acquire the
# guard internally. A scheduler can use a local SG_NONBLOCKING=1 variable to
# defer publication rather than waiting through the blocking retry loop.

SG_DIR="${SG_DIR:-$HOME/.battopt-swiftbar}"
SG_LOCK="$SG_DIR/.state_guard.lock"
SG_TOKEN="$SG_DIR/.active_token"
SG_MODE="$SG_DIR/.active_mode"
SG_SESSION="$SG_DIR/.session"
SG_HEARTBEAT="$SG_DIR/.sentinel_heartbeat"
SG_DESIRED="$SG_DIR/.desired_state"
SG_SEQUENCE="$SG_DIR/.sequence"

# Protocol integers use a portable, explicitly bounded decimal range.
SG_UINT_MAX=2147483647

guard_field_valid() {
    [ "$#" -eq 1 ] || return 1
    case "$1" in
        ''|*'|'*|*$'\r'*|*$'\n'*) return 1 ;;
    esac
    return 0
}

guard_uint() {
    [ "$#" -eq 2 ] || return 1
    local value="$1" maximum="$2"
    local LC_ALL=C

    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    case "$maximum" in ''|*[!0-9]*) return 1 ;; esac

    while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
        value="${value#0}"
    done
    while [ "${#maximum}" -gt 1 ] &&
          [ "${maximum#0}" != "$maximum" ]; do
        maximum="${maximum#0}"
    done

    [ "${#value}" -le "${#maximum}" ] || return 1
    if [ "${#value}" -eq "${#maximum}" ] &&
       [[ "$value" > "$maximum" ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

_guard_mode_valid() {
    case "$1" in
        idle|hold|charge_full|discharge|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

_guard_record_fields() {
    local record="$1" remainder count=1
    case "$record" in
        ''|*$'\r'*|*$'\n'*) return 1 ;;
    esac
    remainder="$record"
    while [[ "$remainder" == *'|'* ]]; do
        remainder="${remainder#*|}"
        count=$((count + 1))
    done
    SG_FIELD_COUNT="$count"
}

guard_parse_request() {
    SG_R_VERSION=
    SG_R_ID=
    SG_R_ORIGIN=
    SG_R_PRIORITY=
    SG_R_ACTION=
    SG_R_ARG1=
    SG_R_ARG2=
    SG_R_ARG3=
    SG_R_ARG4=
    SG_R_EXPECTED_TOKEN=
    SG_R_CONFIG_REVISION=

    [ "$#" -eq 1 ] || return 1
    _guard_record_fields "$1" || return 1
    case "$SG_FIELD_COUNT" in 9|11) ;; *) return 1 ;; esac

    local version id origin priority action arg1 arg2 arg3 arg4 token revision
    IFS='|' read -r version id origin priority action \
        arg1 arg2 arg3 arg4 token revision <<< "$1"

    [ "$version" = 1 ] || return 1
    if [ "$SG_FIELD_COUNT" -eq 9 ]; then
        token=-
        revision=0
    fi

    local field
    for field in "$origin" "$action" "$arg1" "$arg2" "$arg3" \
                 "$arg4" "$token"; do
        guard_field_valid "$field" || return 1
    done

    id=$(guard_uint "$id" "$SG_UINT_MAX") || return 1
    [ "$id" != 0 ] || return 1
    priority=$(guard_uint "$priority" "$SG_UINT_MAX") || return 1
    revision=$(guard_uint "$revision" "$SG_UINT_MAX") || return 1

    SG_R_VERSION=1
    SG_R_ID="$id"
    SG_R_ORIGIN="$origin"
    SG_R_PRIORITY="$priority"
    SG_R_ACTION="$action"
    SG_R_ARG1="$arg1"
    SG_R_ARG2="$arg2"
    SG_R_ARG3="$arg3"
    SG_R_ARG4="$arg4"
    SG_R_EXPECTED_TOKEN="$token"
    SG_R_CONFIG_REVISION="$revision"
    return 0
}

guard_parse_session() {
    SG_S_VERSION=
    SG_S_OWNER=
    SG_S_TOKEN=
    SG_S_MODE=
    SG_S_PHASE=
    SG_S_ORIGIN=
    SG_S_TARGET=
    SG_S_UPPER=
    SG_S_LOWER=
    SG_S_TIMESTAMP=
    SG_S_CONFIG_REVISION=

    [ "$#" -eq 1 ] || return 1
    _guard_record_fields "$1" || return 1
    [ "$SG_FIELD_COUNT" -eq 11 ] || return 1

    local version owner token mode phase origin target upper lower timestamp revision
    IFS='|' read -r version owner token mode phase origin \
        target upper lower timestamp revision <<< "$1"

    [ "$version" = 1 ] || return 1
    local field
    for field in "$owner" "$token" "$phase" "$origin"; do
        guard_field_valid "$field" || return 1
    done
    [ "$owner" != - ] || return 1
    _guard_mode_valid "$mode" || return 1
    if [ "$mode" != idle ]; then
        [ "$token" != - ] || return 1
    fi

    if [ "$target" != - ]; then
        target=$(guard_uint "$target" 100) || return 1
    fi
    if [ "$upper" != - ]; then
        upper=$(guard_uint "$upper" 100) || return 1
    fi
    if [ "$lower" != - ]; then
        lower=$(guard_uint "$lower" 100) || return 1
    fi
    timestamp=$(guard_uint "$timestamp" "$SG_UINT_MAX") || return 1
    revision=$(guard_uint "$revision" "$SG_UINT_MAX") || return 1

    SG_S_VERSION=1
    SG_S_OWNER="$owner"
    SG_S_TOKEN="$token"
    SG_S_MODE="$mode"
    SG_S_PHASE="$phase"
    SG_S_ORIGIN="$origin"
    SG_S_TARGET="$target"
    SG_S_UPPER="$upper"
    SG_S_LOWER="$lower"
    SG_S_TIMESTAMP="$timestamp"
    SG_S_CONFIG_REVISION="$revision"
    return 0
}

guard_parse_heartbeat() {
    SG_H_VERSION=
    SG_H_OWNER=
    SG_H_TOKEN=
    SG_H_MODE=
    SG_H_TIMESTAMP=

    [ "$#" -eq 1 ] || return 1
    _guard_record_fields "$1" || return 1
    [ "$SG_FIELD_COUNT" -eq 5 ] || return 1

    local version owner token mode timestamp
    IFS='|' read -r version owner token mode timestamp <<< "$1"

    [ "$version" = 1 ] || return 1
    guard_field_valid "$owner" || return 1
    [ "$owner" != - ] || return 1
    guard_field_valid "$token" || return 1
    _guard_mode_valid "$mode" || return 1
    if [ "$mode" != idle ]; then
        [ "$token" != - ] || return 1
    fi
    timestamp=$(guard_uint "$timestamp" "$SG_UINT_MAX") || return 1

    SG_H_VERSION=1
    SG_H_OWNER="$owner"
    SG_H_TOKEN="$token"
    SG_H_MODE="$mode"
    SG_H_TIMESTAMP="$timestamp"
    return 0
}

atomic_write() {
    [ "$#" -eq 2 ] || return 1
    local file="$1" content="$2" tmp rc

    tmp=$(mktemp "${file}.tmp.XXXXXXXXXX") || return $?
    if printf '%s' "$content" > "$tmp"; then
        if mv -f "$tmp" "$file"; then
            return 0
        else
            rc=$?
        fi
    else
        rc=$?
    fi

    rm -f "$tmp"
    return "$rc"
}

# Read an entire file without losing trailing newlines to command substitution.
# Parsers reject extra lines, including a second trailing newline.
_guard_read_record() {
    local file="$1" data rc
    data=$(
        cat "$file"
        rc=$?
        printf '\001'
        exit "$rc"
    ) || return $?
    data="${data%$'\001'}"
    case "$data" in *$'\n') data="${data%$'\n'}" ;; esac
    SG_RECORD="$data"
}

_guard_owner_parse() {
    local record="$1" pid token
    _guard_record_fields "$record" || return 1
    [ "$SG_FIELD_COUNT" -eq 2 ] || return 1
    IFS='|' read -r pid token <<< "$record"
    pid=$(guard_uint "$pid" "$SG_UINT_MAX") || return 1
    [ "$pid" != 0 ] || return 1
    guard_field_valid "$token" || return 1
    SG_OWNER_PID="$pid"
    SG_OWNER_TOKEN="$token"
}

_guard_owner_dead() {
    local pid="$1" probe
    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    # A failed kill probe can mean insufficient permission. Treat a visible
    # process, or a failed process-table query, as unavailable for recovery.
    probe=$(ps -A -o pid= 2>/dev/null) || return 1
    local candidate
    while read -r candidate; do
        [ "$candidate" = "$pid" ] && return 1
    done <<< "$probe"
    return 0
}

_guard_owned() {
    [ -n "${SG_ACQUIRED_TOKEN:-}" ] || return 1
    _guard_read_record "$SG_LOCK/owner" 2>/dev/null || return 1
    _guard_owner_parse "$SG_RECORD" || return 1
    [ "$SG_OWNER_PID" = "$$" ] &&
        [ "$SG_OWNER_TOKEN" = "$SG_ACQUIRED_TOKEN" ]
}

_guard_recover() {
    local original="$1" recovery="${SG_LOCK}.recovery"
    local marker token recovery_record current

    # Never reclaim a recovery directory. An interrupted recovery intentionally
    # leaves a barrier that requires manual inspection.
    mkdir "$recovery" 2>/dev/null || return 1
    marker=$(mktemp "$recovery/token.XXXXXXXXXX") || return 1
    token="${marker##*/}"
    recovery_record="$$|$token"
    atomic_write "$recovery/owner" "$recovery_record"$'\n' || return 1

    _guard_read_record "$SG_LOCK/owner" 2>/dev/null || return 1
    current="$SG_RECORD"
    [ "$current" = "$original" ] || return 1
    _guard_owner_parse "$current" || return 1
    _guard_owner_dead "$SG_OWNER_PID" || return 1

    # Recheck both records immediately before removal.
    _guard_read_record "$recovery/owner" 2>/dev/null || return 1
    [ "$SG_RECORD" = "$recovery_record" ] || return 1
    _guard_read_record "$SG_LOCK/owner" 2>/dev/null || return 1
    [ "$SG_RECORD" = "$original" ] || return 1

    # Remove only known files. Unexpected contents fail closed.
    rm -f "$SG_LOCK/owner" || return 1
    rmdir "$SG_LOCK" || return 1

    _guard_read_record "$recovery/owner" 2>/dev/null || return 1
    [ "$SG_RECORD" = "$recovery_record" ] || return 1
    rm -f "$marker" "$recovery/owner" || return 1
    rmdir "$recovery"
}

guard_try_lock() {
    [ -z "${SG_ACQUIRED_TOKEN:-}" ] || {
        printf '%s\n' 'state_guard: nested acquisition rejected' >&2
        return 1
    }
    mkdir -p "$SG_DIR" 2>/dev/null || return $?

    local recovery="${SG_LOCK}.recovery" marker token original rc
    [ ! -e "$recovery" ] || return 1

    if ! mkdir "$SG_LOCK" 2>/dev/null; then
        _guard_read_record "$SG_LOCK/owner" 2>/dev/null || return 1
        original="$SG_RECORD"
        _guard_owner_parse "$original" || return 1
        _guard_owner_dead "$SG_OWNER_PID" || return 1
        _guard_recover "$original" || return 1
        # Recovery does not count as acquisition. The caller must try again.
        return 1
    fi

    # A recovery barrier may have appeared after the first check.
    if [ -e "$recovery" ]; then
        rmdir "$SG_LOCK" 2>/dev/null
        return 1
    fi

    marker=$(mktemp "$SG_DIR/.guard-acquisition.XXXXXXXXXX") || {
        rc=$?
        rmdir "$SG_LOCK" 2>/dev/null
        return "$rc"
    }
    token="${marker##*/}"

    if ! atomic_write "$SG_LOCK/owner" "$$|$token"$'\n'; then
        rm -f "$marker"
        # Missing or partially published ownership must remain unavailable.
        return 1
    fi
    rm -f "$marker" || return 1

    SG_ACQUIRED_TOKEN="$token"
    SG_ACQUIRED_CONTEXT="${BASH_SUBSHELL:-0}"
    return 0
}

guard_lock() {
    [ -z "${SG_ACQUIRED_TOKEN:-}" ] || {
        printf '%s\n' 'state_guard: nested acquisition rejected' >&2
        return 1
    }
    mkdir -p "$SG_DIR" 2>/dev/null || return $?
    if [ "${SG_NONBLOCKING:-0}" = 1 ]; then
        guard_try_lock
        return $?
    fi

    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        guard_try_lock && return 0
        attempt=$((attempt + 1))
        [ "$attempt" -ge 30 ] || sleep 0.1
    done
    return 1
}

guard_unlock() {
    [ "${SG_ACQUIRED_CONTEXT:-unset}" = "${BASH_SUBSHELL:-0}" ] ||
        return 1
    _guard_owned || return 1
    rm -f "$SG_LOCK/owner" || return $?
    rmdir "$SG_LOCK" || return $?
    SG_ACQUIRED_TOKEN=
    SG_ACQUIRED_CONTEXT=
    return 0
}

_guard_finish() {
    local rc="$1" unlock_rc
    guard_unlock
    unlock_rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    return "$unlock_rc"
}

next_sequence() {
    # Command substitution may read inherited ownership to allocate an ID.
    # It must never acquire or release the parent's guard.
    _guard_owned || return 1
    local seq=0 rc
    if [ -e "$SG_SEQUENCE" ]; then
        _guard_read_record "$SG_SEQUENCE" || return $?
        seq=$(guard_uint "$SG_RECORD" "$SG_UINT_MAX") || return 1
    fi
    [ "$seq" -lt "$SG_UINT_MAX" ] || return 1
    seq=$((seq + 1))
    atomic_write "$SG_SEQUENCE" "$seq"$'\n'
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$seq"
}

submit_request() {
    local origin="${1:--}" action="${2:--}"
    local arg1="${3:--}" arg2="${4:--}" arg3="${5:--}" arg4="${6:--}"
    local exp_token="${7:--}" conf_rev="${8:-0}"
    local priority=100 field req_id rc

    for field in "$origin" "$action" "$arg1" "$arg2" "$arg3" \
                 "$arg4" "$exp_token"; do
        guard_field_valid "$field" || return 1
    done
    [ "$origin" != - ] && [ "$action" != - ] || return 1
    conf_rev=$(guard_uint "$conf_rev" "$SG_UINT_MAX") || return 1

    case "$origin" in
        user) priority=300 ;;
        guardian|ac|enforce|wake|sleep|watcher|recovery) priority=200 ;;
    esac

    guard_lock || return $?

    if [ -e "$SG_DESIRED" ]; then
        if ! _guard_read_record "$SG_DESIRED"; then
            rc=$?
            # Do not overwrite an unreadable record.
            _guard_finish 1
            return $?
        fi
        if guard_parse_request "$SG_RECORD"; then
            if [ "$SG_R_PRIORITY" -gt "$priority" ]; then
                _guard_finish 2
                return $?
            fi
        else
            printf '%s\n' \
                'state_guard: replacing malformed pending request' >&2
        fi
    fi

    req_id=$(next_sequence)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        atomic_write "$SG_DESIRED" \
            "1|$req_id|$origin|$priority|$action|$arg1|$arg2|$arg3|$arg4|$exp_token|$conf_rev"$'\n'
        rc=$?
    fi
    _guard_finish "$rc"
}

guard_publish_session() {
    [ "$#" -eq 10 ] || return 1
    local owner="$1" token="$2" mode="$3" phase="$4" origin="$5"
    local target="$6" upper="$7" lower="$8" timestamp="$9"
    shift 9
    local revision="$1" record rc

    record="1|$owner|$token|$mode|$phase|$origin|$target|$upper|$lower|$timestamp|$revision"
    guard_parse_session "$record" || return 1

    target="$SG_S_TARGET"
    upper="$SG_S_UPPER"
    lower="$SG_S_LOWER"
    timestamp="$SG_S_TIMESTAMP"
    revision="$SG_S_CONFIG_REVISION"
    record="1|$owner|$token|$mode|$phase|$origin|$target|$upper|$lower|$timestamp|$revision"

    guard_lock || return $?
    atomic_write "$SG_MODE" "$mode"$'\n'
    rc=$?

    if [ "$rc" -eq 0 ]; then
        if [ "$mode" = idle ]; then
            rm -f "$SG_TOKEN"
        else
            atomic_write "$SG_TOKEN" "$token"$'\n'
        fi
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        atomic_write "$SG_HEARTBEAT" \
            "1|$owner|$token|$mode|$timestamp"$'\n'
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        atomic_write "$SG_SESSION" "$record"$'\n'
        rc=$?
    fi
    _guard_finish "$rc"
}

touch_heartbeat() {
    [ "$#" -eq 3 ] || return 1
    local owner="$1" token="$2" mode="$3" timestamp record rc
    timestamp=$(date +%s) || return $?
    record="1|$owner|$token|$mode|$timestamp"
    guard_parse_heartbeat "$record" || return 1

    guard_lock || return $?
    atomic_write "$SG_HEARTBEAT" "$record"$'\n'
    rc=$?
    _guard_finish "$rc"
}

check_heartbeat() {
    [ "$#" -eq 3 ] || return 1
    local owner="$1" token="$2" mode="$3" now age
    _guard_read_record "$SG_HEARTBEAT" 2>/dev/null || return 1
    guard_parse_heartbeat "$SG_RECORD" || return 1

    [ "$SG_H_OWNER" = "$owner" ] || return 1
    [ "$SG_H_TOKEN" = "$token" ] || return 1
    [ "$SG_H_MODE" = "$mode" ] || return 1

    now=$(date +%s) || return 1
    now=$(guard_uint "$now" "$SG_UINT_MAX") || return 1
    [ "$now" -ge "$SG_H_TIMESTAMP" ] || return 1
    age=$((now - SG_H_TIMESTAMP))
    [ "$age" -le 15 ]
}

read_effective_session() {
    local mode=idle
    if ! guard_lock; then
        printf 'idle\n'
        return 0
    fi

    if _guard_read_record "$SG_SESSION" 2>/dev/null &&
       guard_parse_session "$SG_RECORD"; then
        if check_heartbeat "$SG_S_OWNER" "$SG_S_TOKEN" "$SG_S_MODE"; then
            mode="$SG_S_MODE"
        fi
    fi

    guard_unlock || mode=idle
    printf '%s\n' "$mode"
    return 0
}

guard_session_active() {
    local mode
    mode=$(read_effective_session)
    case "$mode" in
        charge_full|discharge|hold|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

# Legacy compatibility helpers write legacy files only. They never fabricate a
# Sentinel session or heartbeat.

guard_new_token() {
    [ "$#" -eq 1 ] || return 1
    guard_field_valid "$1" || return 1
    local marker token rc
    marker=$(mktemp "$SG_DIR/.legacy-token.XXXXXXXXXX") || return $?
    token="${marker##*/}"
    rm -f "$marker"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s_%s_%s' "$$" "$token" "$1"
}

guard_token() {
    cat "$SG_TOKEN" 2>/dev/null
}

guard_token_matches() {
    [ "$#" -eq 1 ] || return 1
    guard_field_valid "$1" || return 1
    [ "$(guard_token)" = "$1" ]
}

guard_token_write_locked() {
    [ "$#" -eq 1 ] || return 1
    _guard_owned || return 1
    local mode="$1" token
    _guard_mode_valid "$mode" || return 1
    token=$(guard_new_token "$mode") || return $?
    atomic_write "$SG_TOKEN" "$token"$'\n' || return $?
    atomic_write "$SG_MODE" "$mode"$'\n' || return $?
    printf '%s\n' "$token"
}

guard_token_clear_locked() {
    _guard_owned || return 1
    rm -f "$SG_TOKEN" || return $?
    atomic_write "$SG_MODE" $'idle\n'
}

guard_session_begin() {
    [ "$#" -eq 1 ] || return 1
    _guard_mode_valid "$1" || return 1
    guard_lock || return $?
    local token rc
    token=$(guard_token_write_locked "$1")
    rc=$?
    _guard_finish "$rc"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$token"
}

guard_session_end() {
    [ "$#" -eq 1 ] || return 1
    guard_field_valid "$1" || return 1
    guard_lock || return $?
    local rc=1
    if guard_token_matches "$1"; then
        guard_token_clear_locked
        rc=$?
    fi
    _guard_finish "$rc"
}
