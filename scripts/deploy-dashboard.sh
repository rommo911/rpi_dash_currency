#!/usr/bin/env bash
# Clone + install the currency dashboard on a Raspberry Pi and boot straight
# into it in kiosk mode. This is the default and always what happens unless
# you explicitly opt out — kiosk mode is not skipped based on guessing what
# hardware this is.
#
# Run this as the normal user the Pi boots into (e.g. "pi"), AFTER
# provision-pi.sh has already hardened the system (or on its own, if you
# just want the app without the security hardening).
#
# Usage:
#   REPO_URL=https://github.com/<you>/rpi_dash_currency.git ./deploy-dashboard.sh
#
#   # Only for a board with no display attached (e.g. a headless Pi Zero W
#   # you're reaching over the network) — skips Chromium/kiosk entirely.
#   # You must ask for this explicitly; it is never assumed.
#   HEADLESS=true REPO_URL=... ./deploy-dashboard.sh
#
# Re-running this script is safe: it pulls the latest code, reinstalls deps,
# and re-applies the service/kiosk config.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/<your-username>/rpi_dash_currency.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/currency-dashboard}"
SERVICE_NAME="currency-dashboard"
APP_PORT="${APP_PORT:-5000}"
HEADLESS="${HEADLESS:-false}"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

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
    warn "This looks like a Pi Zero / Zero W — it's quite weak for a browser."
    warn "If it has no display attached, re-run with HEADLESS=true instead. Continuing with kiosk setup as requested."
  fi
fi

log "1/6 Installing system dependencies"
sudo apt update
sudo apt install -y git python3-venv python3-pip curl

CHROMIUM_BIN=""
if is_headless; then
  log "HEADLESS=true — skipping Chromium/kiosk setup"
else
  CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
  if [[ -z "$CHROMIUM_BIN" ]]; then
    log "Installing Chromium"
    sudo apt install -y chromium-browser 2>/dev/null || sudo apt install -y chromium
    CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium)"
  fi
fi

log "2/6 Cloning/updating repository into $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

log "3/6 Creating virtualenv and installing Python deps"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

log "4/6 Installing systemd service"
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Currency Dashboard
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/.venv/bin/python $INSTALL_DIR/app.py
WorkingDirectory=$INSTALL_DIR
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

log "Waiting for the dashboard to respond on port ${APP_PORT}"
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${APP_PORT}/" >/dev/null; then
    break
  fi
  sleep 1
done

if is_headless; then
  log "5/6 Skipping kiosk setup (headless)"
  echo "This board has no display configured — access the dashboard from"
  echo "another device's browser instead: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${APP_PORT}/"
else

log "5/6 Configuring kiosk autostart"
KIOSK_CMD="$CHROMIUM_BIN --kiosk --incognito --noerrant --disable-infobars --disable-session-crashed-bubble --check-for-update-interval=31536000 http://localhost:${APP_PORT}"

setup_labwc() {
  mkdir -p "$HOME/.config/labwc"
  cat > "$HOME/.config/labwc/autostart" <<EOF
$KIOSK_CMD &
EOF
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured labwc autostart (Raspberry Pi OS Bookworm / Wayland desktop)"
}

setup_wayfire() {
  local cfg="$HOME/.config/wayfire.ini"
  touch "$cfg"
  grep -q '^\[autostart\]' "$cfg" || printf '\n[autostart]\n' >> "$cfg"
  grep -q 'kiosk_dashboard' "$cfg" || sed -i "/^\[autostart\]/a kiosk_dashboard = $KIOSK_CMD" "$cfg"
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured wayfire autostart"
}

setup_lxde() {
  mkdir -p "$HOME/.config/lxsession/LXDE-pi"
  cat > "$HOME/.config/lxsession/LXDE-pi/autostart" <<EOF
@xset s off
@xset -dpms
@xset s noblank
@$KIOSK_CMD
EOF
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured LXDE autostart (older Raspberry Pi OS desktop)"
}

setup_console_x() {
  cat > "$HOME/.xinitrc" <<EOF
xset -dpms
xset s off
xset s noblank
until curl -s http://localhost:${APP_PORT} >/dev/null; do sleep 1; done
$KIOSK_CMD &
EOF
  if ! grep -q "startx" "$HOME/.bash_profile" 2>/dev/null; then
    cat >> "$HOME/.bash_profile" <<'PROFILE'

if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx
fi
PROFILE
  fi
  sudo apt install -y xserver-xorg xinit
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B2 || true
  log "Configured console autologin + startx kiosk (Raspberry Pi OS Lite)"
}

if command -v labwc >/dev/null 2>&1 || [[ -d /usr/share/labwc ]]; then
  setup_labwc
elif command -v wayfire >/dev/null 2>&1; then
  setup_wayfire
elif [[ -d /etc/xdg/lxsession/LXDE-pi ]] || command -v lxsession >/dev/null 2>&1; then
  setup_lxde
else
  setup_console_x
fi

fi  # is_headless

log "6/6 Done"
echo "Dashboard service: sudo systemctl status ${SERVICE_NAME}"
echo "Dashboard URL:      http://localhost:${APP_PORT}/"
echo
if is_headless; then
  echo "Headless mode — the service is already running, nothing more to do."
else
  warn "Reboot to launch the dashboard in kiosk mode: sudo reboot"
fi
