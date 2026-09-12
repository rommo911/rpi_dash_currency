#!/usr/bin/env bash
# Auto-updater: fetch the configured branch, fast-reset to it if it's
# ahead, reinstall deps if requirements.txt changed, renew the TLS cert if
# needed, and restart the service if anything changed. Run every ~6 hours
# by the currency-dashboard-updater systemd timer (installed by
# deploy-dashboard.sh) — also safe to run by hand any time.
#
# Gated by two flag files the admin panel controls (see app.py):
#   auto-update.enabled     Presence = the "Enable automatic updates"
#                            checkbox is checked. Absent = a scheduled
#                            (timer-triggered) run is a no-op.
#   auto-update.check-now   Touched by the "Check for updates now" button,
#                            which also starts this service immediately.
#                            Its presence forces a check THIS run
#                            regardless of the enabled flag (a manual
#                            click always does something); deleted after
#                            one run either way.
#
# data.json and config.py are gitignored (data.default.json /
# config.py.example are the tracked templates deploy-dashboard.sh copies
# from on first deploy), and this script untracks them locally (git rm
# --cached, keeps the on-disk file) before every reset --hard as a
# guard for any checkout old enough to predate that change — a plain
# reset --hard silently DELETES a file that's tracked+locally-modified in
# HEAD but absent from the target commit, confirmed by testing. Don't
# track either file directly again
#
# Usage:
#   INSTALL_DIR=/path/to/repo ./auto-update.sh
#   (INSTALL_DIR defaults to this script's own repo root)

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
  log "Automatic updates are disabled in the admin panel — skipping (not a manual check-now)."
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
  # A checkout from before data.json/config.py were gitignored may still
  # have them TRACKED with local (real, live) modifications — untrack
  # them first (keeps the on-disk file untouched) so reset --hard can
  # never delete them. Confirmed by testing: reset --hard on a file that's
  # tracked+locally-modified in HEAD but absent from the target commit's
  # tree silently DELETES it outright — this is not a hypothetical.
  git rm --cached -q data.json config.py 2>/dev/null || true
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
