#!/usr/bin/env bash
# Stage 2 of 3: everything provision-pi.sh used to do besides networking —
# bloat removal, system update, user account, hostname, timezone/NTP,
# firewall, SSH hardening, fail2ban (SSH jail), unattended-upgrades,
# journald log limits, and the optional Wi-Fi emergency-AP fallback. Runs
# once, right after provision-pi.sh clones the repo and hands off here.
#
# Every installed config file below is a real file under scripts/files/,
# rendered via lib.sh's install_file/ensure_block_in_file — nothing
# here authors config content inline. See scripts/lib.sh for why.
#
# Usage:
#   ./harden-system.sh                 # interactive (normally invoked by
#                                       # provision-pi.sh, not run alone)
#   AUTO_DEFAULT=true ./harden-system.sh   # non-interactive defaults
#
# Ends by handing off to deploy-dashboard.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Force a static install location under the kiosk user's home for predictable paths
INSTALL_DIR="${INSTALL_DIR:-/home/kiosk/currency-dashboard}"
FILES_DIR="$SCRIPT_DIR/files"
APP_PORT="${APP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HEADLESS="${HEADLESS:-false}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal sudo user, not as root — it calls sudo where needed."
  exit 1
fi

log_info "1/11 Removing unneeded pre-installed packages"
# Only relevant on Raspberry Pi OS "Desktop"/"Full" images, which bundle a
# bunch of apps a dedicated kiosk display never uses. Each is checked with
# dpkg -s first, so this is a no-op on Lite (none of these are installed
# there) and never errors on a package name that isn't present.
BLOAT_PACKAGES=(
  rpi-connect rpi-connect-lite
  wolfram-engine wolframscript
  scratch scratch2 scratch3
  minecraft-pi
  sonic-pi
  thonny
  nodered
  smartsim
  claws-mail
)
ask "Remove unneeded pre-installed apps (Raspberry Pi Connect, LibreOffice, Wolfram, Scratch, Minecraft, Sonic Pi, Thonny, Node-RED, Claws Mail — whichever are actually present) to save space/resources on this dedicated kiosk? [Y/n]: " "Y" DO_CLEANUP
if [[ "${DO_CLEANUP,,}" != "n" ]]; then
  TO_REMOVE=()
  for pkg in "${BLOAT_PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null && TO_REMOVE+=("$pkg")
  done
  dpkg -l 'libreoffice*' 2>/dev/null | grep -q '^ii' && TO_REMOVE+=("libreoffice*")
  if [[ "${#TO_REMOVE[@]}" -gt 0 ]]; then
    log_info "Removing: ${TO_REMOVE[*]}"
    sudo apt purge -y "${TO_REMOVE[@]}"
    sudo apt autoremove -y
  else
    log_info "None of the known bloat packages are installed — nothing to remove."
  fi
else
  log_info "Skipping cleanup."
fi

log_info "2/11 Updating system packages (this can take a while on first boot)"
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

log_info "3/11 Installing security tooling"
sudo apt install -y ufw fail2ban unattended-upgrades curl git

# ---------------------------------------------------------------------------
log_info "4/11 Admin user: ensure kiosk user exists"
# Create a kiosk user unconditionally (idempotent). This keeps paths static
if ! id kiosk >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" kiosk
  sudo usermod -aG sudo kiosk || true
  log_info "Created user 'kiosk' and added to sudo group"
else
  log_info "User 'kiosk' already exists"
fi

# ---------------------------------------------------------------------------
log_info "5/11 Hostname"
if is_auto; then
  NEW_HOSTNAME="prices-dashboard"
else
  read -rp "New hostname (leave blank to keep '$(hostname)'): " NEW_HOSTNAME
fi
if [[ -n "$NEW_HOSTNAME" ]]; then
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_hostname "$NEW_HOSTNAME"
  else
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  fi
  log_info "Hostname set to $NEW_HOSTNAME (takes effect after reboot)"
fi

# ---------------------------------------------------------------------------
log_info "6/11 Timezone and NTP"
sudo timedatectl set-timezone Asia/Damascus
# set-ntp true both syncs now (via systemd-timesyncd) and persists as an
# enabled system setting — timesyncd starts automatically on every future
# boot too, this isn't a one-shot sync.
sudo timedatectl set-ntp true
timedatectl status | grep -E 'Time zone|NTP service|System clock synchronized' || true

# ---------------------------------------------------------------------------
log_info "7/11 Firewall (ufw)"
ask "Dashboard port to allow through the firewall [${APP_PORT}]: " "$APP_PORT" APP_PORT
ask "Admin HTTPS port to allow through the firewall [${HTTPS_PORT}]: " "$HTTPS_PORT" HTTPS_PORT
ask "Restrict dashboard/SSH access to a LAN subnet (e.g. 192.168.1.0/24)? Leave blank to allow from anywhere: " "" LAN_SUBNET

sudo ufw default deny incoming
sudo ufw default allow outgoing

if [[ -n "$LAN_SUBNET" ]]; then
  sudo ufw allow from "$LAN_SUBNET" to any port 22 proto tcp
  sudo ufw allow from "$LAN_SUBNET" to any port "$APP_PORT" proto tcp
  sudo ufw allow from "$LAN_SUBNET" to any port "$HTTPS_PORT" proto tcp
else
  sudo ufw allow OpenSSH
  sudo ufw allow "$APP_PORT"/tcp
  sudo ufw allow "$HTTPS_PORT"/tcp
fi
sudo ufw --force enable

# ---------------------------------------------------------------------------
log_info "8/11 Hardening SSH (root login disabled; password auth kept ON as requested)"
# A drop-in under sshd_config.d/, not a sed edit of the main sshd_config —
# Debian's default sshd_config already Includes that directory near the
# top, so these directives win the same way in-place edits used to,
# without ever touching a line we don't own.
install_file "$FILES_DIR/ssh/currency-dashboard-hardening.conf" \
  /etc/ssh/sshd_config.d/currency-dashboard-hardening.conf
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd

# ---------------------------------------------------------------------------
log_info "9/11 fail2ban for SSH"
install_file "$FILES_DIR/fail2ban/sshd-jail.local" /etc/fail2ban/jail.local
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

# ---------------------------------------------------------------------------
log_info "10/11 Automatic security updates + system-wide log limits (errors only, 1 week max)"
install_file "$FILES_DIR/apt/51unattended-upgrades-security" /etc/apt/apt.conf.d/51unattended-upgrades-security
install_file "$FILES_DIR/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
sudo systemctl enable --now unattended-upgrades

# journald's own MaxLevelStore is what "errors only" actually means at the
# system level: messages below the given level still reach live watchers
# (journalctl -f, fail2ban's follow-mode) but are never written to disk —
# so this cuts disk usage from routine info/debug noise without starving
# anything that depends on real-time log-following. The dashboard's own
# security-relevant log line is deliberately emitted at ERROR (see
# app.py) specifically so it still gets *stored* under this
# policy and the admin-login fail2ban jail keeps working.
install_file "$FILES_DIR/journald/10-currency-dashboard-limits.conf" \
  /etc/systemd/journald.conf.d/10-currency-dashboard-limits.conf
sudo systemctl restart systemd-journald

# ---------------------------------------------------------------------------
log_info "11/11 Optional: emergency Wi-Fi AP fallback"
if is_auto; then
  DO_AP_FALLBACK="y"
else
  read -rp "If this Pi ever loses its Wi-Fi connection, have it broadcast its own emergency Wi-Fi network so you can still reach it? [y/N]: " DO_AP_FALLBACK
fi
if [[ "${DO_AP_FALLBACK,,}" == "y" ]]; then
  if [[ -f "$INSTALL_DIR/scripts/wifi-ap-fallback.sh" ]]; then
    if is_auto; then
      WIFI_CONNECTION=dashboard AP_SSID=dashboardAP AP_PASSWORD=123456789 \
        bash "$INSTALL_DIR/scripts/wifi-ap-fallback.sh" || \
        warn "AP fallback setup failed — you can re-run scripts/wifi-ap-fallback.sh manually later."
    else
      WIFI_CONNECTION="${WIFI_SSID:-}" bash "$INSTALL_DIR/scripts/wifi-ap-fallback.sh" || \
        warn "AP fallback setup failed — you can re-run scripts/wifi-ap-fallback.sh manually later."
    fi
  else
    warn "scripts/wifi-ap-fallback.sh not found in $INSTALL_DIR — skipping."
  fi
fi

# ---------------------------------------------------------------------------
log_info "System summary"
sudo ufw status verbose
echo
sudo fail2ban-client status sshd || true

echo "Handing off to deploy-dashboard.sh ..."
exec env AUTO_DEFAULT="${AUTO_DEFAULT:-false}" INSTALL_DIR="$INSTALL_DIR" APP_PORT="$APP_PORT" \
  HTTPS_PORT="$HTTPS_PORT" LAN_SUBNET="${LAN_SUBNET:-}" HEADLESS="$HEADLESS" \
  bash "$INSTALL_DIR/scripts/deploy-dashboard.sh"
