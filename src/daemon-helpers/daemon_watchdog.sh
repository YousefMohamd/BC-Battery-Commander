#!/bin/bash
BAT="/usr/local/bin/battopt"; LOG="$HOME/.battopt-swiftbar/actions.log"
if ! timeout 3 sudo -n "$BAT" status >/dev/null 2>&1; then
  echo "[$(date +%H:%M:%S)] watchdog: daemon hang, restarting" >> "$LOG"
  sudo -n /usr/local/bin/battopt-daemon-restart >/dev/null 2>&1; sleep 3
  if ! timeout 3 sudo -n "$BAT" status >/dev/null 2>&1; then
    "$HOME/.battopt-swiftbar/force_reset.sh" >/dev/null 2>&1
  fi
  [ -f "$HOME/.battopt-swiftbar/config" ] && source "$HOME/.battopt-swiftbar/config"
  sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
fi
