#!/bin/bash
# Runs once, ~2min after boot. Root (no User=), but git/file ops drop to
# RUN_USER. Checks service+/api/data; success tags last-known-good, failure rolls back once.
set -u

INSTALL_DIR="/home/kiosk/currency-dashboard"
RUN_USER="kiosk"
SERVICE_NAME="currency-dashboard"
APP_PORT="80"

BACKUP_DIR="$INSTALL_DIR/.health-backup"
GOOD_TAG="last-known-good"
RUNTIME_FILES="data.json config.py .env net_config.json"

INSTALL_DIR="${INSTALL_DIR:-/home/kiosk/currency-dashboard}"
if [[ -f "$INSTALL_DIR/scripts/lib.sh" ]]; then
  # shellcheck disable=SC1090
  source "$INSTALL_DIR/scripts/lib.sh"
  log() {
    local msg="$*"
    case "$msg" in
      ERROR:*) log_error "${msg#ERROR: }" ;;
      WARN:*|WARNING:*) log_warn "${msg#*:* }" ;;
      DEBUG:*) log_debug "${msg#DEBUG: }" ;;
      *) log_info "$msg" ;;
    esac
  }
else
  log() { logger -t dashboard-health-check "$1"; echo "$1"; }
fi

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
  log_info "Health check passed — recording as $GOOD_TAG"
  git_as_user tag -f "$GOOD_TAG" HEAD >/dev/null 2>&1 || log_warn "Failed to tag $GOOD_TAG"
  sudo -u "$RUN_USER" mkdir -p "$BACKUP_DIR"
  local f
  for f in $RUNTIME_FILES; do
    [[ -f "$INSTALL_DIR/$f" ]] && sudo -u "$RUN_USER" cp -a "$INSTALL_DIR/$f" "$BACKUP_DIR/$f" 2>/dev/null || true
  done
}

restore_known_good() {
  if ! git_as_user rev-parse "$GOOD_TAG" >/dev/null 2>&1; then
    log_warn "No $GOOD_TAG tag recorded yet (first deploy?) — nothing to roll back to, leaving as-is for manual fix."
    return 1
  fi
  log_warn "Health check failed — rolling back to $GOOD_TAG"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  git_as_user reset --hard "$GOOD_TAG" >/dev/null 2>&1 || log_warn "git reset --hard $GOOD_TAG failed"
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
  log_warn "Initial post-boot health check failed"
  if restore_known_good; then
    if check_healthy; then
      log_info "Recovered after rollback to $GOOD_TAG"
    else
      log_error "Still unhealthy after rollback to $GOOD_TAG — giving up, manual intervention needed"
    fi
  fi
fi
