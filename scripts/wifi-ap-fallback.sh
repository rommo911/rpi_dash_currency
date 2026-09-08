#!/usr/bin/env bash
# Adds an emergency Wi-Fi Access Point fallback on top of an already
# working NetworkManager Wi-Fi connection: if the Pi ever loses that
# network (router down, wrong password after a change, moved somewhere
# new), wlan0 automatically starts broadcasting its own AP so you can
# still connect to it directly (e.g. to SSH in and fix things) instead of
# the Pi going dark on the network. The moment the configured Wi-Fi is
# reachable again, it drops the AP and reconnects on its own — no manual
# intervention either direction.
#
# Assumes a Wi-Fi client connection already exists in NetworkManager
# (provision-pi.sh's network step sets one up, or use 'nmcli device wifi
# connect' / raspi-config yourself) — this script only layers the AP
# fallback on top of it, it doesn't configure normal Wi-Fi itself. Safe to
# re-run any time (from provision-pi.sh, or standalone later) to change
# the AP SSID/password or refresh the watchdog service.
#
# Usage:
#   ./wifi-ap-fallback.sh
#
# Optional env vars (all skip their interactive prompt when set):
#   WIFI_CONNECTION   Name of the existing NetworkManager Wi-Fi connection
#                      to treat as primary
#   AP_SSID            Emergency AP SSID
#   AP_PASSWORD        Emergency AP password (must be >= 8 characters)

set -euo pipefail

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

AP_CONN_NAME="Emergency-AP"
AP_IP="192.168.50.1/24"
WIFI_TIMEOUT="${WIFI_TIMEOUT:-30}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"

CONFIG_DIR="/etc/wifi-ap-fallback"
CONFIG_FILE="$CONFIG_DIR/config"
WATCHDOG="/usr/local/sbin/wifi-ap-fallback"
SERVICE_FILE="/etc/systemd/system/wifi-ap-fallback.service"

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal sudo user, not as root — it calls sudo where needed."
  exit 1
fi

if ! command -v nmcli >/dev/null 2>&1; then
  warn "nmcli (NetworkManager) not found — this Pi isn't using NetworkManager for Wi-Fi, can't continue."
  exit 1
fi

WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')" || true
if [[ -z "$WIFI_DEV" ]]; then
  warn "No Wi-Fi device detected on this Pi."
  exit 1
fi

pick_primary_connection() {
  if [[ -n "${WIFI_CONNECTION:-}" ]]; then
    PRIMARY_CONN="$WIFI_CONNECTION"
    return
  fi

  local active_conn
  active_conn="$(nmcli -t -f GENERAL.CONNECTION device show "$WIFI_DEV" 2>/dev/null | cut -d: -f2)" || true

  local conns=()
  while IFS=: read -r name type; do
    [[ "$type" == "802-11-wireless" && "$name" != "$AP_CONN_NAME" ]] && conns+=("$name")
  done < <(nmcli -t -f NAME,TYPE connection show)

  if [[ "${#conns[@]}" -eq 0 ]]; then
    warn "No saved Wi-Fi connections found. Connect to Wi-Fi first (provision-pi.sh's network step, 'nmcli device wifi connect ...', or raspi-config), then re-run this script."
    exit 1
  fi

  if [[ -n "$active_conn" && "$active_conn" != "--" ]]; then
    read -rp "Use the currently active Wi-Fi connection '$active_conn' as the primary network? [Y/n]: " use_active
    if [[ "${use_active,,}" != "n" ]]; then
      PRIMARY_CONN="$active_conn"
      return
    fi
  fi

  echo "Saved Wi-Fi connections:"
  local i=1 name
  for name in "${conns[@]}"; do
    printf "  %2d) %s\n" "$i" "$name"
    ((i++))
  done
  read -rp "Enter a number: " sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#conns[@]} )); then
    warn "Invalid selection."
    exit 1
  fi
  PRIMARY_CONN="${conns[$((sel - 1))]}"
}

log "Choosing the primary Wi-Fi connection"
pick_primary_connection
echo "Primary Wi-Fi connection: $PRIMARY_CONN"

# Make sure it's the one NetworkManager prefers to reconnect to.
sudo nmcli connection modify "$PRIMARY_CONN" connection.autoconnect yes connection.autoconnect-priority 100

# ---------------------------------------------------------------------------
log "Emergency AP configuration"

if [[ -z "${AP_SSID:-}" ]]; then
  read -rp "Emergency AP SSID [Pi-Emergency]: " AP_SSID
  AP_SSID="${AP_SSID:-Pi-Emergency}"
fi

if [[ -z "${AP_PASSWORD:-}" ]]; then
  while true; do
    read -rsp "Emergency AP password (min 8 characters): " AP_PASSWORD
    echo
    [[ "${#AP_PASSWORD}" -ge 8 ]] && break
    warn "Password must be at least 8 characters."
  done
fi

# ---------------------------------------------------------------------------
log "Creating the emergency AP profile"
# Idempotent: delete-then-recreate rather than modify-in-place, so a
# re-run with a different SSID/password never leaves stale settings behind.
sudo nmcli connection delete "$AP_CONN_NAME" >/dev/null 2>&1 || true
sudo nmcli connection add \
  type wifi ifname "$WIFI_DEV" mode ap con-name "$AP_CONN_NAME" ssid "$AP_SSID" autoconnect no
sudo nmcli connection modify "$AP_CONN_NAME" 802-11-wireless.band bg
sudo nmcli connection modify "$AP_CONN_NAME" ipv4.method shared ipv4.addresses "$AP_IP"
sudo nmcli connection modify "$AP_CONN_NAME" ipv6.method disabled
sudo nmcli connection modify "$AP_CONN_NAME" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$AP_CONN_NAME" wifi-sec.psk "$AP_PASSWORD"

# ---------------------------------------------------------------------------
log "Saving watchdog configuration"
sudo mkdir -p "$CONFIG_DIR"
sudo chmod 700 "$CONFIG_DIR"
sudo tee "$CONFIG_FILE" >/dev/null <<EOF
WIFI_DEV=$(printf '%q' "$WIFI_DEV")
PRIMARY_CONN=$(printf '%q' "$PRIMARY_CONN")
AP_CONN_NAME=$(printf '%q' "$AP_CONN_NAME")
WIFI_TIMEOUT=$(printf '%q' "$WIFI_TIMEOUT")
CHECK_INTERVAL=$(printf '%q' "$CHECK_INTERVAL")
EOF
sudo chmod 600 "$CONFIG_FILE"

# ---------------------------------------------------------------------------
log "Installing the watchdog"
# The watchdog is deliberately NOT `set -e`: it runs forever in a loop, and
# a single failed nmcli call (a transient DBus hiccup, a network blip)
# should be logged and retried on the next tick, not kill the daemon.
sudo tee "$WATCHDOG" >/dev/null <<'WDEOF'
#!/bin/bash
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
WDEOF
sudo chmod 755 "$WATCHDOG"

# ---------------------------------------------------------------------------
log "Installing the systemd service"
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Wi-Fi Emergency AP Fallback
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=$WATCHDOG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wifi-ap-fallback
# Make sure we don't start already in AP mode if one was left up from a
# previous run/config.
sudo nmcli connection down "$AP_CONN_NAME" >/dev/null 2>&1 || true
sudo systemctl restart wifi-ap-fallback

echo
echo "Emergency Wi-Fi AP fallback installed:"
echo "  Primary Wi-Fi : $PRIMARY_CONN"
echo "  Emergency AP  : $AP_SSID"
echo "  AP IP         : ${AP_IP%/*}"
echo "  Service       : wifi-ap-fallback.service"
echo
echo "Check status:   sudo systemctl status wifi-ap-fallback"
echo "Live logs:      sudo journalctl -u wifi-ap-fallback -f"
echo "Config:         $CONFIG_FILE"
