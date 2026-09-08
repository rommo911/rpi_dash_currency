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
# and re-applies the service/kiosk/cert/updater config.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/<your-username>/rpi_dash_currency.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/currency-dashboard}"
SERVICE_NAME="currency-dashboard"
APP_PORT="${APP_PORT:-5000}"
HTTPS_PORT="${HTTPS_PORT:-5443}"
HEADLESS="${HEADLESS:-false}"
LAN_SUBNET="${LAN_SUBNET:-}"

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

log "1/11 Installing system dependencies"
sudo apt update
sudo apt install -y git python3-venv python3-pip curl openssl

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

log "2/11 Cloning/updating repository into $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  # A checkout from before data.json/config.py were gitignored may still
  # have them TRACKED with local (real, live) modifications — untrack
  # them first (keeps the on-disk file untouched) so the update below can
  # never delete them. fetch+reset instead of a plain `git pull`: pull
  # refuses outright on local changes to a path the merge touches (a loud
  # but safe failure), while fetch+reset here — now that the untrack
  # guard makes it safe — always succeeds, matching what
  # scripts/auto-update.sh already does for consistency.
  git -C "$INSTALL_DIR" rm --cached -q data.json config.py 2>/dev/null || true
  CURRENT_BRANCH="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)"
  git -C "$INSTALL_DIR" fetch origin "$CURRENT_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$CURRENT_BRANCH"
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

log "3/11 Setting up local config (data.json, config.py, auto-update.conf)"
# These three are gitignored and never committed as themselves — copied
# from their tracked templates only if missing, so a later `git reset --hard`
# (see scripts/auto-update.sh) can never touch live prices, the real admin
# password, or your chosen auto-update branch.
NEW_CONFIG=false
if [[ ! -f "$INSTALL_DIR/data.json" ]]; then
  cp "$INSTALL_DIR/data.default.json" "$INSTALL_DIR/data.json"
fi
if [[ ! -f "$INSTALL_DIR/config.py" ]]; then
  cp "$INSTALL_DIR/config.py.example" "$INSTALL_DIR/config.py"
  NEW_CONFIG=true
fi
if [[ ! -f "$INSTALL_DIR/scripts/auto-update.conf" ]]; then
  cp "$INSTALL_DIR/scripts/auto-update.conf.example" "$INSTALL_DIR/scripts/auto-update.conf"
fi
# Auto-update is a flag FILE (see app.py/auto-update.sh), not a data.json
# setting — the admin panel's "Enable automatic updates" checkbox
# creates/removes it directly. Defaults to present (enabled) ONLY on a
# genuinely fresh install (tied to NEW_CONFIG, same signal the password
# prompt above uses) — matching this project's previous always-on
# behavior for a first deploy, without ever re-enabling it behind an
# admin's back on a later redeploy after they've explicitly unchecked it.
if [[ "$NEW_CONFIG" == true ]]; then
  touch "$INSTALL_DIR/auto-update.enabled" 2>/dev/null || true
fi
if [[ "$NEW_CONFIG" == true ]]; then
  # -t 0 guards against a non-interactive run (automation, `ssh host cmd`
  # with no pty, piped input): deploy-dashboard.sh is documented as safe
  # to run unattended, and a bare `read` on closed/non-tty stdin returns
  # non-zero, which set -e would treat as this whole script failing.
  SET_ADMIN_PW="n"
  if [[ -t 0 ]]; then
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
    # Written via python's repr() so any character in the password (quotes,
    # backslashes, unicode) ends up correctly escaped in the .py file —
    # safer than trying to do this with sed.
    python3 - "$ADMIN_PW1" "$INSTALL_DIR/config.py" <<'PYEOF'
import pathlib
import sys

pw, cfg_path = sys.argv[1], pathlib.Path(sys.argv[2])
lines = cfg_path.read_text(encoding="utf-8").splitlines(keepends=True)
out = [f"ADMIN_PASSWORD = {pw!r}\n" if line.strip().startswith("ADMIN_PASSWORD") else line for line in lines]
cfg_path.write_text("".join(out), encoding="utf-8")
PYEOF
    unset ADMIN_PW1 ADMIN_PW2
    log "Admin panel password set."
  else
    warn "config.py created with the placeholder password — change ADMIN_PASSWORD in $INSTALL_DIR/config.py before relying on it."
  fi
fi

log "4/11 Creating virtualenv and installing Python deps"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

log "5/11 Generating/renewing the self-signed HTTPS certificate"
INSTALL_DIR="$INSTALL_DIR" bash "$INSTALL_DIR/scripts/generate-cert.sh" || \
  warn "Certificate generation failed — the admin panel will fall back to HTTP only until this is fixed."

log "6/11 Installing systemd service"
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Currency Dashboard
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/.venv/bin/python $INSTALL_DIR/app.py
WorkingDirectory=$INSTALL_DIR
Environment=APP_PORT=$APP_PORT
Environment=HTTPS_PORT=$HTTPS_PORT
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

log "7/11 Firewall: opening the HTTPS admin port"
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  if [[ -n "$LAN_SUBNET" ]]; then
    sudo ufw allow from "$LAN_SUBNET" to any port "$HTTPS_PORT" proto tcp
  else
    sudo ufw allow "$HTTPS_PORT"/tcp
  fi
else
  log "ufw not active — skipping (nothing to open)"
fi

log "8/11 Installing the auto-updater (git pull + cert renewal every 6h)"
SYSTEMCTL_BIN="$(command -v systemctl)"
SUDOERS_FILE="/etc/sudoers.d/${SERVICE_NAME}-updater"
SUDOERS_TMP="$(mktemp)"
# Two commands, both exact-match (no wildcards): restarting the app after
# an update lands, and the admin panel's "Check for updates now" button
# starting the updater service immediately instead of waiting for the
# timer. app.py's admin_check_update_now() runs the second one verbatim —
# keep both in sync if either changes.
{
  echo "$USER ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} restart ${SERVICE_NAME}"
  echo "$USER ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} start ${SERVICE_NAME}-updater.service"
} > "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
  warn "Generated sudoers rule failed validation — the auto-updater won't be able to restart the service, and the admin panel's 'check now' button won't be able to trigger a check, automatically."
  warn "Restart it by hand after an update: sudo systemctl restart ${SERVICE_NAME}"
fi
rm -f "$SUDOERS_TMP"

sudo tee "/etc/systemd/system/${SERVICE_NAME}-updater.service" > /dev/null <<EOF
[Unit]
Description=Currency Dashboard auto-updater (git pull + cert renewal)

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_DIR/scripts/auto-update.sh
WorkingDirectory=$INSTALL_DIR
Environment=INSTALL_DIR=$INSTALL_DIR
Environment=SERVICE_NAME=${SERVICE_NAME}
User=$USER
EOF

sudo tee "/etc/systemd/system/${SERVICE_NAME}-updater.timer" > /dev/null <<EOF
[Unit]
Description=Run the Currency Dashboard auto-updater periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}-updater.timer"

log "9/11 Securing the admin panel: fail2ban jail for repeated failed logins"
if command -v fail2ban-client >/dev/null 2>&1; then
  sudo tee "/etc/fail2ban/filter.d/${SERVICE_NAME}.conf" > /dev/null <<'EOF'
[Definition]
failregex = ^.*Failed admin login from <HOST>\s*$
ignoreregex =
EOF
  sudo tee "/etc/fail2ban/jail.d/${SERVICE_NAME}.local" > /dev/null <<EOF
[${SERVICE_NAME}]
enabled      = true
port         = ${APP_PORT},${HTTPS_PORT}
filter       = ${SERVICE_NAME}
backend      = systemd
journalmatch = _SYSTEMD_UNIT=${SERVICE_NAME}.service
bantime      = 1h
findtime     = 10m
maxretry     = 6
EOF
  sudo systemctl restart fail2ban
else
  log "fail2ban not installed (run provision-pi.sh first for full hardening) — skipping the admin-login jail"
fi

log "Waiting for the dashboard to respond on port ${APP_PORT}"
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${APP_PORT}/" >/dev/null; then
    break
  fi
  sleep 1
done

configure_hdmi_always_on() {
  local boot_dir=/boot/firmware
  [[ -d "$boot_dir" ]] || boot_dir=/boot
  local config="$boot_dir/config.txt"
  local cmdline="$boot_dir/cmdline.txt"

  if [[ -f "$config" ]]; then
    local changed=0
    for line in "hdmi_force_hotplug=1" "hdmi_force_hotplug:0=1" "hdmi_force_hotplug:1=1"; do
      if ! grep -qxF "$line" "$config"; then
        [[ "$changed" -eq 0 ]] && sudo cp "$config" "${config}.bak.$(date +%s)"
        echo "$line" | sudo tee -a "$config" >/dev/null
        changed=1
      fi
    done
    if [[ "$changed" -eq 1 ]]; then
      log "Forced HDMI output on in $config — the screen stays active even if no monitor is attached at boot (plugging one in later works without a reboot)"
    fi
  else
    warn "Could not find $config — skipping HDMI force-hotplug"
  fi

  if [[ -f "$cmdline" ]] && ! grep -q 'consoleblank=0' "$cmdline"; then
    sudo cp "$cmdline" "${cmdline}.bak.$(date +%s)"
    sudo sed -i 's/$/ consoleblank=0/' "$cmdline"
    log "Disabled console screen blanking in $cmdline"
  fi
}

configure_silent_boot() {
  # Hide the kernel log spam, systemd "[ OK ] Started ..." lines, boot
  # logo, and boot-delay countdown — a kiosk display has no reason to
  # show any of that. Doesn't touch SSH's serial/tty1 console attachment,
  # just how chatty the boot is on it.
  local boot_dir=/boot/firmware
  [[ -d "$boot_dir" ]] || boot_dir=/boot
  local config="$boot_dir/config.txt"
  local cmdline="$boot_dir/cmdline.txt"

  if [[ -f "$cmdline" ]]; then
    local line
    line="$(cat "$cmdline")"
    local original="$line"
    local tok
    for tok in quiet loglevel=0 systemd.show_status=0 vt.global_cursor_default=0 logo.nologo; do
      if ! grep -qw "$tok" <<<"$line"; then
        line="$line $tok"
      fi
    done
    if [[ "$line" != "$original" ]]; then
      sudo cp "$cmdline" "${cmdline}.bak.$(date +%s)"
      echo "$line" | sudo tee "$cmdline" >/dev/null
      log "Silenced kernel/systemd boot messages in $cmdline"
    fi
  fi

  if [[ -f "$config" ]]; then
    local changed=0
    local line2
    for line2 in "disable_splash=1" "boot_delay=0"; do
      if ! grep -qxF "$line2" "$config"; then
        [[ "$changed" -eq 0 ]] && sudo cp "$config" "${config}.bak.$(date +%s)"
        echo "$line2" | sudo tee -a "$config" >/dev/null
        changed=1
      fi
    done
    if [[ "$changed" -eq 1 ]]; then
      log "Disabled boot splash/delay in $config"
    fi
  fi
}

if is_headless; then
  log "10/11 Skipping kiosk setup (headless)"
  echo "This board has no display configured — access the dashboard from"
  echo "another device's browser instead: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${APP_PORT}/"
else

log "10/11 Configuring kiosk autostart"
configure_hdmi_always_on
configure_silent_boot
KIOSK_CMD="$CHROMIUM_BIN --kiosk --incognito --noerrant --disable-infobars --disable-session-crashed-bubble --check-for-update-interval=31536000 http://localhost:${APP_PORT}"

setup_labwc() {
  # labwc doesn't blank/DPMS the screen by default on Pi OS Bookworm, so no
  # xset-equivalent is needed here — configure_hdmi_always_on already
  # covers the console/firmware-level blanking that would otherwise apply.
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
  # $KIOSK_CMD must be the FOREGROUND last command here (via exec, no
  # trailing &) — xinit/startx tears the X session down the instant
  # .xinitrc reaches EOF with nothing left to wait on. Backgrounding it
  # made X start, launch Chromium, and immediately exit again a few
  # seconds later ("Server terminated successfully (0)" in Xorg.0.log)
  # every single time — this was a real bug, caught live on a deployed
  # Pi where the console dropped straight back to a login shell.
  #
  # matchbox-window-manager is required here, not optional: bare xinit
  # starts NO window manager at all, and without one nobody honors
  # Chromium's --kiosk fullscreen request — it just gets whatever default
  # size its toolkit picks (observed live: ~945x1060 at +10+10 on a
  # 1920x1080 screen, i.e. the dashboard filling only the left half).
  # matchbox is the standard minimal WM for exactly this Pi-OS-Lite-kiosk
  # case; it auto-maximizes any window it manages. Give it a moment to
  # start before Chromium maps its window, or the race can lose the same
  # way.
  #
  # The mouse pointer (visible on screen despite no mouse being attached)
  # is hidden at the Xorg SERVER level via `startx -- -nocursor` below,
  # not just matchbox's own -use_cursor no (which only controls whether
  # matchbox itself draws/manages a cursor for the root window — the
  # default X-server arrow cursor was still rendering on top of that).
  # -nocursor tells Xorg not to draw a cursor sprite at all, ever.
  sudo apt install -y xserver-xorg xinit matchbox-window-manager
  cat > "$HOME/.xinitrc" <<EOF
xset -dpms
xset s off
xset s noblank
matchbox-window-manager -use_cursor no -use_titlebar no &
sleep 1
until curl -s http://localhost:${APP_PORT} >/dev/null; do sleep 1; done
exec $KIOSK_CMD
EOF
  # Match only an ACTIVE (uncommented) startx line — scripts/disable-kiosk.sh
  # neutralizes kiosk autostart by commenting this exact line out, and a
  # plain `grep -q "startx"` would still match inside that comment, making
  # deploy-dashboard.sh wrongly think kiosk autostart is already configured
  # and silently skip re-adding it. This way a redeploy after disabling
  # correctly restores it (the old commented block stays too, harmlessly).
  # \b not \s*$ at the end — the line carries "-- -nocursor" now (see
  # below), so it no longer ends right after "startx".
  #
  # If an active line already exists, SYNC its content instead of leaving
  # it alone — this is not "insert once and never touch again." Caught
  # live: a Pi provisioned before -- -nocursor was added kept its old bare
  # `startx` line untouched across a redeploy, because the old check only
  # asked "does an active line exist," not "does it match what we'd write
  # today" — so the cursor fix silently never landed on an
  # already-provisioned board. Self-healing this way means any future
  # change to this line reaches existing installs on their next redeploy
  # too, not just fresh ones.
  if grep -qE '^\s*startx\b' "$HOME/.bash_profile" 2>/dev/null; then
    sed -i -E 's|^(\s*)startx\b.*|\1startx -- -nocursor|' "$HOME/.bash_profile"
  else
    cat >> "$HOME/.bash_profile" <<'PROFILE'

if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx -- -nocursor
fi
PROFILE
  fi
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

log "11/11 Done"
echo "Dashboard service:   sudo systemctl status ${SERVICE_NAME}"
echo "Dashboard URL:       http://localhost:${APP_PORT}/"
if [[ -f "$INSTALL_DIR/ssl/cert.pem" ]]; then
  echo "Admin panel (HTTPS): https://$(hostname):${HTTPS_PORT}/admin  (self-signed — your browser will warn once, accept the exception)"
else
  echo "Admin panel (HTTP, no cert yet): http://localhost:${APP_PORT}/admin"
fi
echo "Auto-updater:        sudo systemctl status ${SERVICE_NAME}-updater.timer  (runs every 6h if enabled in the admin panel; branch in scripts/auto-update.conf)"
echo
if is_headless; then
  echo "Headless mode — the service is already running, nothing more to do."
else
  warn "Reboot to launch the dashboard in kiosk mode: sudo reboot"
fi
