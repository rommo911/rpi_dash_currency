#!/usr/bin/env bash
# Generates/renews the self-signed TLS cert — a no-op unless missing/
# expiring/hostname changed. Called by deploy-dashboard.sh and auto-update.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SSL_DIR="$INSTALL_DIR/ssl"
CERT_FILE="$SSL_DIR/cert.pem"
KEY_FILE="$SSL_DIR/key.pem"
META_FILE="$SSL_DIR/cert.meta"
RENEW_BEFORE_DAYS="${RENEW_BEFORE_DAYS:-30}"
VALIDITY_DAYS="${VALIDITY_DAYS:-397}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found — install it (apt install openssl) to enable HTTPS for the admin panel." >&2
  exit 1
fi

mkdir -p "$SSL_DIR"
chmod 700 "$SSL_DIR"

CURRENT_HOSTNAME="$(hostname)"
CURRENT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || CURRENT_IP=""
CURRENT_IP="${CURRENT_IP:-127.0.0.1}"

needs_generate=false
reason=""

if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
  needs_generate=true
  reason="no certificate present yet"
elif ! openssl x509 -checkend "$((RENEW_BEFORE_DAYS * 86400))" -noout -in "$CERT_FILE" >/dev/null 2>&1; then
  needs_generate=true
  reason="expiring within ${RENEW_BEFORE_DAYS} days"
elif [[ -f "$META_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$META_FILE"
  if [[ "${CERT_HOSTNAME:-}" != "$CURRENT_HOSTNAME" || "${CERT_IP:-}" != "$CURRENT_IP" ]]; then
    needs_generate=true
    reason="hostname/IP changed (was ${CERT_HOSTNAME:-?}/${CERT_IP:-?}, now $CURRENT_HOSTNAME/$CURRENT_IP)"
  fi
else
  # Cert exists but no metadata (e.g. upgraded from an older version of
  # this script) — regenerate once so the SAN list and metadata line up.
  needs_generate=true
  reason="no metadata recorded for the existing certificate"
fi

if [[ "$needs_generate" != true ]]; then
  log_info "Certificate for $CURRENT_HOSTNAME ($CURRENT_IP) is still valid — nothing to do."
  exit 0
fi

log_info "Generating certificate for $CURRENT_HOSTNAME ($CURRENT_IP) — $reason"

SAN="DNS:${CURRENT_HOSTNAME},DNS:${CURRENT_HOSTNAME}.local,DNS:localhost,IP:${CURRENT_IP},IP:127.0.0.1"

TMP_KEY="$SSL_DIR/key.pem.new"
TMP_CERT="$SSL_DIR/cert.pem.new"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$TMP_KEY" -out "$TMP_CERT" \
  -days "$VALIDITY_DAYS" \
  -subj "/CN=${CURRENT_HOSTNAME}" \
  -addext "subjectAltName=${SAN}" \
  >/dev/null 2>&1

chmod 600 "$TMP_KEY"
mv "$TMP_KEY" "$KEY_FILE"
mv "$TMP_CERT" "$CERT_FILE"

cat > "$META_FILE" <<EOF
CERT_HOSTNAME="$CURRENT_HOSTNAME"
CERT_IP="$CURRENT_IP"
CERT_GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

log_info "Regenerated certificate for $CURRENT_HOSTNAME ($CURRENT_IP), valid $VALIDITY_DAYS days (SAN: $SAN)"
