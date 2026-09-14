"""Admin auth: HTTPS redirect, security headers, login lockout, CSRF."""
import hashlib
import hmac
import secrets
import threading
import time

from flask import Response, redirect, request

import config
from config import ADMIN_LOCKOUT_WINDOW, ADMIN_MAX_FAILURES, ADMIN_PASSWORD
from logging_setup import security_log

_admin_failures_lock = threading.Lock()
_admin_failures = {}  # ip -> [failure timestamps]

# Per-process CSRF secret — no session/cookie here (plain Basic Auth), so
# a fixed HMAC over a constant string stands in for a per-session nonce.
CSRF_SECRET = secrets.token_bytes(32)


def _port_suffix(port: int, default_port: int) -> str:
    return "" if port == default_port else f":{port}"


def redirect_admin_to_https():
    # Only /admin redirects to HTTPS, and only once config.HTTPS_ENABLED
    # confirms the listener actually bound — the kiosk itself stays on HTTP.
    if config.HTTPS_ENABLED and request.path.startswith("/admin") and request.scheme != "https":
        host = request.host.split(":")[0]
        target = f"https://{host}{_port_suffix(config.HTTPS_PORT, 443)}{request.full_path}".rstrip("?")
        # 307 preserves the HTTP method/body, so a POSTed form doesn't
        # silently turn into a GET when it crosses from HTTP to HTTPS.
        return redirect(target, code=307)


def set_security_headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; "
        "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
        "frame-ancestors 'none'"
    )
    return resp


def _is_locked_out(ip):
    now = time.time()
    with _admin_failures_lock:
        attempts = [t for t in _admin_failures.get(ip, []) if now - t < ADMIN_LOCKOUT_WINDOW]
        if attempts:
            _admin_failures[ip] = attempts
        else:
            _admin_failures.pop(ip, None)
        return len(attempts) >= ADMIN_MAX_FAILURES


def _record_admin_failure(ip):
    with _admin_failures_lock:
        _admin_failures.setdefault(ip, []).append(time.time())


def require_admin_auth():
    ip = request.remote_addr or "unknown"
    if _is_locked_out(ip):
        security_log.error("Admin login locked out for %s (too many failed attempts)", ip)
        return Response(
            "Too many failed login attempts. Try again in a few minutes.",
            429,
            {"Retry-After": str(ADMIN_LOCKOUT_WINDOW)},
        )
    auth = request.authorization
    # hmac.compare_digest for constant-time comparison — auth.password is
    # attacker-controlled input compared against a real secret.
    if not auth or not hmac.compare_digest(auth.password or "", ADMIN_PASSWORD):
        _record_admin_failure(ip)
        # fail2ban tails the journal for this exact message (see
        # scripts/deploy-dashboard.sh) to ban repeat offenders.
        security_log.error("Failed admin login from %s", ip)
        return Response(
            "Authentication required.",
            401,
            {"WWW-Authenticate": 'Basic realm="Admin Panel"'},
        )
    return None


def csrf_token():
    return hmac.new(CSRF_SECRET, b"admin-csrf", hashlib.sha256).hexdigest()


def check_csrf():
    return hmac.compare_digest(request.form.get("csrf_token", ""), csrf_token())
