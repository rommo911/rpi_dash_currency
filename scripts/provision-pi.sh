#!/usr/bin/env bash
# Harden a fresh Raspberry Pi OS install: update system, create a new admin
# user (optionally locking the default one), configure a firewall, harden
# SSH, and protect it with fail2ban.
#
# Run this ONCE, right after first boot, logged in as the default user
# (over SSH or on the console). SSH password auth is intentionally left
# enabled (fail2ban covers brute-force protection) — switch to key-only
# auth later once you've copied your key over, if you want to lock it down
# further.
#
# Usage:
#   chmod +x provision-pi.sh
#   ./provision-pi.sh

set -euo pipefail

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal sudo user (e.g. 'pi'), not as root — it calls sudo where needed."
  exit 1
fi

log "1/8 Updating system packages (this can take a while on first boot)"
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

log "2/8 Installing security tooling"
sudo apt install -y ufw fail2ban unattended-upgrades curl

# ---------------------------------------------------------------------------
log "3/8 Admin user"
read -rp "New username to create (leave blank to just change the current user's password): " NEW_USER
if [[ -n "$NEW_USER" ]]; then
  if id "$NEW_USER" &>/dev/null; then
    warn "User '$NEW_USER' already exists — skipping creation."
  else
    sudo adduser --gecos "" "$NEW_USER"
    sudo usermod -aG "$(id -Gn "$USER" | tr ' ' ',')" "$NEW_USER" 2>/dev/null || true
    sudo usermod -aG sudo "$NEW_USER"
  fi
  CURRENT_USER="$(whoami)"
  if [[ "$CURRENT_USER" != "$NEW_USER" ]]; then
    read -rp "Lock login for current user '$CURRENT_USER'? Only do this once you've confirmed '$NEW_USER' can log in and sudo. [y/N]: " LOCK_OLD
    if [[ "${LOCK_OLD,,}" == "y" ]]; then
      sudo passwd -l "$CURRENT_USER"
      warn "'$CURRENT_USER' password login is now locked. Log in as '$NEW_USER' from now on."
    fi
  fi
else
  log "Changing password for current user ($(whoami))"
  passwd
fi

# ---------------------------------------------------------------------------
log "4/8 Hostname"
read -rp "New hostname (leave blank to keep '$(hostname)'): " NEW_HOSTNAME
if [[ -n "$NEW_HOSTNAME" ]]; then
  if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_hostname "$NEW_HOSTNAME"
  else
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  fi
  log "Hostname set to $NEW_HOSTNAME (takes effect after reboot)"
fi

# ---------------------------------------------------------------------------
log "5/8 Firewall (ufw)"
read -rp "Dashboard port to allow through the firewall [5000]: " APP_PORT
APP_PORT="${APP_PORT:-5000}"
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
log "6/8 Hardening SSH (root login disabled; password auth kept ON as requested)"
SSHD_CONFIG=/etc/ssh/sshd_config
sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
sudo sed -i \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
  -e 's/^#\?MaxAuthTries.*/MaxAuthTries 4/' \
  -e 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' \
  "$SSHD_CONFIG"
sudo systemctl restart ssh

# ---------------------------------------------------------------------------
log "7/8 fail2ban for SSH"
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
log "8/8 Automatic security updates"
echo 'Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Raspbian,codename=${distro_codename},label=Raspbian";
        "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};' | sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-security > /dev/null
echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
sudo systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
log "Summary"
sudo ufw status verbose
echo
sudo fail2ban-client status sshd || true
echo
warn "Reboot recommended before continuing: sudo reboot"
warn "After reboot, log in as your (new) user and run scripts/deploy-dashboard.sh"
