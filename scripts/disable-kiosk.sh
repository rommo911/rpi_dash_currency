#!/usr/bin/env bash
# Put the Pi into maintenance mode: stop and disable the dashboard service,
# pause the auto-updater timer, stop the kiosk browser from auto-launching
# on the next boot, and kill any X/Chromium session currently running —
# so the console is free and the app isn't fighting you (or the updater
# timer) while you SSH in to do admin work.
#
# Reversible: re-running scripts/deploy-dashboard.sh restores everything
# (service, updater timer, kiosk autostart) — that's the intended way
# back, there's no separate "enable" script.
#
# Usage: ./disable-kiosk.sh
#   (run as the normal user the Pi boots into, e.g. "dashboard" — it uses
#   sudo where needed)

set -uo pipefail
# Not set -e: this script's job is "make a best effort at everything on
# the list," not "abort the whole thing because chromium wasn't running."
# Each step reports what it did; nothing here is destructive if it's a
# no-op because that piece was already stopped/disabled.

SERVICE_NAME="${SERVICE_NAME:-currency-dashboard}"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (e.g. 'dashboard'), not as root — it calls sudo where needed."
  exit 1
fi

log "Stopping and disabling the ${SERVICE_NAME} service"
if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  sudo systemctl disable --now "${SERVICE_NAME}" 2>&1
else
  echo "${SERVICE_NAME}.service not found — nothing to stop."
fi

log "Pausing the auto-updater timer"
if systemctl list-unit-files "${SERVICE_NAME}-updater.timer" >/dev/null 2>&1; then
  sudo systemctl disable --now "${SERVICE_NAME}-updater.timer" 2>&1
else
  echo "${SERVICE_NAME}-updater.timer not found — nothing to pause."
fi

log "Disabling kiosk auto-boot"
if [[ -f "$HOME/.bash_profile" ]] && grep -qE '^\s*startx\s*$' "$HOME/.bash_profile"; then
  cp "$HOME/.bash_profile" "$HOME/.bash_profile.bak.$(date +%s)"
  # `:` (a real, valid no-op command), NOT a bare comment -- replacing the
  # only statement inside an if/then/fi with just a comment leaves an
  # EMPTY then-body, which is a bash syntax error ("unexpected token
  # `fi'"). That error aborts sourcing the rest of .bash_profile entirely,
  # silently skipping any later block too -- including a freshly
  # redeployed, otherwise-correct startx block. Confirmed live: this
  # exact bug caused a real Pi's kiosk to never come back after
  # disable-kiosk.sh + a redeploy, verified with a standalone repro before
  # this fix (see CLAUDE.md).
  sed -i -E 's/^(\s*)startx\s*$/\1: # startx disabled by disable-kiosk.sh -- re-run deploy-dashboard.sh to restore/' "$HOME/.bash_profile"
  echo "Commented out the 'startx' line in ~/.bash_profile — kiosk will no longer auto-launch on boot."
else
  echo "No active 'startx' line found in ~/.bash_profile — already disabled, or console+X kiosk was never configured on this board."
fi

log "Stopping any kiosk session currently running"
pkill -f 'chromium.*--kiosk' 2>/dev/null && echo "Stopped chromium." || echo "No kiosk chromium process was running."
pkill -x matchbox-window-manager 2>/dev/null && echo "Stopped matchbox-window-manager." || echo "matchbox-window-manager was not running."
sudo pkill -x Xorg 2>/dev/null && echo "Stopped Xorg." || echo "Xorg was not running."

echo
echo "Maintenance mode active:"
echo "  - ${SERVICE_NAME}.service: stopped and disabled"
echo "  - ${SERVICE_NAME}-updater.timer: stopped and disabled"
echo "  - kiosk auto-boot: disabled (won't relaunch after a reboot either)"
echo "  - any running Xorg/chromium/matchbox session: stopped"
echo
echo "To restore everything: bash scripts/deploy-dashboard.sh"
