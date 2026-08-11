#!/usr/bin/env bash
# Harden a fresh Raspberry Pi OS install: update system, create a new admin
# user (optionally locking the default one), set the hostname, optionally
# scan for and connect to Wi-Fi (DHCP or static IP), configure a firewall,
# harden SSH, and protect it with fail2ban.
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

log "1/9 Updating system packages (this can take a while on first boot)"
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

log "2/9 Installing security tooling"
sudo apt install -y ufw fail2ban unattended-upgrades curl

# ---------------------------------------------------------------------------
log "3/9 Admin user"
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
log "4/9 Hostname"
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
log "5/9 Wi-Fi"
WIFI_IP=""
read -rp "Scan for and (re)configure Wi-Fi now? [y/N]: " SETUP_WIFI
if [[ "${SETUP_WIFI,,}" == "y" ]]; then
  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli (NetworkManager) not found on this system — skipping. Configure Wi-Fi manually with 'sudo raspi-config' instead."
  else
    WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')" || true
    if [[ -z "$WIFI_DEV" ]]; then
      warn "No Wi-Fi device detected — skipping."
    else
      log "Scanning for networks on $WIFI_DEV..."
      sudo nmcli device wifi rescan ifname "$WIFI_DEV" >/dev/null 2>&1 || true
      sleep 2
      nmcli --fields SSID,SIGNAL,SECURITY device wifi list ifname "$WIFI_DEV" 2>/dev/null | awk '!seen[$0]++' || true

      read -rp "SSID to connect to (leave blank to skip Wi-Fi setup): " WIFI_SSID
      if [[ -n "$WIFI_SSID" ]]; then
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
          log "Verifying connection..."
          sleep 3
          STATE="$(nmcli -t -f GENERAL.STATE device show "$WIFI_DEV" 2>/dev/null | cut -d: -f2)" || true
          if [[ "$STATE" == 100* ]]; then
            WIFI_IP="$(nmcli -g IP4.ADDRESS device show "$WIFI_DEV" 2>/dev/null | head -n1 | cut -d/ -f1)" || true
            echo "Connected — IP address: ${WIFI_IP:-unknown}"
          else
            warn "Device state is '${STATE:-unknown}' — Wi-Fi may not be connected. Check later with: nmcli device status"
          fi
          if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
            echo "Internet connectivity verified."
          else
            warn "Could not reach the internet over Wi-Fi — double-check credentials/static IP settings, or that the router is online."
          fi
        else
          warn "Could not connect to '$WIFI_SSID' — check the SSID/password. Retry later with 'sudo raspi-config' or 'nmcli'."
        fi
      else
        log "No SSID entered — skipping Wi-Fi setup."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "6/9 Firewall (ufw)"
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
log "7/9 Hardening SSH (root login disabled; password auth kept ON as requested)"
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
log "8/9 fail2ban for SSH"
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
log "9/9 Automatic security updates"
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
if [[ -n "$WIFI_IP" ]]; then
  echo "Wi-Fi IP address: $WIFI_IP"
fi
echo "Once the dashboard is deployed (scripts/deploy-dashboard.sh), reach it from any device on the LAN at:"
echo "  http://${FINAL_HOSTNAME}.local:${APP_PORT}/"
echo "(mDNS/.local resolution needs a reboot to pick up a new hostname, and needs Bonjour/mDNS support on the client — nearly"
echo " always on by default on macOS/Linux/iOS/Android; Windows may need Bonjour or a recent build. The IP address above always works.)"
echo
warn "Reboot recommended before continuing: sudo reboot"
warn "After reboot, log in as your (new) user and run scripts/deploy-dashboard.sh"
