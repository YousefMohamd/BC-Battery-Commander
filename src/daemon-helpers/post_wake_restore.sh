#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
# Post-Wake Restore — Minimal
# Spotlight, Photos, TM auto-restore when RAM is on

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] post_wake: $1" >> "$LOG"; }

# Only restore audio apps if they were paused
# (In simplified version, we killed them, so nothing to restore)

# SMC resets to 100/99 after deep sleep — re-assert
if [ -n "${LAST_UPPER:-}" ]; then
  # ── Stop charging before re-applying limit ──
  # Without this, if battery is already above LAST_UPPER, charging
  # continues to 100% until guardian runs (up to 2 min later).
  sudo -n /usr/local/bin/battopt charge stop >/dev/null 2>&1 || true
  sudo pkill -9 -f "battopt charge " 2>/dev/null || true

  # ── If battery is already above target, no point waiting for guardian ──
  _C=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
  _M=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
  [ -n "$_C" ] && [ -n "$_M" ] && [ "$_M" -gt 0 ] && _P=$(( (_C * 100 + _M / 2) / _M ))
  [ "${_P:-0}" -gt "${LAST_UPPER:-100}" ] && log "post_wake: battery ${_P}% > target ${LAST_UPPER}%, will drain naturally"

  sudo -n /usr/local/bin/battopt limit "${LAST_UPPER}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1; RC=$?
  sleep 1
  V=$(sudo -n /usr/local/bin/battopt status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ "$RC" -ne 0 ] || [ "$V" != "${LAST_UPPER}" ]; then
    log "post_wake: SMC mismatch want=${LAST_UPPER} got=${V} rc=${RC} retry"
    sleep 2; sudo -n /usr/local/bin/battopt limit "${LAST_UPPER}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
  fi
  log "post_wake: re-applied ${LAST_UPPER}/${LAST_LOWER:-80} V=${V}"
fi
log "Wake complete"
rm -f "$HOME/.battopt-swiftbar/.armed_for_sleep" "$HOME/.battopt-swiftbar/.pre_sleep_done"
# Cancel RTC maintenance wakes (they drain battery overnight)
sudo -n /usr/bin/pmset schedule cancelall 2>/dev/null || true

exit 0
