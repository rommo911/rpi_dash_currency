#!/usr/bin/env bash
# One script for a fresh Raspberry Pi OS install, start to finish: get
# online, enable SSH, create the admin user, set the hostname, harden the
# system (firewall, SSH, fail2ban, unattended-upgrades) — then
# automatically install git, get this repo, and hand off to
# deploy-dashboard.sh (venv + systemd service + kiosk autostart). By the
# time it exits, the dashboard is installed and running.
#
# Network comes FIRST, before anything else, on purpose: apt and git both
# need internet access, and a fresh Pi typically has neither Ethernet nor
# Wi-Fi configured yet. Nothing that fetches packages runs until a working
# connection is confirmed.
#
# Works both ways:
#   - Copied alone onto a fresh SD card (no repo present yet) — it clones
#     this repo itself before handing off to deploy-dashboard.sh.
#   - Run from inside an already-cloned copy of this repo (e.g. you cloned
#     it on your PC and copied the whole thing over, or git-cloned it
#     directly on the Pi) — it detects deploy-dashboard.sh sitting next to
#     it and uses that checkout directly instead of cloning a second copy.
#
# Usage (right after first boot, logged in as the default user):
#   scp scripts/provision-pi.sh pi@<pi-ip>:~
#   ssh pi@<pi-ip>
#   chmod +x provision-pi.sh
#   ./provision-pi.sh
#
# Optional env vars (all have sane defaults):
#   REPO_URL     Git URL to clone (default: this project's GitHub repo) —
#                only used when not already running from inside a clone
#   INSTALL_DIR  Where to clone/install (default: ~/currency-dashboard) —
#                only used when not already running from inside a clone
#   APP_PORT     Dashboard port (default: 5000)
#   HEADLESS     Set to "true" to skip Chromium/kiosk setup entirely
#                (default: "false" — kiosk is always on unless you opt out)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/rommo911/rpi_dash_currency.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/currency-dashboard}"
APP_PORT="${APP_PORT:-5000}"
HEADLESS="${HEADLESS:-false}"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal sudo user (e.g. 'pi'), not as root — it calls sudo where needed."
  exit 1
fi

# Detect whether we're already sitting inside a clone of this repo (has a
# sibling deploy-dashboard.sh) so step 12 can skip re-cloning.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNING_FROM_CLONE=false
if [[ -f "$SCRIPT_DIR/deploy-dashboard.sh" ]]; then
  RUNNING_FROM_CLONE=true
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ---------------------------------------------------------------------------
check_internet() {
  ping -c 1 -W 3 8.8.8.8 &>/dev/null && return 0
  curl -fsS --max-time 5 https://deb.debian.org >/dev/null 2>&1 && return 0
  return 1
}

connect_wifi() {
  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli (NetworkManager) not found on this system — can't configure Wi-Fi from here."
    warn "Connect Ethernet instead, or configure Wi-Fi with 'sudo raspi-config'."
    return 1
  fi
  WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')" || true
  if [[ -z "$WIFI_DEV" ]]; then
    warn "No Wi-Fi device detected."
    return 1
  fi

  log "Scanning for networks on $WIFI_DEV..."
  sudo nmcli device wifi rescan ifname "$WIFI_DEV" >/dev/null 2>&1 || true
  sleep 2
  nmcli --fields SSID,SIGNAL,SECURITY device wifi list ifname "$WIFI_DEV" 2>/dev/null | awk '!seen[$0]++' || true

  read -rp "SSID to connect to (leave blank to skip): " WIFI_SSID
  [[ -z "$WIFI_SSID" ]] && return 1

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

log "1/14 Network connectivity — apt and git both need this before anything else can run"
WIFI_IP=""
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

if ! check_internet; then
  echo
  echo "No internet connection available — apt and git both need one to continue."
  echo "Connect Ethernet, or re-run this script to try Wi-Fi again (or configure it with 'sudo raspi-config'), then try again."
  exit 1
fi

# ---------------------------------------------------------------------------
log "2/14 Enabling SSH"
sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || \
  warn "Could not find an ssh/sshd service to enable — SSH may already be active, or install openssh-server."

# ---------------------------------------------------------------------------
log "3/14 Removing unneeded pre-installed packages"
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
read -rp "Remove unneeded pre-installed apps (Raspberry Pi Connect, LibreOffice, Wolfram, Scratch, Minecraft, Sonic Pi, Thonny, Node-RED, Claws Mail — whichever are actually present) to save space/resources on this dedicated kiosk? [Y/n]: " DO_CLEANUP
if [[ "${DO_CLEANUP,,}" != "n" ]]; then
  TO_REMOVE=()
  for pkg in "${BLOAT_PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null && TO_REMOVE+=("$pkg")
  done
  dpkg -l 'libreoffice*' 2>/dev/null | grep -q '^ii' && TO_REMOVE+=("libreoffice*")
  if [[ "${#TO_REMOVE[@]}" -gt 0 ]]; then
    log "Removing: ${TO_REMOVE[*]}"
    sudo apt purge -y "${TO_REMOVE[@]}"
    sudo apt autoremove -y
  else
    log "None of the known bloat packages are installed — nothing to remove."
  fi
else
  log "Skipping cleanup."
fi

log "4/14 Updating system packages (this can take a while on first boot)"
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

log "5/14 Installing security tooling"
sudo apt install -y ufw fail2ban unattended-upgrades curl git

# ---------------------------------------------------------------------------
log "6/14 Admin user (optional)"
read -rp "Create a new sudo user? [y/N]: " DO_NEW_USER
if [[ "${DO_NEW_USER,,}" == "y" ]]; then
  read -rp "New username: " NEW_USER
  if [[ -z "$NEW_USER" ]]; then
    warn "No username entered — skipping user creation."
  elif id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists — skipping creation."
  else
    sudo adduser --gecos "" "$NEW_USER"
    sudo usermod -aG "$(id -Gn "$USER" | tr ' ' ',')" "$NEW_USER" 2>/dev/null || true
    sudo usermod -aG sudo "$NEW_USER"
  fi
  CURRENT_USER="$(whoami)"
  if [[ -n "$NEW_USER" && "$CURRENT_USER" != "$NEW_USER" ]]; then
    read -rp "Lock login for current user '$CURRENT_USER'? Only do this once you've confirmed '$NEW_USER' can log in and sudo. [y/N]: " LOCK_OLD
    if [[ "${LOCK_OLD,,}" == "y" ]]; then
      sudo passwd -l "$CURRENT_USER"
      warn "'$CURRENT_USER' password login is now locked. Log in as '$NEW_USER' from now on."
    fi
  fi
else
  read -rp "Change the password for the current user ($(whoami))? [y/N]: " DO_PASSWD
  if [[ "${DO_PASSWD,,}" == "y" ]]; then
    passwd
  else
    log "Skipping user/password changes."
  fi
fi

# ---------------------------------------------------------------------------
log "7/14 Hostname"
read -rp "New hostname (leave blank to keep '$(hostname)'): " NEW_HOSTNAME
if [[ -n "$NEW_HOSTNAME" ]]; then
  if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_hostname "$NEW_HOSTNAME"
  else
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  fi
  log "Hostname set to $NEW_HOSTNAME (takes effect after reboot)"
fi
FINAL_HOSTNAME="${NEW_HOSTNAME:-$(hostname)}"

# ---------------------------------------------------------------------------
log "8/14 Firewall (ufw)"
read -rp "Dashboard port to allow through the firewall [${APP_PORT}]: " APP_PORT_INPUT
APP_PORT="${APP_PORT_INPUT:-$APP_PORT}"
read -rp "Restrict dashboard/SSH access to a LAN subnet (e.g. 192.168.1.0/24)? Leave blank to allow from anywhere: " LAN_SUBNET

sudo ufw default deny incoming
sudo ufw default allow outgoing

if [[ -n "$LAN_SUBNET" ]]; then
  sudo ufw allow from "$LAN_SUBNET" to any port 22 proto tcp
  sudo ufw allow from "$LAN_SUBNET" to any port "$APP_PORT" proto tcp
else
  sudo ufw allow OpenSSH
  sudo ufw allow "$APP_PORT"/tcp
fi
sudo ufw --force enable

# ---------------------------------------------------------------------------
log "9/14 Hardening SSH (root login disabled; password auth kept ON as requested)"
SSHD_CONFIG=/etc/ssh/sshd_config
sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
sudo sed -i \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
  -e 's/^#\?MaxAuthTries.*/MaxAuthTries 4/' \
  -e 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' \
  "$SSHD_CONFIG"
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd

# ---------------------------------------------------------------------------
log "10/14 fail2ban for SSH"
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
EOF
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

# ---------------------------------------------------------------------------
log "11/14 Automatic security updates"
echo 'Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Raspbian,codename=${distro_codename},label=Raspbian";
        "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};' | sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-security > /dev/null
echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
sudo systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
log "12/14 System-wide log limits (errors only, 1 week max)"
# journald's own MaxLevelStore is what "errors only" actually means at the
# system level: messages below the given level still reach live watchers
# (journalctl -f, fail2ban's follow-mode) but are never written to disk —
# so this cuts disk usage from routine info/debug noise without starving
# anything that depends on real-time log-following. The dashboard's own
# security-relevant log line is deliberately emitted at ERROR (see
# app.py/CLAUDE.md) specifically so it still gets *stored* under this
# policy and the admin-login fail2ban jail keeps working.
# A drop-in under journald.conf.d/, not a raw edit of journald.conf, so
# this stays isolated from distro defaults and is safe to re-run.
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/10-currency-dashboard-limits.conf > /dev/null <<'EOF'
[Journal]
Storage=persistent
Compress=yes
MaxLevelStore=err
MaxRetentionSec=1week
SystemMaxUse=200M
EOF
sudo systemctl restart systemd-journald

# ---------------------------------------------------------------------------
log "13/14 Provisioning summary"
sudo ufw status verbose
echo
sudo fail2ban-client status sshd || true
echo
if [[ -n "$WIFI_IP" ]]; then
  echo "Wi-Fi IP address: $WIFI_IP"
fi

# ---------------------------------------------------------------------------
log "14/14 Installing the dashboard (git clone + deploy-dashboard.sh)"
# Untrack data.json/config.py first if this checkout predates them being
# gitignored — a plain `git pull`/reset would otherwise refuse or (worse,
# for reset --hard) silently delete a live-modified copy of either file.
# See scripts/auto-update.sh for the full explanation; deploy-dashboard.sh
# repeats this same update below anyway, so failures here are non-fatal.
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
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [[ ! -f "$INSTALL_DIR/scripts/deploy-dashboard.sh" ]]; then
  warn "scripts/deploy-dashboard.sh not found in $INSTALL_DIR — cannot continue automatically."
  warn "Check REPO_URL ($REPO_URL) and run it manually once it's available."
  exit 1
fi

echo "Handing off to deploy-dashboard.sh ..."
exec env REPO_URL="$REPO_URL" INSTALL_DIR="$INSTALL_DIR" APP_PORT="$APP_PORT" HEADLESS="$HEADLESS" LAN_SUBNET="${LAN_SUBNET:-}" \
  bash "$INSTALL_DIR/scripts/deploy-dashboard.sh"
