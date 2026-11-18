#!/bin/bash
# Battery Commander (BC) Morning Report — runs at 8 AM daily (LaunchAgent).
# Generates the overnight sleep/drain summary + full report.
# Read-only: reads pmset log, bc-status, config. No settings changes, no SMC writes.
# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi

LOG="$DASH/actions.log"
REPORT_DIR="$DASH/reports"
mkdir -p "$REPORT_DIR"

STAMP=$(date '+%Y%m%d')
REPORT="$REPORT_DIR/morning-$STAMP.txt"
SUMMARY_FILE="$DASH/.overnight_summary"

# --- Overnight summary (read-only) ---
# Overnight window: yesterday 18:00 → now.
# Sleep/Wake/DarkWake lines carry Charge % + BATT/AC; together they are the
# overnight % timeline. Endpoints come from the genuine Sleep/Wake/DarkWake
# series, NOT from DarkWake lines alone: a DarkWake due to EC.ACAttach or
# EC.ACDetach carries a stale cached Charge % (fix 2026-11-13: the night
# 2026-11-12->13 reported 89% -> 89% instead of 89% -> 76%).
# (macOS date: -v-1d = yesterday, -j -f = parse a datetime to epoch.)
YESTERDAY=$(date -v-1d '+%Y-%m-%d')
TODAY=$(date '+%Y-%m-%d')
YEST_SHORT=$(date -v-1d '+%b %d')
TODAY_SHORT=$(date '+%b %d')

# Capture only the Sleep/Wake/DarkWake lines for yesterday + today (pmset -g log
# is slow; read it once and reuse it). Fields: $1=date $2=time $3=tz $4=event.
REL=$(pmset -g log 2>/dev/null | awk -v y="$YESTERDAY" -v t="$TODAY" '
    ($1 == y || $1 == t) && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake") { print }
')

# DarkWake lines in the overnight window (yesterday after 18:00, or today).
DW=$(printf '%s\n' "$REL" | awk -v y="$YESTERDAY" -v t="$TODAY" '
    $4 == "DarkWake" && (($1 == y && $2 >= "18:00:00") || $1 == t) { print }
')

# "Wake from Standby" (user wake, e.g. LidOpen) lines in the same window.
# NOTE: match $4 == "Wake" (not a grep for "Wake from Standby") — grep would
# also match "DarkWake from Standby" and contaminate the user-wake list.
UW=$(printf '%s\n' "$REL" | awk -v y="$YESTERDAY" -v t="$TODAY" '
    $4 == "Wake" && /Wake from Standby/ && (($1 == y && $2 >= "18:00:00") || $1 == t) { print }
')

# --- Overnight endpoints (fix 2026-11-13) ---
# Each line: "YYYY-MM-DD HH:MM:SS +0200 Sleep|Wake|DarkWake ... Using BATT|AC (Charge:NN%) ..."
# WIN = every Sleep/Wake/DarkWake line in the overnight window (yesterday
# after 18:00, or today) — the same window DW/UW use.
WIN=$(printf '%s\n' "$REL" | awk -v y="$YESTERDAY" -v t="$TODAY" '
    (($1 == y && $2 >= "18:00:00") || $1 == t) { print }
')
# GEN = the genuine readings in WIN. A line whose reason is EC.ACAttach or
# EC.ACDetach carries a stale cached Charge % (and a lagging power field),
# so it can NEVER be an endpoint. Dropping it means an endpoint that would
# have been such a line becomes the nearest genuine reading at/after it
# (e.g. the Sleep line that follows an ACAttach DarkWake in the same wake
# episode), or the last genuine reading before it when none follows.
GEN=$(printf '%s\n' "$WIN" | grep 'Charge:' | grep -v -E 'EC\.ACAttach|EC\.ACDetach')
# FIRST = the sleep-entry Sleep line that begins the overnight sleep period
# (fall back to the first genuine reading if the window has no Sleep line).
# LAST = the last genuine reading in the window.
if [ -n "$GEN" ]; then
    FIRST_LINE=$(printf '%s\n' "$GEN" | awk '$4 == "Sleep" { print; exit }')
    [ -z "$FIRST_LINE" ] && FIRST_LINE=$(printf '%s\n' "$GEN" | head -1)
    LAST_LINE=$(printf '%s\n' "$GEN" | tail -1)
else
    FIRST_LINE=""
    LAST_LINE=""
fi
# DarkWake count is unchanged (maintenance-wake counting only; DarkWake
# lines no longer supply the endpoints).
if [ -n "$DW" ]; then
    DW_COUNT=$(printf '%s\n' "$DW" | wc -l | tr -d ' ')
else
    DW_COUNT=0
fi

# _field <line> <n> — print field n of a pmset line.
_field() { printf '%s' "$1" | awk -v n="$2" '{ print $n }'; }
# _charge <line> — the Charge % (e.g. "(Charge:65%)" → 65).
_charge() { printf '%s' "$1" | grep -oE 'Charge:[0-9]+' | grep -oE '[0-9]+' | head -1; }
# _power <line> — "BATT" or "AC".
_power() {
    case "$1" in
        *"Using AC"*) printf 'AC' ;;
        *"Using BATT"*) printf 'BATT' ;;
        *"Using Batt"*) printf 'BATT' ;;
        *) printf '?' ;;
    esac
}
# _reason <line> — the DarkWake reason (after "due to ", before " Using").
_reason() { printf '%s' "$1" | sed -nE 's/.*due to ([^ ]+).*/\1/p' | head -1; }
# _epoch <"YYYY-MM-DD HH:MM:SS"> — epoch seconds (macOS date -j -f).
_epoch() { date -j -f "%Y-%m-%d %H:%M:%S" "$1" "+%s" 2>/dev/null || echo 0; }

if [ -n "$FIRST_LINE" ] && [ -n "$LAST_LINE" ]; then
    FIRST_DT="$(_field "$FIRST_LINE" 1) $(_field "$FIRST_LINE" 2)"
    LAST_DT="$(_field "$LAST_LINE" 1) $(_field "$LAST_LINE" 2)"
    FIRST_PCT=$(_charge "$FIRST_LINE")
    LAST_PCT=$(_charge "$LAST_LINE")
    FIRST_PWR=$(_power "$FIRST_LINE")
    LAST_PWR=$(_power "$LAST_LINE")
    [ -z "$FIRST_PCT" ] && FIRST_PCT="?"
    [ -z "$LAST_PCT" ] && LAST_PCT="?"
    # Total drain, duration (hours), rate (%/h).
    if [ "$FIRST_PCT" != "?" ] && [ "$LAST_PCT" != "?" ]; then
        DRAIN=$((FIRST_PCT - LAST_PCT))
    else
        DRAIN="?"
    fi
    # Signed drain display: DRAIN is FIRST-LAST, so it is NEGATIVE when
    # the battery charged overnight — "-$DRAIN%" would print "--5%"
    # (audit 2026-11-11, W20).
    if [ "$DRAIN" != "?" ]; then
        if [ "$DRAIN" -ge 0 ]; then _drain_disp="-$DRAIN%"; else _drain_disp="+$((-DRAIN))%"; fi
    else
        _drain_disp="?"
    fi
    START_EPOCH=$(_epoch "$FIRST_DT")
    END_EPOCH=$(_epoch "$LAST_DT")
    if [ "$START_EPOCH" -gt 0 ] && [ "$END_EPOCH" -gt "$START_EPOCH" ]; then
        DUR_H=$(awk -v s="$START_EPOCH" -v e="$END_EPOCH" 'BEGIN { printf "%.1f", (e-s)/3600 }')
        if [ "$DRAIN" != "?" ]; then
            RATE=$(awk -v d="$DRAIN" -v h="$DUR_H" 'BEGIN { if (h > 0) printf "%.1f", d/h; else printf "?" }')
        else
            RATE="?"
        fi
    else
        DUR_H="?"
        RATE="?"
    fi
    # Power: on battery if every DarkWake says BATT; on AC if any says AC.
    # (DW empty but endpoints exist: judge from the genuine series instead.)
    _pwr_src="$DW"
    [ -z "$_pwr_src" ] && _pwr_src="$GEN"
    if printf '%s\n' "$_pwr_src" | grep -q "Using AC"; then
        POWER="AC (plugged in during the night)"
        if printf '%s\n' "$_pwr_src" | grep -q "Using BATT"; then
            POWER="mixed (battery + AC)"
        fi
    else
        POWER="on battery"
    fi
    # Distinct DarkWake reasons (for the BC-involvement check).
    REASONS=$(printf '%s\n' "$DW" | sed -nE 's/.*due to ([^ ]+).*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ *$//')
else
    FIRST_DT="?"
    LAST_DT="?"
    FIRST_PCT="?"
    LAST_PCT="?"
    DRAIN="?"
    _drain_disp="?"
    DUR_H="?"
    RATE="?"
    POWER="?"
    REASONS=""
fi

# User wakes during the night: a "Wake from Standby" that is followed by a
# later DarkWake (the Mac went back to sleep after the user woke it). The
# morning wake-up is the last user Wake, after the last DarkWake — normal.
if [ -n "$UW" ]; then
    UW_COUNT=$(printf '%s\n' "$UW" | wc -l | tr -d ' ')
    LAST_UW=$(printf '%s\n' "$UW" | tail -1)
    LAST_UW_DT="$(_field "$LAST_UW" 1) $(_field "$LAST_UW" 2)"
    LAST_UW_PCT=$(_charge "$LAST_UW")
    # A night wake = a user Wake whose datetime is before the last DarkWake.
    NIGHT_WAKES=0
    if [ -n "$LAST_DT" ] && [ "$LAST_DT" != "?" ]; then
        NIGHT_WAKES=$(printf '%s\n' "$UW" | awk -v last="$LAST_DT" '
            { dt = $1 " " $2; if (dt < last) n++ }
            END { print n+0 }
        ')
    fi
else
    UW_COUNT=0
    LAST_UW=""
    LAST_UW_DT="?"
    LAST_UW_PCT="?"
    NIGHT_WAKES=0
fi

# Slept normally?
if [ "$DW_COUNT" -ge 1 ] && [ "$NIGHT_WAKES" -eq 0 ]; then
    SLEPT="yes — standby + maintenance wakes only"
elif [ "$DW_COUNT" -ge 1 ]; then
    SLEPT="no — woken $NIGHT_WAKES time(s) during the night"
else
    SLEPT="unknown — no standby wakes found (Mac may have been off or awake)"
fi

# BC involvement: BC schedules no wakes. If every DarkWake reason is a system
# maintenance reason, BC was not involved.
BC_INVOLVED="no — all wakes were system maintenance"
if [ -n "$REASONS" ]; then
    case "$REASONS" in
        *RTC*|*Maintenance*|*EC.*)
            # All reasons are system maintenance (RTC/Maintenance, EC.ACAttach,
            # EC.ACDetach). BC schedules no wakes.
            BC_INVOLVED="no — all wakes were system maintenance ($REASONS)"
            ;;
        *)
            BC_INVOLVED="check — unusual wake reason: $REASONS"
            ;;
    esac
else
    BC_INVOLVED="unknown — no wake reasons found"
fi

# Current % + hold status (bc-status, read-only; works during DarkWake).
BC_OUT=""
if [ -x "$DASH/bc-status" ]; then
    BC_OUT=$("$DASH/bc-status" 2>/dev/null)
fi
CUR_PCT=$(printf '%s\n' "$BC_OUT" | grep '^Capacity:' | sed -E 's/.*: *([0-9]+).*/\1/' | head -1)
CUR_BCLM=$(printf '%s\n' "$BC_OUT" | grep '^BCLM:' | sed -E 's/.*: *([0-9]+).*/\1/' | head -1)
CUR_HEALTH=$(printf '%s\n' "$BC_OUT" | grep '^Health:' | sed -E 's/.*: *([0-9]+).*/\1/' | head -1)
[ -z "$CUR_PCT" ] && CUR_PCT="?"
[ -z "$CUR_BCLM" ] && CUR_BCLM="?"
if [ "$CUR_BCLM" = "10" ]; then
    HOLD="holding (BCLM=10)"
elif [ "$CUR_BCLM" = "100" ]; then
    HOLD="not holding (BCLM=100)"
else
    HOLD="unknown (BCLM=$CUR_BCLM)"
fi

# Gauge-jump note: only if the last user Wake was RECENT (< 60 min ago) and
# the current % differs from the wake % by >5. (If the wake was hours ago the
# current % reflects charging, not a gauge jump.) The % at lid-open can
# understate the true charge — known phenomenon, e.g. 2026-11-11: 60% at
# lid-open → 72% in 5 min.
GAUGE_NOTE=""
NOW_EPOCH=$(date "+%s")
if [ -n "$LAST_UW" ] && [ "$LAST_UW_PCT" != "?" ] && [ "$CUR_PCT" != "?" ]; then
    WAKE_EPOCH=$(_epoch "$LAST_UW_DT")
    if [ "$WAKE_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - WAKE_EPOCH)) -lt 3600 ]; then
        _d=$((CUR_PCT - LAST_UW_PCT))
        [ "$_d" -lt 0 ] && _d=$((-_d))
        if [ "$_d" -gt 5 ]; then
            GAUGE_NOTE="Note: gauge jump — wake showed ${LAST_UW_PCT}%, now ${CUR_PCT}% (the % at lid-open can understate the true charge)."
        fi
    fi
fi

# One-line summary (also written to $SUMMARY_FILE for the plugin menu).
# ASCII arrows ("->") only: a multibyte arrow directly after a $VAR (e.g.
# "$YEST_SHORT→") is mangled by the shell (the value + the arrow's first
# byte are dropped — verified 2026-11-11). A "->" renders the same everywhere.
if [ -n "$FIRST_LINE" ] && [ "$FIRST_PCT" != "?" ] && [ "$LAST_PCT" != "?" ]; then
    SUMMARY_LINE="Last night ($YEST_SHORT -> $TODAY_SHORT): $FIRST_PCT% -> $LAST_PCT% ($_drain_disp, ${RATE}%/h)"
else
    SUMMARY_LINE="Last night: no standby data (Mac may have been off or awake)"
fi
printf '%s\n' "$SUMMARY_LINE" > "$SUMMARY_FILE" 2>/dev/null

# --- Sleep episode sidecar (design §2e; verification deployment
# 2026-11-14) ---
# Machine-readable KEY=value twin of the overnight numbers above,
# written next to .overnight_summary for the verification tracker
# (bc-verify judges the sleep/bc axes from it). Every value comes
# from the fixed endpoint logic above — that logic is unchanged; this
# block only formats its results. Written only when real endpoints
# with numeric values exist; a night with no standby data produces
# no sidecar (the verifier then honestly has no sleep episode).
# BC involvement mapping: the report's "no" -> BC_INVOLVED=false;
# "check"/"unknown" are not proof of involvement, so they map to
# BC_INVOLVED=false + DATA_INCOMPLETE=true (bc-verify: UNVERIFIED).
SIDECAR="$DASH/.sleep_episode"
_num() { case "$1" in ''|*[!0-9.-]*) return 1 ;; *) return 0 ;; esac; }
if [ -n "$FIRST_LINE" ] && _num "$FIRST_PCT" && _num "$LAST_PCT" && _num "$DRAIN" && _num "$RATE"; then
    _sc_reasons=$(printf '%s' "$REASONS" | tr ' ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')
    if [ "${NIGHT_WAKES:-0}" -gt 0 ] 2>/dev/null; then
        _sc_reasons="${_sc_reasons:+$_sc_reasons,}user"
    fi
    if [ "${DW_COUNT:-0}" -ge 1 ] && [ "${NIGHT_WAKES:-0}" -eq 0 ]; then
        _sc_slept="true"
    else
        _sc_slept="false"
    fi
    case "$FIRST_PWR" in
        AC) _sc_onac="true" ;;
        *)  _sc_onac="false" ;;
    esac
    case "$BC_INVOLVED" in
        no*)      _sc_bc="false"; _sc_incomplete="false" ;;
        *)        _sc_bc="false"; _sc_incomplete="true" ;;
    esac
    {
        echo "SLEEP_START_TS=$FIRST_DT"
        echo "SLEEP_START_PCT=$FIRST_PCT"
        echo "WAKE_TS=$LAST_DT"
        echo "WAKE_PCT=$LAST_PCT"
        echo "DRAIN_PCT=$DRAIN"
        echo "RATE_PCT_H=$RATE"
        echo "DARKWAKES=$DW_COUNT"
        echo "WAKE_REASONS=$_sc_reasons"
        echo "SLEPT_NORMALLY=$_sc_slept"
        echo "BC_INVOLVED=$_sc_bc"
        echo "ON_AC=$_sc_onac"
        echo "EXTERNAL_NOTES="
        echo "DATA_INCOMPLETE=$_sc_incomplete"
    } > "$SIDECAR.tmp" 2>/dev/null && mv "$SIDECAR.tmp" "$SIDECAR" 2>/dev/null || true
fi

# --- Full report ---
{
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Battery Commander (BC) Morning Report — $(date '+%Y-%m-%d %H:%M')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "─── Overnight Summary ───"
    if [ -n "$FIRST_LINE" ]; then
        echo "Sleep start (first reading): $FIRST_DT — $FIRST_PCT% ($FIRST_PWR)"
        echo "Last reading:                $LAST_DT — $LAST_PCT% ($LAST_PWR)"
        echo "Total drain:                 $_drain_disp over ${DUR_H} h"
        echo "Drain rate:                  ${RATE}%/h (known baseline: 1.2–1.7%/h)"
        echo "Maintenance wakes:           $DW_COUNT (DarkWake)"
        echo "Power overnight:             $POWER"
        echo "Slept normally:              $SLEPT"
        echo "BC involved:                 $BC_INVOLVED"
        if [ -n "$LAST_UW" ]; then
            echo "Morning wake:                $LAST_UW_DT — $LAST_UW_PCT%"
        fi
    else
        echo "No standby data for last night (Mac may have been off or awake)."
    fi
    echo "Current:                     $CUR_PCT% — $HOLD (Health ${CUR_HEALTH:-?}%)"
    [ -n "$GAUGE_NOTE" ] && echo "$GAUGE_NOTE"
    echo ""
    echo "─── Battery Now ───"
    if [ -n "$BC_OUT" ]; then
        printf '%s\n' "$BC_OUT"
    else
        echo "(bc-status not available — will refresh on next plugin run)"
    fi
    echo ""
    echo "─── Overnight Wake Reasons ───"
    if [ -n "$DW" ]; then
        printf '%s\n' "$DW" | sed 's/^/  /'
    else
        echo "(no DarkWake lines in the overnight window)"
    fi
    if [ -n "$UW" ]; then
        echo ""
        echo "─── User Wakes (LidOpen) ───"
        printf '%s\n' "$UW" | sed 's/^/  /'
    fi
    echo ""
    echo "─── Recent Actions ───"
    tail -20 "$LOG" 2>/dev/null || echo "(no actions log)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
} > "$REPORT"

# Notification — the message IS the summary, so the answer is visible even if
# the report itself is opened later (or only seen in Notification Center).
# App-native transport (final cleanup 2026-11-18): queue one
# title<TAB>body line; BatteryCommander.app posts it natively.
# (The old notifier's click-to-open-the-report action has no
# equivalent in the queue transport; the report file itself is
# unchanged and stays at $REPORT.)
{ _mt=$(printf '%s' "Battery Commander — Morning Report" | tr '\n\t' '  ')
  _mb=$(printf '%s' "$SUMMARY_LINE" | tr '\n\t' '  ')
  printf '%s\t%s\n' "$_mt" "$_mb" >> "$DASH/.notify_queue" 2>/dev/null || true; }

# --- Verification scoring (design §5 hosting decision; verification
# deployment 2026-11-14) ---
# bc-verify runs as a step of THIS agent's run, immediately after the
# morning report — no new agent. It ingests the sidecar written above,
# refreshes .verification_state/.verification_summary + the daily
# verification report, evaluates Phase C (§7.1), and applies the §6
# notification policy. Guarded: verification can never affect the
# report or the notification above.
if [ -x "$DASH/bc-verify-run.sh" ]; then
    "$DASH/bc-verify-run.sh" morning >/dev/null 2>&1 || true
fi
