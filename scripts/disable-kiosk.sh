#!/usr/bin/env bash
# Maintenance mode: stops the service/updater/kiosk autostart, kills any
# running X/Chromium. Reversible via deploy-dashboard.sh (no "enable" script).

set -uo pipefail
# Not set -e: best-effort on every item, not abort-on-first-failure —
# each step is a harmless no-op if already stopped/disabled.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

SERVICE_NAME="${SERVICE_NAME:-currency-dashboard}"

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (e.g. 'dashboard'), not as root — it calls sudo where needed."
  exit 1
fi

log_info "Stopping and disabling the ${SERVICE_NAME} service"
if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  sudo systemctl disable --now "${SERVICE_NAME}" 2>&1
else
  echo "${SERVICE_NAME}.service not found — nothing to stop."
fi

log_info "Pausing the auto-updater timer"
if systemctl list-unit-files "${SERVICE_NAME}-updater.timer" >/dev/null 2>&1; then
  sudo systemctl disable --now "${SERVICE_NAME}-updater.timer" 2>&1
else
  echo "${SERVICE_NAME}-updater.timer not found — nothing to pause."
fi

log_info "Disabling kiosk auto-boot"
# Rebuilds .bash_profile with the kiosk block (ensure_block_in_file
# marker) simply omitted, rather than pattern-matching in place — the old sed approach once left a broken empty if/fi body.
if [[ -f "$HOME/.bash_profile" ]] && grep -q "# BEGIN currency-dashboard-kiosk" "$HOME/.bash_profile"; then
  ensure_block_in_file "$HOME/.bash_profile" "currency-dashboard-kiosk" --remove--
  echo "Removed the kiosk autostart block from ~/.bash_profile — kiosk will no longer auto-launch on boot."
else
  echo "No kiosk autostart block found in ~/.bash_profile — already disabled, or console+X kiosk was never configured on this board."
fi

log_info "Stopping any kiosk session currently running"
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
