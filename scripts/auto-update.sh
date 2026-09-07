#!/usr/bin/env bash
# Auto-updater: fetch the configured branch, fast-reset to it if it's
# ahead, reinstall deps if requirements.txt changed, renew the TLS cert if
# needed, and restart the service if anything changed. Run every ~2 hours
# by the currency-dashboard-updater systemd timer (installed by
# deploy-dashboard.sh) — also safe to run by hand any time.
#
# data.json and config.py are gitignored and were never committed as
# themselves (data.default.json / config.py.example are the tracked
# templates deploy-dashboard.sh copies from on first deploy) — so
# `git reset --hard` here can never touch them, at all, under any
# circumstance. Don't track either file directly again; see CLAUDE.md.
#
# Usage:
#   INSTALL_DIR=/path/to/repo ./auto-update.sh
#   (INSTALL_DIR defaults to this script's own repo root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SERVICE_NAME="${SERVICE_NAME:-currency-dashboard}"
CONFIG_FILE="$INSTALL_DIR/scripts/auto-update.conf"

log()  { echo -e "\033[1;36m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

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

needs_restart=false

log "Checking for updates on branch '$BRANCH'"
git fetch origin "$BRANCH" --quiet

if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout -b "$BRANCH" "origin/$BRANCH" --quiet
elif [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  git checkout "$BRANCH" --quiet
fi

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"

if [[ "$LOCAL" != "$REMOTE" ]]; then
  log "Update available on $BRANCH: ${LOCAL:0:9} -> ${REMOTE:0:9}"
  REQS_BEFORE="$(git show HEAD:requirements.txt 2>/dev/null || true)"
  # --skip-worktree on data.json/config.py (set at deploy time) means this
  # never touches either file's on-disk content, no matter what changed
  # upstream.
  git reset --hard "origin/$BRANCH" --quiet
  REQS_AFTER="$(cat requirements.txt 2>/dev/null || true)"
  if [[ "$REQS_BEFORE" != "$REQS_AFTER" && -x "$INSTALL_DIR/.venv/bin/pip" ]]; then
    log "requirements.txt changed — reinstalling dependencies"
    "$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt"
  fi
  needs_restart=true
else
  log "Already up to date ($BRANCH @ ${LOCAL:0:9})"
fi

if [[ -x "$INSTALL_DIR/scripts/generate-cert.sh" ]]; then
  CERT_OUTPUT="$(INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/generate-cert.sh" 2>&1)" || {
    warn "Certificate check/renewal failed:"
    warn "$CERT_OUTPUT"
  }
  echo "$CERT_OUTPUT"
  if grep -q "^==> Regenerated certificate" <<<"$CERT_OUTPUT"; then
    needs_restart=true
  fi
fi

if [[ "$needs_restart" == true ]]; then
  log "Restarting $SERVICE_NAME"
  if sudo -n systemctl restart "$SERVICE_NAME" 2>/dev/null; then
    log "Restarted $SERVICE_NAME"
  else
    warn "Could not restart $SERVICE_NAME automatically (sudoers rule missing or not passwordless)."
    warn "Restart it by hand: sudo systemctl restart $SERVICE_NAME"
  fi
fi
