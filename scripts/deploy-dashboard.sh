#!/usr/bin/env bash
# Stage 3 of 3 (also safe to run entirely standalone): clone/update the
# currency dashboard on a Raspberry Pi and boot straight into it in kiosk
# mode. This is the default and always what happens unless you explicitly
# opt out — kiosk mode is not skipped based on guessing what hardware
# this is.
#
# Every installed config file below (systemd units, fail2ban, sudoers,
# kiosk autostart, boot config) is a real file under scripts/files/,
# rendered via lib.sh's render_template/ensure_block_in_file — nothing
# here authors config content inline or edits an OS file with sed. See
# scripts/lib.sh for why.
#
# Run this as the normal user the Pi boots into (e.g. "pi" or
# "dashboard"), normally invoked automatically by harden-system.sh, but
# also fine to run entirely on its own if you just want the app without
# the security hardening.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
if [[ -f "$SCRIPT_DIR/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib.sh"
else
  # Running copied-alone, before the repo (and lib.sh/scripts/files with
  # it) exists on disk yet — bare log/warn/is_auto cover everything used
  # before the clone step below; render_template & friends are only
  # called after it, by which point lib.sh is re-sourced from the fresh
  # checkout (see FILES_DIR re-point below).
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
# Re-point FILES_DIR/lib.sh at the checkout we just ensured is current, in
# case this script started from a different location than $INSTALL_DIR
# (e.g. run copied-alone, before it had cloned anything) — the fallback
# log/warn/is_auto above cover everything up to this point, but
# render_template & friends (used from here on) need the real lib.sh.
FILES_DIR="$INSTALL_DIR/scripts/files"
# shellcheck disable=SC1091
source "$INSTALL_DIR/scripts/lib.sh"

log "3/11 Setting up local config (data.json, .env, auto-update.conf)"
# These files are gitignored and never committed as themselves — copied
# from their tracked templates only if missing, so a later `git reset --hard`
# (see scripts/auto-update.sh) can never touch live prices, the real admin
# password, or your chosen auto-update branch.
NEW_ENV=false
if [[ ! -f "$INSTALL_DIR/data.json" ]]; then
  cp "$INSTALL_DIR/data.default.json" "$INSTALL_DIR/data.json"
fi
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  NEW_ENV=true
fi
if [[ ! -f "$INSTALL_DIR/scripts/auto-update.conf" ]]; then
  cp "$INSTALL_DIR/scripts/auto-update.conf.example" "$INSTALL_DIR/scripts/auto-update.conf"
fi
# Auto-update is a flag FILE (see app.py/auto-update.sh), not a data.json
# setting — the admin panel's "Enable automatic updates" checkbox
# creates/removes it directly. Defaults to present (enabled) ONLY on a
# genuinely fresh install (tied to NEW_ENV, same signal the password
# prompt above uses) — matching this project's previous always-on
# behavior for a first deploy, without ever re-enabling it behind an
# admin's back on a later redeploy after they've explicitly unchecked it.
if [[ "$NEW_ENV" == true ]]; then
  touch "$INSTALL_DIR/auto-update.enabled" 2>/dev/null || true
fi
if [[ "$NEW_ENV" == true ]]; then
  # -t 0 guards against a non-interactive run (automation, `ssh host cmd`
  # with no pty, piped input, or --auto_default) — deploy-dashboard.sh is
  # documented as safe to run unattended, and a bare `read` on
  # closed/non-tty stdin returns non-zero, which set -e would treat as
  # this whole script failing.
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
    log "Admin panel password set."
  else
    warn "No custom password set — put ADMIN_PASSWORD in $INSTALL_DIR/.env before relying on the admin panel."
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
render_template "$FILES_DIR/systemd/currency-dashboard.service" \
  "/etc/systemd/system/${SERVICE_NAME}.service" \
  "INSTALL_DIR=$INSTALL_DIR" "APP_PORT=$APP_PORT" "HTTPS_PORT=$HTTPS_PORT" "RUN_USER=$USER"

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
# Rendered to a LOCAL temp file first (not straight to /etc/sudoers.d)
# so it can be validated with visudo before it's ever live, and so it
# lands with the correct 440 root:root permissions via `install` — a
# plain `sudo tee` would leave it world-readable, which sudoers must
# never be.
SUDOERS_TMP="$(mktemp)"
render_template_user "$FILES_DIR/sudoers/currency-dashboard-updater" "$SUDOERS_TMP" \
  "RUN_USER=$USER" "SYSTEMCTL_BIN=$SYSTEMCTL_BIN" "SERVICE_NAME=$SERVICE_NAME"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
  warn "Generated sudoers rule failed validation — the auto-updater won't be able to restart the service, and the admin panel's 'check now' button won't be able to trigger a check, automatically."
  warn "Restart it by hand after an update: sudo systemctl restart ${SERVICE_NAME}"
fi
rm -f "$SUDOERS_TMP"

render_template "$FILES_DIR/systemd/currency-dashboard-updater.service" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.service" \
  "INSTALL_DIR=$INSTALL_DIR" "SERVICE_NAME=$SERVICE_NAME" "RUN_USER=$USER"
render_template "$FILES_DIR/systemd/currency-dashboard-updater.timer" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.timer"

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}-updater.timer"

log "9/11 Securing the admin panel: fail2ban jail for repeated failed logins"
if command -v fail2ban-client >/dev/null 2>&1; then
  render_template "$FILES_DIR/fail2ban/currency-dashboard.filter" \
    "/etc/fail2ban/filter.d/${SERVICE_NAME}.conf"
  render_template "$FILES_DIR/fail2ban/currency-dashboard.jail" \
    "/etc/fail2ban/jail.d/${SERVICE_NAME}.local" \
    "SERVICE_NAME=$SERVICE_NAME" "APP_PORT=$APP_PORT" "HTTPS_PORT=$HTTPS_PORT"
  sudo systemctl restart fail2ban
else
  log "fail2ban not installed (run provision-pi.sh/harden-system.sh first for full hardening) — skipping the admin-login jail"
fi

log "Waiting for the dashboard to respond on port ${APP_PORT}"
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${APP_PORT}/" >/dev/null; then
    break
  fi
  sleep 1
done

# config.txt/cmdline.txt are OS-owned firmware files that also carry a lot
# of Pi-model-specific content we must never touch — ensure_block_in_file
# (config.txt: comment-delimited managed block) and ensure_tokens_in_cmdline
# (cmdline.txt: a single line, no comment syntax at all, so tokens are
# appended directly rather than wrapped in a block) both only ever ADD to
# these files, never rewrite them wholesale.
configure_boot_files() {
  local boot_dir=/boot/firmware
  [[ -d "$boot_dir" ]] || boot_dir=/boot
  local config="$boot_dir/config.txt"
  local cmdline="$boot_dir/cmdline.txt"

  if [[ -f "$config" ]]; then
    ensure_block_in_file --sudo "$config" "currency-dashboard-boot" "$FILES_DIR/boot/config-txt-append.conf"
    log "Ensured HDMI-always-on / silent-boot settings are present in $config"
  else
    warn "Could not find $config — skipping boot config"
  fi

  if [[ -f "$cmdline" ]]; then
    ensure_tokens_in_cmdline --sudo "$cmdline" "$FILES_DIR/boot/cmdline-txt-tokens.txt"
    log "Ensured silent-boot/no-console-blanking tokens are present in $cmdline"
  fi
}

if is_headless; then
  log "10/11 Skipping kiosk setup (headless)"
  echo "This board has no display configured — access the dashboard from"
  echo "another device's browser instead: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${APP_PORT}/"
else

log "10/11 Configuring kiosk autostart"
configure_boot_files
KIOSK_CMD="$CHROMIUM_BIN --kiosk --incognito --noerrant --disable-infobars --disable-session-crashed-bubble --check-for-update-interval=31536000 http://localhost:${APP_PORT}"

setup_labwc() {
  # labwc doesn't blank/DPMS the screen by default on Pi OS Bookworm, so no
  # xset-equivalent is needed here — configure_boot_files already covers
  # the console/firmware-level blanking that would otherwise apply.
  render_template_user "$FILES_DIR/kiosk/labwc-autostart" "$HOME/.config/labwc/autostart" "KIOSK_CMD=$KIOSK_CMD"
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured labwc autostart (Raspberry Pi OS Bookworm / Wayland desktop)"
}

setup_wayfire() {
  ensure_block_in_file "$HOME/.config/wayfire.ini" "currency-dashboard-kiosk" \
    "$FILES_DIR/kiosk/wayfire-autostart.snippet" "KIOSK_CMD=$KIOSK_CMD"
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured wayfire autostart"
}

setup_lxde() {
  render_template_user "$FILES_DIR/kiosk/lxde-autostart" "$HOME/.config/lxsession/LXDE-pi/autostart" "KIOSK_CMD=$KIOSK_CMD"
  command -v raspi-config >/dev/null 2>&1 && sudo raspi-config nonint do_boot_behaviour B4 || true
  log "Configured LXDE autostart (older Raspberry Pi OS desktop)"
}

setup_console_x() {
  # $KIOSK_CMD must be the FOREGROUND last command in .xinitrc (via exec,
  # no trailing &) — xinit/startx tears the X session down the instant
  # .xinitrc reaches EOF with nothing left to wait on. Backgrounding it
  # made X start, launch Chromium, and immediately exit again a few
  # seconds later ("Server terminated successfully (0)" in Xorg.0.log)
  # every single time — this was a real bug, caught live on a deployed
  # Pi. See scripts/files/kiosk/xinitrc — the template already ends with
  # `exec {{KIOSK_CMD}}`, keep it that way if you touch it.
  #
  # matchbox-window-manager is required here, not optional: bare xinit
  # starts NO window manager at all, and without one nobody honors
  # Chromium's --kiosk fullscreen request — it just gets whatever default
  # size its toolkit picks. matchbox is the standard minimal WM for
  # exactly this Pi-OS-Lite-kiosk case; it auto-maximizes any window it
  # manages.
  #
  # The mouse pointer (visible on screen despite no mouse being attached)
  # is hidden at the Xorg SERVER level via `startx -- -nocursor` in the
  # bash_profile snippet below, not just matchbox's own -use_cursor no
  # (which only controls whether matchbox itself draws/manages a cursor
  # for the root window — the default X-server arrow cursor was still
  # rendering on top of that). -nocursor tells Xorg not to draw a cursor
  # sprite at all, ever.
  sudo apt install -y xserver-xorg xinit matchbox-window-manager
  render_template_user "$FILES_DIR/kiosk/xinitrc" "$HOME/.xinitrc" "APP_PORT=$APP_PORT" "KIOSK_CMD=$KIOSK_CMD"

  # ensure_block_in_file (see scripts/lib.sh) always converges .bash_profile
  # on exactly the current scripts/files/kiosk/bash-profile.snippet content,
  # whatever was there on a previous run — this replaces the old bespoke
  # sed self-heal logic (see CLAUDE.md for the bug that caused) with the
  # same shared, independently-tested mechanism disable-kiosk.sh's
  # --remove counterpart uses.
  ensure_block_in_file "$HOME/.bash_profile" "currency-dashboard-kiosk" "$FILES_DIR/kiosk/bash-profile.snippet"
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
