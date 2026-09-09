#!/bin/bash
# Installed at /usr/local/sbin/wifi-ap-fallback by scripts/wifi-ap-fallback.sh.
# Not `set -e`: runs forever in a polling loop, and a single failed
# nmcli/DBus call should be logged and retried on the next tick, not kill
# the daemon.
set -u

CONFIG="/etc/wifi-ap-fallback/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

log() { logger -t wifi-ap-fallback "$1"; echo "$1"; }

wifi_connected() {
  local state
  state="$(nmcli -t -f GENERAL.STATE device show "$WIFI_DEV" 2>/dev/null | cut -d: -f1)"
  [[ "$state" == "100" ]]
}

ap_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "$AP_CONN_NAME"
}

stop_ap() {
  if ap_active; then
    log "Normal Wi-Fi is up — stopping emergency AP."
    nmcli connection down "$AP_CONN_NAME" >/dev/null 2>&1 || true
  fi
}

start_ap() {
  if ap_active; then
    return
  fi
  log "Wi-Fi unavailable — starting emergency AP ($AP_CONN_NAME)."
  nmcli device disconnect "$WIFI_DEV" >/dev/null 2>&1 || true
  sleep 2
  nmcli connection up "$AP_CONN_NAME" >/dev/null 2>&1 || log "ERROR: failed to start $AP_CONN_NAME"
}

try_reconnect() {
  log "Trying primary Wi-Fi: $PRIMARY_CONN"
  stop_ap
  sleep 2
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli connection up "$PRIMARY_CONN" >/dev/null 2>&1 || true
  for ((i = 0; i < WIFI_TIMEOUT; i++)); do
    if wifi_connected; then
      log "Wi-Fi connected: $PRIMARY_CONN"
      return 0
    fi
    sleep 1
  done
  log "Wi-Fi connection attempt failed."
  return 1
}

log "wifi-ap-fallback watchdog started (primary=$PRIMARY_CONN ap=$AP_CONN_NAME)"
nmcli radio wifi on >/dev/null 2>&1 || true

while true; do
  if wifi_connected; then
    stop_ap
  else
    try_reconnect || start_ap
  fi
  sleep "$CHECK_INTERVAL"
done
