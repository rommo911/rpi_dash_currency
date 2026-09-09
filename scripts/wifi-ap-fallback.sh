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
# (harden-system.sh's optional step, provision-pi.sh's/harden-system.sh's
# --auto_default Wi-Fi setup, or 'nmcli device wifi connect'/raspi-config
# by hand) — this script only layers the AP fallback on top of it, it
# doesn't configure normal Wi-Fi itself. Safe to re-run any time to
# change the AP SSID/password or refresh the watchdog service.
#
# The watchdog daemon itself and its systemd unit are real files under
# scripts/files/network/ and scripts/files/systemd/ — this script only
# renders and installs them (see scripts/lib.sh), it doesn't author their
# content inline.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

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
    warn "No saved Wi-Fi connections found. Connect to Wi-Fi first (harden-system.sh's network step, 'nmcli device wifi connect ...', or raspi-config), then re-run this script."
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
# This one config file is genuinely install-time-computed data (which
# device/connection this Pi chose), not static template content, so it's
# the one exception to going through render_template — matches
# generate-cert.sh's cert.meta for the same reason.

# ---------------------------------------------------------------------------
log "Installing the watchdog"
render_template "$FILES_DIR/network/wifi-ap-fallback-watchdog.sh" "$WATCHDOG"
sudo chmod 755 "$WATCHDOG"

# ---------------------------------------------------------------------------
log "Installing the systemd service"
render_template "$FILES_DIR/systemd/wifi-ap-fallback.service" "$SERVICE_FILE" "WATCHDOG_PATH=$WATCHDOG"

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
