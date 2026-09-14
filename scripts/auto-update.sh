#!/usr/bin/env bash
# Resets to the configured branch, reinstalls deps/cert/restarts as needed.
# Runs every ~6h via timer; gated by auto-update.enabled/.check-now flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SERVICE_NAME="${SERVICE_NAME:-currency-dashboard}"
CONFIG_FILE="$INSTALL_DIR/scripts/auto-update.conf"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

BRANCH="main"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

cd "$INSTALL_DIR"

if [[ ! -d .git ]]; then
  warn "$INSTALL_DIR is not a git checkout — nothing to update."
  exit 0
fi

ENABLED_FLAG="$INSTALL_DIR/auto-update.enabled"
CHECK_NOW_FLAG="$INSTALL_DIR/auto-update.check-now"

FORCE_RUN=false
if [[ -f "$CHECK_NOW_FLAG" ]]; then
  FORCE_RUN=true
  rm -f "$CHECK_NOW_FLAG"
fi

if [[ "$FORCE_RUN" != true && ! -f "$ENABLED_FLAG" ]]; then
  log_info "Automatic updates are disabled in the admin panel — skipping (not a manual check-now)."
  exit 0
fi

needs_restart=false

log_info "Checking for updates on branch '$BRANCH'"
git fetch origin "$BRANCH" --quiet

if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout -b "$BRANCH" "origin/$BRANCH" --quiet
elif [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  git checkout "$BRANCH" --quiet
fi

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"

if [[ "$LOCAL" != "$REMOTE" ]]; then
  log_info "Update available on $BRANCH: ${LOCAL:0:9} -> ${REMOTE:0:9}"
  REQS_BEFORE="$(git show HEAD:requirements.txt 2>/dev/null || true)"
  # Untrack data.json/config.py first (pre-gitignore checkouts) — reset
  # --hard silently DELETES a tracked+modified file absent from the target commit (confirmed by testing).
  git rm --cached -q data.json config.py 2>/dev/null || true
  git reset --hard "origin/$BRANCH" --quiet
  REQS_AFTER="$(cat requirements.txt 2>/dev/null || true)"
  if [[ "$REQS_BEFORE" != "$REQS_AFTER" && -x "$INSTALL_DIR/.venv/bin/pip" ]]; then
    log_info "requirements.txt changed — reinstalling dependencies"
    "$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt"
  fi
  needs_restart=true
else
  log_info "Already up to date ($BRANCH @ ${LOCAL:0:9})"
fi

if [[ -x "$INSTALL_DIR/scripts/generate-cert.sh" ]]; then
  CERT_OUTPUT="$(INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/generate-cert.sh" 2>&1)" || {
    log_warn "Certificate check/renewal failed: $CERT_OUTPUT"
  }
  echo "$CERT_OUTPUT"
  if grep -q "^==> Regenerated certificate" <<<"$CERT_OUTPUT"; then
    needs_restart=true
  fi
fi

if [[ "$needs_restart" == true ]]; then
  log_info "Restarting $SERVICE_NAME"
    if sudo -n systemctl restart "$SERVICE_NAME" 2>/dev/null; then
      log_info "Restarted $SERVICE_NAME"
    else
      log_warn "Could not restart $SERVICE_NAME automatically (sudoers rule missing or not passwordless)."
      log_warn "Restart it by hand: sudo systemctl restart $SERVICE_NAME"
    fi
fi
