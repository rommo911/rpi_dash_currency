#!/usr/bin/env bash
# Stage 1 of 3: get this Pi online, then get the repo onto it. Nothing
# else — user/hostname/firewall/hardening/kiosk setup all live in
# harden-system.sh and deploy-dashboard.sh, which this script hands off
# to once the repo is present. Kept minimal on purpose: this is the one
# file you copy onto a fresh SD card before anything else exists there,
# so it can't depend on any sibling file until it's cloned one.
#
# Works both ways:
#   - Copied alone onto a fresh SD card (no repo present yet) — clones
#     this repo itself before handing off.
#   - Run from inside an already-cloned copy of this repo — detects
#     harden-system.sh sitting next to it and uses that checkout directly
#     instead of cloning a second copy.
#
# Usage (right after first boot, logged in as the default user):
#   scp scripts/provision-pi.sh pi@<pi-ip>:~
#   ssh pi@<pi-ip>
#   chmod +x provision-pi.sh
#   ./provision-pi.sh                 # interactive
#   ./provision-pi.sh --auto_default  # fully non-interactive, see README
#
# Optional env vars (all have sane defaults):
#   REPO_URL     Git URL to clone (default: this project's GitHub repo) —
#                only used when not already running from inside a clone
#   INSTALL_DIR  Where to clone/install (default: ~/currency-dashboard) —
#                only used when not already running from inside a clone

set -euo pipefail

AUTO_DEFAULT=false
for arg in "$@"; do
  case "$arg" in
    --auto_default) AUTO_DEFAULT=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
export AUTO_DEFAULT

REPO_URL="${REPO_URL:-https://github.com/rommo911/rpi_dash_currency.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/currency-dashboard}"
HEADLESS="${HEADLESS:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib.sh"
else
  # Running copied-alone, before the repo (and lib.sh with it) exists on
  # disk yet — fall back to bare versions of just what this stage needs.
  log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
  warn() { echo -e "\033[1;33m$*\033[0m"; }
  is_auto() { [[ "$AUTO_DEFAULT" == "true" ]]; }
fi

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal sudo user (e.g. 'pi'), not as root — it calls sudo where needed."
  exit 1
fi

# Detect whether we're already sitting inside a clone of this repo (has a
# sibling harden-system.sh) so the final step can skip re-cloning.
RUNNING_FROM_CLONE=false
if [[ -f "$SCRIPT_DIR/harden-system.sh" ]]; then
  RUNNING_FROM_CLONE=true
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ---------------------------------------------------------------------------
check_internet() {
  ping -c 1 -W 3 8.8.8.8 &>/dev/null && return 0
  curl -fsS --max-time 5 https://deb.debian.org >/dev/null 2>&1 && return 0
  return 1
}

# netplan_wifi_dev — tool-free wireless-device detection for the no-nmcli
# path: every wifi netdev has a "wireless" subdir under /sys/class/net.
netplan_wifi_dev() {
  local d
  for d in /sys/class/net/*/wireless; do
    [[ -d "$d" ]] || continue
    basename "$(dirname "$d")"
    return
  done
}

# has_netplan — Armbian/Orange Pi and other Debian-family images without
# NetworkManager commonly use netplan + systemd-networkd + wpa_supplicant
# instead (confirmed live on an Orange Pi Zero 3 running Armbian trixie).
has_netplan() {
  command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]
}

# write_netplan_wifi <ssid> <password-or-empty> — writes ONE dedicated
# file this provisioning step fully owns (same file dashboard-net-apply.sh
# manages later at runtime, so the admin panel's Wi-Fi card picks up
# straight from here with no extra migration step). Claims the device
# away from any OTHER netplan file that already configures it first (an
# Armbian board-bring-up file, most likely) via a real YAML parse/rewrite
# — never sed/regex on YAML — backing up the foreign file once before
# ever touching it. Requires python3-yaml; installed on the spot if
# missing (this is provisioning time, apt is expected to work here).
write_netplan_wifi() {
  local ssid="$1" password="$2" wifi_dev
  wifi_dev="$(netplan_wifi_dev)"
  if [[ -z "$wifi_dev" ]]; then
    warn "No Wi-Fi device detected."
    return 1
  fi
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    sudo apt-get install -y python3-yaml >/dev/null 2>&1 || true
  fi
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    warn "python3-yaml unavailable — can't safely write netplan config."
    return 1
  fi

  local dest="/etc/netplan/90-dashboard-wifi.yaml"
  sudo python3 - "$wifi_dev" "$dest" <<'PYEOF'
import glob, os, shutil, sys
import yaml

wifi_dev, our_file = sys.argv[1], sys.argv[2]
for path in glob.glob("/etc/netplan/*.yaml"):
    if os.path.realpath(path) == os.path.realpath(our_file):
        continue
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except Exception:
        continue
    net = doc.get("network") or {}
    wifis = net.get("wifis") or {}
    if wifi_dev not in wifis:
        continue
    backup = path + ".dashboard-orig.bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
    del wifis[wifi_dev]
    if wifis:
        net["wifis"] = wifis
    else:
        net.pop("wifis", None)
    doc["network"] = net
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF

  sudo python3 - "$wifi_dev" "$ssid" "$password" "$dest" <<'PYEOF'
import sys
import yaml

wifi_dev, ssid, password, dest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
doc = {
    "network": {
        "version": 2,
        "renderer": "networkd",
        "wifis": {
            wifi_dev: {
                "dhcp4": True,
                "access-points": {ssid: ({"password": password} if password else {})},
            }
        },
    }
}
with open(dest, "w", encoding="utf-8") as f:
    f.write("# Managed by dashboard-net-apply — do not edit by hand, it is\n")
    f.write("# regenerated from net_config.json on every change.\n")
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  sudo chmod 600 "$dest" 2>/dev/null || true
  sudo netplan apply 2>/dev/null || { warn "netplan apply failed."; return 1; }
}

connect_wifi_auto() {
  # Non-interactive path for --auto_default: create (or refresh) a saved
  # profile for SSID "dashboard" / password "123456789" and try to bring
  # it up. Saving the profile always succeeds even if that SSID isn't in
  # range yet — NetworkManager will connect to it the moment it is, and
  # harden-system.sh's AP-fallback step builds on this same saved profile
  # regardless of whether it's reachable right now.
  if ! command -v nmcli >/dev/null 2>&1; then
    if has_netplan; then
      log "nmcli not found but netplan is — configuring default Wi-Fi profile 'dashboard' via netplan (auto mode)"
      write_netplan_wifi "dashboard" "123456789" || \
        warn "Could not write netplan Wi-Fi config — relying on Ethernet."
      return 0
    fi
    warn "nmcli (NetworkManager) not found — can't configure Wi-Fi automatically. Connect Ethernet instead."
    if is_armbian; then
      warn "Armbian/Orange Pi images commonly use NetworkManager; if nmcli is missing on your image, configure networking via armbian-config or the OS's normal network tool."
    fi
    return 1
  fi
  sudo rfkill unblock wifi 2>/dev/null || true
  sudo nmcli radio wifi on 2>/dev/null || true

  local wifi_dev
  wifi_dev="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')" || true
  if [[ -z "$wifi_dev" ]]; then
    warn "No Wi-Fi device detected — relying on Ethernet."
    return 1
  fi

  log "Configuring default Wi-Fi profile 'dashboard' (auto mode)"
  sudo nmcli connection delete dashboard >/dev/null 2>&1 || true
  sudo nmcli connection add \
    type wifi ifname "$wifi_dev" con-name dashboard ssid dashboard autoconnect yes \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk 123456789
  sudo nmcli connection up dashboard >/dev/null 2>&1 || \
    warn "Could not connect to 'dashboard' right now — profile is saved, will connect automatically once that SSID is in range."
}

# connect_wifi_netplan — interactive no-nmcli path. Skips scanning
# (would need `iw`, an extra dependency for a rare fallback) and just
# prompts directly for SSID/password, same as the manual-SSID-entry
# option the nmcli path already offers when its own scan finds nothing.
connect_wifi_netplan() {
  local wifi_dev
  wifi_dev="$(netplan_wifi_dev)"
  if [[ -z "$wifi_dev" ]]; then
    warn "No Wi-Fi device detected."
    return 1
  fi
  read -rp "SSID to connect to (leave blank to skip): " WIFI_SSID
  [[ -z "$WIFI_SSID" ]] && return 1
  read -rsp "Password for '$WIFI_SSID' (leave blank for an open network): " WIFI_PASS
  echo

  write_netplan_wifi "$WIFI_SSID" "$WIFI_PASS" || { warn "Failed to apply netplan Wi-Fi config."; return 1; }

  sleep 5
  if ip -4 route show dev "$wifi_dev" 2>/dev/null | grep -q '^default'; then
    WIFI_IP="$(ip -4 -o addr show dev "$wifi_dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    echo "Connected — IP address: ${WIFI_IP:-unknown}"
  else
    warn "Device isn't showing a default route yet — Wi-Fi may still be negotiating, or the SSID/password may be wrong. Check later with: sudo netplan status"
  fi
}

connect_wifi() {
  if ! command -v nmcli >/dev/null 2>&1; then
    if has_netplan; then
      log "nmcli not found but netplan is — configuring Wi-Fi via netplan instead"
      connect_wifi_netplan
      return
    fi
    warn "nmcli (NetworkManager) not found on this system — can't configure Wi-Fi from here."
    if is_armbian; then
      warn "Armbian/Orange Pi typically uses NetworkManager or armbian-config for Wi-Fi; connect via Ethernet or configure the OS's native networking tool first."
    else
      warn "Connect Ethernet instead, or configure Wi-Fi with 'sudo raspi-config'."
    fi
    return 1
  fi

  # On a fresh SD card the radio can be soft-blocked (rfkill) or the
  # NetworkManager wifi radio can be off — either one makes a scan return
  # nothing with no error at all, which looks identical to "no networks
  # nearby." Confirmed in practice: a first run's scan came back empty,
  # and only running raspi-config's own Wi-Fi setup (which unblocks/turns
  # this on as a side effect) fixed it. Unconditionally unblock/enable
  # before every scan — harmless no-ops if already fine.
  sudo rfkill unblock wifi 2>/dev/null || true
  sudo nmcli radio wifi on 2>/dev/null || true
  sleep 1

  WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')" || true
  if [[ -z "$WIFI_DEV" ]]; then
    warn "No Wi-Fi device detected."
    return 1
  fi

  log "Scanning for networks on $WIFI_DEV..."
  sudo nmcli device wifi rescan ifname "$WIFI_DEV" >/dev/null 2>&1 || true
  sleep 2

  # Numbered list, deduplicated by SSID (multiple APs/bands for the same
  # network show up as separate scan results otherwise). --escape no keeps
  # the terse output plain (no backslash-escaping of ':' inside field
  # values) so it's simple to split on ':' — the trade-off is an SSID that
  # itself contains a literal ':' would parse wrong, rare enough for a
  # provisioning prompt not to matter.
  WIFI_SCAN_NAMES=()
  WIFI_SCAN_ROWS=()
  while IFS=: read -r ssid signal security; do
    [[ -z "$ssid" ]] && continue  # hidden/blank SSID entries aren't selectable by name
    WIFI_SCAN_NAMES+=("$ssid")
    WIFI_SCAN_ROWS+=("$ssid|$signal|${security:-open}")
  done < <(nmcli --escape no -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$WIFI_DEV" 2>/dev/null | awk -F: '!seen[$1]++')

  if [[ "${#WIFI_SCAN_NAMES[@]}" -gt 0 ]]; then
    echo "Nearby networks:"
    local i=1 row ssid signal security
    for row in "${WIFI_SCAN_ROWS[@]}"; do
      IFS='|' read -r ssid signal security <<<"$row"
      printf "  %2d) %-32s signal:%-4s %s\n" "$i" "$ssid" "$signal" "$security"
      ((i++))
    done
    read -rp "Enter a number from the list, or type an SSID directly (leave blank to skip): " WIFI_INPUT
  else
    warn "No networks found in the scan — you can still type a hidden network's SSID directly."
    warn "If that's not it either: the Wi-Fi country/region may not be set yet, which can block"
    if is_armbian; then
      warn "scanning on Armbian/Orange Pi. Use armbian-config -> Network or set the regulatory domain in the OS before retrying."
    else
      warn "scanning with no error. Try 'sudo raspi-config' -> Localisation Options -> WLAN Country,"
      warn "then re-run this script."
    fi
    read -rp "SSID to connect to (leave blank to skip): " WIFI_INPUT
  fi

  if [[ -z "$WIFI_INPUT" ]]; then
    return 1
  elif [[ "$WIFI_INPUT" =~ ^[0-9]+$ ]] && (( WIFI_INPUT >= 1 && WIFI_INPUT <= ${#WIFI_SCAN_NAMES[@]} )); then
    WIFI_SSID="${WIFI_SCAN_NAMES[$((WIFI_INPUT - 1))]}"
    echo "Selected: $WIFI_SSID"
  else
    WIFI_SSID="$WIFI_INPUT"
  fi

  read -rsp "Password for '$WIFI_SSID' (leave blank for an open network): " WIFI_PASS
  echo
  read -rp "IP configuration — dhcp or static? [dhcp]: " IP_MODE
  IP_MODE="${IP_MODE:-dhcp}"

  # Drop any stale profile with the same name so we start clean.
  sudo nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1 || true

  CONNECTED=1
  if [[ -n "$WIFI_PASS" ]]; then
    sudo nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_DEV" name "$WIFI_SSID" || CONNECTED=0
  else
    sudo nmcli device wifi connect "$WIFI_SSID" ifname "$WIFI_DEV" name "$WIFI_SSID" || CONNECTED=0
  fi

  if [[ "$CONNECTED" -eq 1 && "${IP_MODE,,}" == "static" ]]; then
    read -rp "Static IP with CIDR prefix (e.g. 192.168.1.50/24): " STATIC_IP
    read -rp "Gateway (e.g. 192.168.1.1): " STATIC_GW
    read -rp "DNS server(s), space-separated (e.g. 192.168.1.1 1.1.1.1): " STATIC_DNS
    if sudo nmcli connection modify "$WIFI_SSID" \
        ipv4.method manual \
        ipv4.addresses "$STATIC_IP" \
        ipv4.gateway "$STATIC_GW" \
        ipv4.dns "${STATIC_DNS// /,}" \
      && sudo nmcli connection up "$WIFI_SSID"; then
      :
    else
      warn "Failed to apply static IP settings — connection may still be using DHCP."
    fi
  fi

  if [[ "$CONNECTED" -eq 1 ]]; then
    sleep 3
    STATE="$(nmcli -t -f GENERAL.STATE device show "$WIFI_DEV" 2>/dev/null | cut -d: -f2)" || true
    if [[ "$STATE" == 100* ]]; then
      WIFI_IP="$(nmcli -g IP4.ADDRESS device show "$WIFI_DEV" 2>/dev/null | head -n1 | cut -d/ -f1)" || true
      echo "Connected — IP address: ${WIFI_IP:-unknown}"
    else
      warn "Device state is '${STATE:-unknown}' — Wi-Fi may not be connected. Check later with: nmcli device status"
    fi
  else
    warn "Could not connect to '$WIFI_SSID' — check the SSID/password."
  fi
}

log "1/2 Network connectivity — apt and git both need this before anything else can run"
WIFI_IP=""
if is_auto; then
  if check_internet; then
    log "Internet already reachable (Ethernet, or Wi-Fi already configured)."
  else
    connect_wifi_auto || true
  fi
else
  if check_internet; then
    log "Internet already reachable (Ethernet, or Wi-Fi already configured)."
    read -rp "Reconfigure Wi-Fi anyway? [y/N]: " RECONFIGURE_WIFI
  else
    warn "No internet connection detected yet — nothing can be installed until one is available."
    RECONFIGURE_WIFI="y"
  fi

  if [[ "${RECONFIGURE_WIFI,,}" == "y" ]]; then
    while true; do
      connect_wifi || true
      if check_internet; then
        echo "Internet connectivity verified."
        break
      fi
      warn "Still no internet connection."
      read -rp "Try Wi-Fi setup again? [Y/n]: " RETRY
      [[ "${RETRY,,}" == "n" ]] && break
    done
  fi
fi

if ! check_internet; then
  echo
  echo "No internet connection available — apt and git both need one to continue."
  if is_armbian; then
    echo "Connect Ethernet, or re-run this script to try Wi-Fi again (using the OS's network tool or nmcli), then try again."
  else
    echo "Connect Ethernet, or re-run this script to try Wi-Fi again (or configure it with 'sudo raspi-config'), then try again."
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
log "2/2 Getting the dashboard repo onto this Pi"
# Untrack data.json/config.py first if this checkout predates them being
# gitignored — a plain `git pull`/reset would otherwise refuse or (worse,
# for reset --hard) silently delete a live-modified copy of either file.
# See scripts/auto-update.sh for the full explanation; harden-system.sh's
# handoff to deploy-dashboard.sh repeats this same update anyway, so
# failures here are non-fatal.
if [[ "$RUNNING_FROM_CLONE" == true ]]; then
  log "Already running from a clone at $REPO_ROOT — using it directly"
  git -C "$REPO_ROOT" rm --cached -q data.json config.py 2>/dev/null || true
  git -C "$REPO_ROOT" pull || warn "git pull failed — continuing with the code already on disk"
  INSTALL_DIR="$REPO_ROOT"
elif [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Repo already present at $INSTALL_DIR — pulling latest"
  git -C "$INSTALL_DIR" rm --cached -q data.json config.py 2>/dev/null || true
  git -C "$INSTALL_DIR" pull || warn "git pull failed — continuing with the code already on disk"
else
  log "Cloning $REPO_URL into $INSTALL_DIR"
  sudo apt update && sudo apt install -y git
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [[ ! -f "$INSTALL_DIR/scripts/harden-system.sh" ]]; then
  warn "scripts/harden-system.sh not found in $INSTALL_DIR — cannot continue automatically."
  warn "Check REPO_URL ($REPO_URL) and run it manually once it's available."
  exit 1
fi

if [[ -n "$WIFI_IP" ]]; then
  echo "Wi-Fi IP address: $WIFI_IP"
fi

echo "Handing off to harden-system.sh ..."
exec env AUTO_DEFAULT="$AUTO_DEFAULT" INSTALL_DIR="$INSTALL_DIR" WIFI_SSID="${WIFI_SSID:-}" HEADLESS="$HEADLESS" \
  bash "$INSTALL_DIR/scripts/harden-system.sh"
