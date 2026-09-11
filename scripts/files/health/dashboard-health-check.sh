#!/bin/bash
# Installed at /usr/local/sbin/dashboard-health-check by deploy-dashboard.sh,
# triggered once ~2 minutes after every boot by dashboard-health-check.timer
# (OnBootSec=120, no repeat). Runs as root (no User= in its unit, same as
# wifi-ap-fallback.service/dashboard-net-apply.service) since it needs to
# restart the service and reset the git checkout; the git/file operations
# themselves drop to RUN_USER via `sudo -u` so ownership stays correct —
# same pattern dashboard-net-apply.sh already uses for wifi-ap-fallback.sh.
#
# Deliberately the cheapest useful check: service active + /api/data
# returns parseable JSON. On success, advances a `last-known-good` git tag
# to HEAD and backs up the small gitignored runtime files (data.json,
# config.py, .env, net_config.json) that aren't tracked by git at all. On
# failure, rolls back to that tag/backup ONCE, restarts, and re-checks —
# if still unhealthy after that, it stops and logs rather than looping.
# No reboot is ever triggered here; this script itself only runs once per
# boot (via the timer), so there's no extra retry-guard state needed.
set -u

INSTALL_DIR="{{INSTALL_DIR}}"
RUN_USER="{{RUN_USER}}"
SERVICE_NAME="{{SERVICE_NAME}}"
APP_PORT="{{APP_PORT}}"

BACKUP_DIR="$INSTALL_DIR/.health-backup"
GOOD_TAG="last-known-good"
RUNTIME_FILES="data.json config.py .env net_config.json"

log() { logger -t dashboard-health-check "$1"; echo "$1"; }

git_as_user() {
  sudo -u "$RUN_USER" git -C "$INSTALL_DIR" "$@"
}

check_healthy() {
  systemctl is-active --quiet "$SERVICE_NAME" || return 1
  local body
  body="$(curl -sf --max-time 5 "http://127.0.0.1:${APP_PORT}/api/data")" || return 1
  python3 -c "import json,sys; json.loads(sys.argv[1])" "$body" >/dev/null 2>&1 || return 1
  return 0
}

save_known_good() {
  log "Health check passed — recording as $GOOD_TAG"
  git_as_user tag -f "$GOOD_TAG" HEAD >/dev/null 2>&1 || log "WARNING: failed to tag $GOOD_TAG"
  sudo -u "$RUN_USER" mkdir -p "$BACKUP_DIR"
  local f
  for f in $RUNTIME_FILES; do
    [[ -f "$INSTALL_DIR/$f" ]] && sudo -u "$RUN_USER" cp -a "$INSTALL_DIR/$f" "$BACKUP_DIR/$f" 2>/dev/null || true
  done
}

restore_known_good() {
  if ! git_as_user rev-parse "$GOOD_TAG" >/dev/null 2>&1; then
    log "No $GOOD_TAG tag recorded yet (first deploy?) — nothing to roll back to, leaving as-is for manual fix."
    return 1
  fi
  log "Health check failed — rolling back to $GOOD_TAG"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  git_as_user reset --hard "$GOOD_TAG" >/dev/null 2>&1 || log "WARNING: git reset --hard $GOOD_TAG failed"
  local f
  for f in $RUNTIME_FILES; do
    [[ -f "$BACKUP_DIR/$f" ]] && sudo -u "$RUN_USER" cp -a "$BACKUP_DIR/$f" "$INSTALL_DIR/$f" 2>/dev/null || true
  done
  systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 5
  return 0
}

if check_healthy; then
  save_known_good
else
  log "Initial post-boot health check failed"
  if restore_known_good; then
    if check_healthy; then
      log "Recovered after rollback to $GOOD_TAG"
    else
      log "ERROR: still unhealthy after rollback to $GOOD_TAG — giving up, manual intervention needed"
    fi
  fi
fi
