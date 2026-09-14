#!/usr/bin/env bash
# Stage 3/3, standalone-safe: clone/update + boot into kiosk. Re-run to
# redeploy. Usage: REPO_URL=... ./deploy-dashboard.sh (HEADLESS=true skips kiosk)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/rommo911/rpi_dash_currency.git}"
# Deploy into a fixed location under the kiosk user's home to keep paths
# static and predictable.
INSTALL_DIR="${INSTALL_DIR:-/home/kiosk/currency-dashboard}"
SERVICE_NAME="currency-dashboard"
APP_PORT="${APP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HEADLESS="${HEADLESS:-false}"
LAN_SUBNET="${LAN_SUBNET:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
if [[ -f "$SCRIPT_DIR/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib.sh"
else
  # Copied-alone, before lib.sh exists — bare log/warn/is_auto cover this
  # point; install_file etc. need the real lib.sh, re-sourced below.
  log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
  warn() { echo -e "\033[1;33m$*\033[0m"; }
  is_auto() { [[ "${AUTO_DEFAULT:-false}" == "true" ]]; }
fi

if [[ "$REPO_URL" == *"<your-username>"* ]]; then
  echo "Set REPO_URL to your GitHub repo before running, e.g.:"
  echo "  REPO_URL=https://github.com/you/rpi_dash_currency.git $0"
  exit 1
fi

is_headless() {
  [[ "$HEADLESS" == "true" ]]
}

if ! is_headless; then
  # Just a heads-up, never a decision — kiosk mode still proceeds regardless.
  model=""
  [[ -f /proc/device-tree/model ]] && model="$(tr -d '\0' < /proc/device-tree/model)"
  if [[ "$model" == *"Zero"* && "$model" != *"Zero 2"* ]]; then
    log_warn "This looks like a Pi Zero / Zero W — it's quite weak for a browser."
    log_warn "If it has no display attached, re-run with HEADLESS=true instead. Continuing with kiosk setup as requested."
  fi
fi

log_info "1/13 Installing system dependencies"
sudo apt update
sudo apt install -y git python3-venv python3-pip curl openssl avahi-daemon fonts-noto-core

CHROMIUM_BIN=""
if is_headless; then
  log_info "HEADLESS=true — skipping Chromium/kiosk setup"
else
  CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
  if [[ -z "$CHROMIUM_BIN" ]]; then
    log_info "Installing Chromium"
    sudo apt install -y chromium-browser 2>/dev/null || sudo apt install -y chromium
    CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium)"
  fi
fi

# Ensure kiosk user and home exist before cloning into /home/kiosk
if ! id kiosk >/dev/null 2>&1; then
  log_info "Creating kiosk user"
  sudo adduser --disabled-password --gecos "" kiosk
  sudo usermod -aG sudo kiosk || true
fi
sudo mkdir -p /home/kiosk
sudo chown "$USER":"$USER" /home/kiosk 2>/dev/null || true
log_info "2/13 Cloning/updating repository into $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  # Untrack data.json/config.py first so reset --hard can't delete local
  # copies; fetch+reset (not pull) matches auto-update.sh.
  git -C "$INSTALL_DIR" rm --cached -q data.json config.py 2>/dev/null || true
  CURRENT_BRANCH="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)"
  git -C "$INSTALL_DIR" fetch origin "$CURRENT_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$CURRENT_BRANCH"
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
# Re-point at the fresh checkout in case this ran copied-alone before
# ever cloning anything.
FILES_DIR="$INSTALL_DIR/scripts/files"
# shellcheck disable=SC1091
source "$INSTALL_DIR/scripts/lib.sh"

# Use kiosk as the runtime user for installed units and files
export RUN_USER="kiosk"
export HOME="/home/kiosk"
export USER="kiosk"
sudo mkdir -p "$INSTALL_DIR" || true
sudo chown -R "$USER":"$USER" "$INSTALL_DIR" 2>/dev/null || true

log_info "3/13 Setting up local config (data.json, .env, net_config.json, auto-update.conf)"
# Gitignored, copied from templates only if missing, so reset --hard
# (auto-update.sh) can never touch live data.
NEW_ENV=false
if [[ ! -f "$INSTALL_DIR/data.json" ]]; then
  cp "$INSTALL_DIR/data.default.json" "$INSTALL_DIR/data.json"
fi
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  NEW_ENV=true
fi
# Ensure a default LOG_LEVEL if not present (WARN by default)
if ! grep -q '^LOG_LEVEL=' "$INSTALL_DIR/.env" 2>/dev/null; then
  echo "LOG_LEVEL=WARN" | sudo tee -a "$INSTALL_DIR/.env" >/dev/null
  sudo chmod 600 "$INSTALL_DIR/.env"
fi

# Install system journald limits to reduce SD wear (warning level, 3 days)
log_info "Applying system journald limits (3 days, warning level)"
install_file "$FILES_DIR/journald/10-currency-dashboard-limits.conf" \
  /etc/systemd/journald.conf.d/10-currency-dashboard-limits.conf
sudo systemctl restart systemd-journald || warn "Failed to restart systemd-journald"
if [[ ! -f "$INSTALL_DIR/scripts/auto-update.conf" ]]; then
  cp "$INSTALL_DIR/scripts/auto-update.conf.example" "$INSTALL_DIR/scripts/auto-update.conf"
fi
# detect_active_wifi <ssid_var> <password_var> — carries a currently-
# connected network into net_config.json so first deploy doesn't overwrite it.
detect_active_wifi() {
  local -n _ssid_out="$1" _password_out="$2"
  _ssid_out=""
  _password_out=""

  if command -v nmcli >/dev/null 2>&1; then
    local dev state conn
    dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    [[ -z "$dev" ]] && return 0
    state="$(nmcli -t -f GENERAL.STATE device show "$dev" 2>/dev/null | cut -d: -f1)"
    [[ "$state" == "100" ]] || return 0
    conn="$(nmcli -t -f GENERAL.CONNECTION device show "$dev" 2>/dev/null | cut -d: -f2)"
    [[ -z "$conn" || "$conn" == "--" ]] && return 0
    _ssid_out="$(nmcli -g 802-11-wireless.ssid connection show "$conn" 2>/dev/null)"
    [[ -z "$_ssid_out" ]] && _ssid_out="$conn"
    _password_out="$(sudo nmcli -s -g 802-11-wireless-security.psk connection show "$conn" 2>/dev/null)"
    return 0
  fi

  if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
    local d dev=""
    for d in /sys/class/net/*/wireless; do
      [[ -d "$d" ]] || continue
      dev="$(basename "$(dirname "$d")")"
      break
    done
    [[ -z "$dev" ]] && return 0
    ip -4 route show dev "$dev" 2>/dev/null | grep -q '^default' || return 0

    if ! python3 -c "import yaml" >/dev/null 2>&1; then
      sudo apt-get install -y python3-yaml >/dev/null 2>&1 || true
    fi
    python3 -c "import yaml" >/dev/null 2>&1 || return 0

    local out
    out="$(sudo python3 - "$dev" <<'PYEOF'
import glob, sys
import yaml

wifi_dev = sys.argv[1]
for path in glob.glob("/etc/netplan/*.yaml"):
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except Exception:
        continue
    aps = (((doc.get("network") or {}).get("wifis") or {}).get(wifi_dev) or {}).get("access-points") or {}
    for ssid, opts in aps.items():
        print(ssid)
        print((opts or {}).get("password") or "")
        break
    else:
        continue
    break
PYEOF
)"
    _ssid_out="$(sed -n '1p' <<<"$out")"
    _password_out="$(sed -n '2p' <<<"$out")"
  fi
}

# Seeds a fresh board with known networks/AP fallback, zero manual steps.
# 600 perms: holds plaintext Wi-Fi/hotspot PSKs, like .env above.
if [[ ! -f "$INSTALL_DIR/net_config.json" ]]; then
  cp "$INSTALL_DIR/net_config.default.json" "$INSTALL_DIR/net_config.json"
  DETECTED_WIFI_SSID=""
  DETECTED_WIFI_PASSWORD=""
  detect_active_wifi DETECTED_WIFI_SSID DETECTED_WIFI_PASSWORD
  if [[ -n "$DETECTED_WIFI_SSID" ]]; then
    log_info "Already connected to Wi-Fi '$DETECTED_WIFI_SSID' — carrying it into net_config.json instead of the placeholder default"
    python3 - "$INSTALL_DIR/net_config.json" "$DETECTED_WIFI_SSID" "$DETECTED_WIFI_PASSWORD" <<'PYEOF'
import json, sys

path, ssid, password = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
wifi = [slot for slot in (cfg.get("wifi") or []) if slot.get("ssid") != ssid]
wifi.insert(0, {"ssid": ssid, "password": password})
cfg["wifi"] = wifi[:2]
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  fi
  chmod 600 "$INSTALL_DIR/net_config.json"
fi
# Flag file, admin-toggled. Defaults on only for a genuinely fresh
# install (NEW_ENV) — never re-enabled behind an admin's back later.
if [[ "$NEW_ENV" == true ]]; then
  touch "$INSTALL_DIR/auto-update.enabled" 2>/dev/null || true
fi
if [[ "$NEW_ENV" == true ]]; then
  # -t 0 guards non-interactive runs (automation/piped stdin) — this
  # script is documented safe to run unattended.
  SET_ADMIN_PW="n"
  if [[ -t 0 ]] && ! is_auto; then
    read -rp "Set a custom admin panel password now instead of the placeholder? [y/N]: " SET_ADMIN_PW || true
  fi
  if [[ "${SET_ADMIN_PW,,}" == "y" ]]; then
    while true; do
      read -rsp "New admin panel password: " ADMIN_PW1; echo
      read -rsp "Confirm: " ADMIN_PW2; echo
      if [[ -z "$ADMIN_PW1" ]]; then
        warn "Password can't be empty."
      elif [[ "$ADMIN_PW1" != "$ADMIN_PW2" ]]; then
        warn "Passwords didn't match — try again."
      else
        break
      fi
    done
    # Write the password into the project-local env file without exposing it
    # in the service unit or in a shell command argument.
    python3 - "$ADMIN_PW1" "$INSTALL_DIR/.env" <<'PYEOF'
import pathlib
import sys

pw, env_path = sys.argv[1], pathlib.Path(sys.argv[2])
lines = env_path.read_text(encoding="utf-8").splitlines()
out = [f"ADMIN_PASSWORD={pw}" if line.startswith("ADMIN_PASSWORD=") else line for line in lines]
env_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PYEOF
    chmod 600 "$INSTALL_DIR/.env"
    unset ADMIN_PW1 ADMIN_PW2
    log_info "Admin panel password set."
  else
    warn "No custom password set — put ADMIN_PASSWORD in $INSTALL_DIR/.env before relying on the admin panel."
  fi
fi

log_info "4/13 Creating virtualenv and installing Python deps"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# Ensure logs directory exists and is writable by kiosk
sudo mkdir -p "$INSTALL_DIR/logs"
sudo chown -R kiosk:kiosk "$INSTALL_DIR/logs" || true

log_info "5/13 Generating/renewing the self-signed HTTPS certificate"
INSTALL_DIR="$INSTALL_DIR" bash "$INSTALL_DIR/scripts/generate-cert.sh" || \
  warn "Certificate generation failed — the admin panel will fall back to HTTP only until this is fixed."

log_info "6/13 Installing systemd service"
install_file "$FILES_DIR/systemd/currency-dashboard.service" \
  "/etc/systemd/system/${SERVICE_NAME}.service"

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

log_info "7/13 Firewall: opening the HTTP and HTTPS ports"
# Rules queue regardless of ufw's state, no race. Path fallback: /usr/sbin
# is off kiosk's PATH, so `command -v` alone skipped this on a real deploy.
if command -v ufw >/dev/null 2>&1 || [[ -x /usr/sbin/ufw ]]; then
  if [[ -n "$LAN_SUBNET" ]]; then
    sudo ufw allow from "$LAN_SUBNET" to any port "$APP_PORT" proto tcp
    sudo ufw allow from "$LAN_SUBNET" to any port "$HTTPS_PORT" proto tcp
  else
    sudo ufw allow "$APP_PORT"/tcp
    sudo ufw allow "$HTTPS_PORT"/tcp
  fi
  # Opens the AP subnet too, else hotspot clients are locked out. DHCP/67
  # itself is interface-scoped, added by the daemon around each AP session.
  AP_SUBNET="192.168.50.0/24"
  sudo ufw allow from "$AP_SUBNET" to any port "$APP_PORT" proto tcp
  sudo ufw allow from "$AP_SUBNET" to any port "$HTTPS_PORT" proto tcp
  sudo ufw allow from "$AP_SUBNET" to any port 22 proto tcp
  sudo ufw status 2>/dev/null | grep -q "Status: active" || \
    log_warn "ufw is installed but not active yet — rule was queued and will apply once ufw is enabled."
else
  log_warn "ufw not installed — skipping (nothing to open)"
fi

log_info "8/13 Installing the auto-updater (git pull + cert renewal every 6h)"
SYSTEMCTL_BIN="$(command -v systemctl)"
SUDOERS_FILE="/etc/sudoers.d/${SERVICE_NAME}-updater"
# Rendered to a temp file, visudo-validated, then installed with 440
# perms — a plain `sudo tee` would leave it world-readable.
SUDOERS_TMP="$(mktemp)"
install_user_file "$FILES_DIR/sudoers/currency-dashboard-updater" "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
  warn "Generated sudoers rule failed validation — the auto-updater won't be able to restart the service, and the admin panel's 'check now' button won't be able to trigger a check, automatically."
  warn "Restart it by hand after an update: sudo systemctl restart ${SERVICE_NAME}"
fi
rm -f "$SUDOERS_TMP"

install_file "$FILES_DIR/systemd/currency-dashboard-updater.service" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.service"
install_file "$FILES_DIR/systemd/currency-dashboard-updater.timer" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.timer"

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}-updater.timer"

# Install logrotate config for app logs
install_file "$FILES_DIR/logrotate/currency-dashboard" "/etc/logrotate.d/currency-dashboard"

log_info "9/13 Securing the admin panel: fail2ban jail for repeated failed logins"
if command -v fail2ban-client >/dev/null 2>&1; then
  install_file "$FILES_DIR/fail2ban/currency-dashboard.filter" \
    "/etc/fail2ban/filter.d/${SERVICE_NAME}.conf"
  install_file "$FILES_DIR/fail2ban/currency-dashboard.jail" \
    "/etc/fail2ban/jail.d/${SERVICE_NAME}.local"
  sudo systemctl restart fail2ban
else
  log_warn "fail2ban not installed (run provision-pi.sh/harden-system.sh first for full hardening) — skipping the admin-login jail"
fi

log_info "10/13 Installing the network/reboot reconciler (Wi-Fi + hotspot fallback + reboot from the admin panel)"
# Flask never holds sudo — this root-run daemon (no User= in the unit)
# polls its desired-state files and does the real nmcli/systemctl work.
DAEMON_PATH="/usr/local/sbin/dashboard-net-apply"
install_file "$FILES_DIR/network/dashboard-net-apply.sh" "$DAEMON_PATH"
sudo chmod 755 "$DAEMON_PATH"
install_file "$FILES_DIR/systemd/dashboard-net-apply.service" \
  "/etc/systemd/system/dashboard-net-apply.service"
sudo systemctl daemon-reload
# Removes the old 90-dashboard-ap.network (always lost to netplan's
# 10-netplan-*.network) so an upgraded box matches a fresh one.
sudo rm -f /etc/systemd/network/90-dashboard-ap.network
sudo systemctl enable --now dashboard-net-apply
sudo systemctl restart dashboard-net-apply

# Non-NetworkManager images (Armbian) drive hostapd+iw directly for AP
# fallback. Disabled here — it only runs on-demand via a transient unit.
if ! command -v nmcli >/dev/null 2>&1; then
  log_warn "No NetworkManager detected — installing netplan-backend Wi-Fi fallback dependencies (hostapd, iw)"
  sudo apt-get install -y hostapd iw || \
    log_warn "Failed to install hostapd/iw — the emergency Wi-Fi hotspot fallback won't work until this is resolved (Wi-Fi client networking is unaffected)."
  sudo systemctl disable --now hostapd >/dev/null 2>&1 || true
fi

log_info "Waiting for the dashboard to respond on port ${APP_PORT}"
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${APP_PORT}/" >/dev/null; then
    break
  fi
  sleep 1
done

log_info "11/13 Installing the post-boot health check (auto-rollback on a bad boot)"
# ~2min post-boot: tags last-known-good if /api/data is healthy, else
# rolls back once and restarts — guards against an unbootable checkout.
HEALTH_SCRIPT_PATH="/usr/local/sbin/dashboard-health-check"
install_file "$FILES_DIR/health/dashboard-health-check.sh" "$HEALTH_SCRIPT_PATH"
sudo chmod 755 "$HEALTH_SCRIPT_PATH"
install_file "$FILES_DIR/systemd/dashboard-health-check.service" \
  "/etc/systemd/system/dashboard-health-check.service"
install_file "$FILES_DIR/systemd/dashboard-health-check.timer" \
  "/etc/systemd/system/dashboard-health-check.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now dashboard-health-check.timer

# config.txt/cmdline.txt are OS-owned — these helpers only ever ADD
# (managed block / appended tokens), never rewrite wholesale.
configure_boot_files() {
  local boot_dir
  boot_dir="$(detect_boot_dir)"
  local config="$boot_dir/config.txt"
  local cmdline="$boot_dir/cmdline.txt"

  if is_armbian; then
    warn "Armbian/Orange Pi detected: Raspberry Pi /boot/config.txt and cmdline.txt are not assumed to be present or compatible."
    warn "This image commonly uses Armbian boot configuration instead, and those flags are board-specific."
    local armbian_env=""
    if [[ -f /boot/armbianEnv.txt ]]; then
      armbian_env="/boot/armbianEnv.txt"
    elif [[ -f /boot/firmware/armbianEnv.txt ]]; then
      armbian_env="/boot/firmware/armbianEnv.txt"
    fi
    if [[ -n "$armbian_env" ]]; then
      # Forces HDMI on regardless of hotplug-detect (mainline-DRM
      # equivalent of hdmi_force_hotplug=1), else a cold TV gets no mode.
      ensure_key_tokens_in_file --sudo "$armbian_env" "extraargs" "$FILES_DIR/boot/armbian-extraargs-tokens.txt"
      log_info "Ensured forced HDMI output mode is present in $armbian_env (extraargs=) — takes effect after a reboot"

      # console=serial hides boot text on tty1 while keeping it on serial;
      # doesn't touch bootlogo/splash (plymouth isn't installed here).
      ensure_key_value_in_file --sudo "$armbian_env" "console" "serial"
      log_info "Silenced kernel/systemd boot messages on the HDMI display in $armbian_env (console=serial; still visible over the serial UART) — takes effect after a reboot"
    else
      warn "No Armbian boot environment file was found at /boot/armbianEnv.txt or /boot/firmware/armbianEnv.txt — HDMI force-enable and silent-boot tweaks skipped."
    fi
    return 0
  fi

  if [[ -f "$config" ]]; then
    ensure_block_in_file --sudo "$config" "currency-dashboard-boot" "$FILES_DIR/boot/config-txt-append.conf"
    log_info "Ensured HDMI-always-on / silent-boot settings are present in $config"
  else
    log_warn "Could not find $config — skipping boot config"
  fi

  if [[ -f "$cmdline" ]]; then
    ensure_tokens_in_cmdline --sudo "$cmdline" "$FILES_DIR/boot/cmdline-txt-tokens.txt"
    log_info "Ensured silent-boot/no-console-blanking tokens are present in $cmdline"
  fi
}

reduce_network_wait_online_delay() {
  # wait-online.service ate ~10.5s of ~15.6s boot (confirmed live) — cap
  # via TimeoutStartSec; masking it caused live network flapping instead.
  local unit
  for unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
      install_file "$FILES_DIR/systemd/wait-online-fast-timeout.conf" \
        "/etc/systemd/system/${unit}.d/currency-dashboard-fast-timeout.conf"
      log_info "Capped $unit's start timeout at 5s (was blocking boot far longer than the dashboard needs)"
    fi
  done
  sudo systemctl daemon-reload
}
reduce_network_wait_online_delay

if is_headless; then
  log_info "12/13 Skipping kiosk setup (headless)"
  echo "This board has no display configured — access the dashboard from"
  echo "another device's browser instead: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${APP_PORT}/"
else

log_info "12/13 Configuring kiosk autostart"
configure_boot_files
# Clears stale Chromium Singleton lock files before launch — a non-graceful
# exit leaves them, causing a relaunch dialog instead of the dashboard (hit live).

setup_labwc() {
  # labwc needs no xset-equivalent — configure_boot_files already
  # covers console/firmware-level blanking.
  install_user_file "$FILES_DIR/kiosk/labwc-autostart" "$HOME/.config/labwc/autostart"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log_info "Configured labwc autostart (Raspberry Pi OS Bookworm / Wayland desktop)"
}

setup_wayfire() {
  ensure_block_in_file "$HOME/.config/wayfire.ini" "currency-dashboard-kiosk" \
    "$FILES_DIR/kiosk/wayfire-autostart.snippet"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log_info "Configured wayfire autostart"
}

setup_lxde() {
  install_user_file "$FILES_DIR/kiosk/lxde-autostart" "$HOME/.config/lxsession/LXDE-pi/autostart"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log_info "Configured LXDE autostart (older Raspberry Pi OS desktop)"
}

setup_console_x() {
  # .xinitrc must end with exec, no trailing & (else X exits instantly).
  # matchbox is required for --kiosk to fullscreen; xset (x11-xserver-utils) for DPMS.
  sudo apt install -y xserver-xorg xinit matchbox-window-manager x11-xserver-utils
  install_user_file "$FILES_DIR/kiosk/xinitrc" "$HOME/.xinitrc"
  # chmod explicit: install_user_file doesn't touch perms, and an
  # inode-recreating write reset it non-executable before (confirmed live — silent black screen).
  chmod +x "$HOME/.xinitrc"

  # ensure_block_in_file always converges .bash_profile to the current
  # snippet — same mechanism disable-kiosk.sh's --remove uses.
  ensure_block_in_file "$HOME/.bash_profile" "currency-dashboard-kiosk" "$FILES_DIR/kiosk/bash-profile.snippet"

  # tty1 autologin reaches .bash_profile/.xinitrc — applied unconditionally
  # since Armbian has no raspi-config (confirmed live: boot stopped at login prompt).
  install_file "$FILES_DIR/systemd/getty-autologin.conf" \
    "/etc/systemd/system/getty@tty1.service.d/autologin.conf"
  sudo systemctl daemon-reload
  log_info "Configured tty1 autologin as $USER (takes effect on next boot, or: sudo systemctl restart getty@tty1)"

  # .hushlogin suppresses the MOTD/last-login text that would otherwise
  # flash on tty1 before .bash_profile's startx takes over.
  touch "$HOME/.hushlogin"

  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B2 || true
    log_info "Configured console autologin + startx kiosk (Raspberry Pi OS Lite)"
  else
    log_info "Configured generic X11 kiosk launch in ~/.bash_profile ~/.xinitrc (Armbian/Orange Pi)"
  fi
}

detect_desktop_environment() {
  if command -v labwc >/dev/null 2>&1 || [[ -d /usr/share/labwc ]]; then
    echo "labwc"
  elif command -v wayfire >/dev/null 2>&1; then
    echo "wayfire"
  elif [[ -d /etc/xdg/lxsession/LXDE-pi ]] || command -v lxsession >/dev/null 2>&1; then
    echo "lxde"
  elif command -v startx >/dev/null 2>&1; then
    echo "x11"
  else
    echo "unknown"
  fi
}

case "$(detect_desktop_environment)" in
  labwc)
    setup_labwc
    ;;
  wayfire)
    setup_wayfire
    ;;
  lxde)
    setup_lxde
    ;;
  x11|unknown)
    if is_armbian; then
      warn "Armbian detected: no stable desktop session manager was found; falling back to the generic X11 launcher path."
      warn "If your image does not auto-login to X or does not start X on tty1, configure that through the Armbian service manager or the board's native startup tooling."
    fi
    setup_console_x
    ;;
esac

fi  # is_headless

log_info "13/13 Done"
echo "Dashboard service:   sudo systemctl status ${SERVICE_NAME}"
echo "Dashboard URL:       http://localhost:${APP_PORT}/"
if [[ -f "$INSTALL_DIR/ssl/cert.pem" ]]; then
  echo "Admin panel (HTTPS): https://$(hostname):${HTTPS_PORT}/admin  (self-signed — your browser will warn once, accept the exception)"
else
  echo "Admin panel (HTTP, no cert yet): http://localhost:${APP_PORT}/admin"
fi
echo "Auto-updater:        sudo systemctl status ${SERVICE_NAME}-updater.timer  (runs every 6h if enabled in the admin panel; branch in scripts/auto-update.conf)"
echo "Network reconciler:  sudo systemctl status dashboard-net-apply  (applies Wi-Fi/hotspot/reboot requests from the admin panel every ~5s)"
echo "Health check:        sudo systemctl status dashboard-health-check.timer  (runs once ~2min after boot; rolls back to last-known-good on failure)"
echo
if is_headless; then
  echo "Headless mode — the service is already running, nothing more to do."
else
  warn "Reboot to launch the dashboard in kiosk mode: sudo reboot"
fi
