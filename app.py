#!/usr/bin/env python3
"""Currency dashboard entrypoint.

Registers the before/after-request hooks and route modules on the shared
`app` instance (core.py), then runs the HTTP(S) server directly via
werkzeug — no gunicorn/WSGI container. See CLAUDE.md for the module
layout (config/i18n/helpers/routes/templates/static).
"""
import os
import socket
import ssl
import threading

from werkzeug.serving import make_server

import config
from core import app
from helpers.security import _port_suffix, redirect_admin_to_https, set_security_headers

# Imported for the side effect of registering @app.route handlers on the
# shared `app` above — the names themselves are never used directly.
from routes import admin, admin_system, dashboard  # noqa: F401

app.before_request(redirect_admin_to_https)
app.after_request(set_security_headers)


if __name__ == "__main__":
    # The dashboard (/) always serves plain HTTP on APP_PORT — the kiosk
    # browser points here and must never hit a self-signed-cert warning.
    # /admin redirects to HTTPS (see redirect_admin_to_https) only once
    # the listener below is actually confirmed working; until a cert
    # exists (scripts/generate-cert.sh), admin stays on HTTP as a fallback.
    https_server = None
    if os.path.isfile(config.CERT_FILE) and os.path.isfile(config.KEY_FILE):
        try:
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(config.CERT_FILE, config.KEY_FILE)
            # No ssl_context passed to make_server() — the socket is
            # wrapped manually below with do_handshake_on_connect=False.
            # The default (do_handshake_on_connect=True) does the TLS
            # handshake synchronously inside the shared accept() call
            # before threaded=True ever hands off to a worker thread, so
            # one stalled client's handshake wedges accept() for
            # everyone — a real, reproduced bug (see NOTES). Deferring
            # the handshake to each connection's own worker thread fixes it.
            https_server = make_server("0.0.0.0", config.HTTPS_PORT, app, threaded=True)
            https_server.socket = ssl_ctx.wrap_socket(
                https_server.socket, server_side=True, do_handshake_on_connect=False
            )
            https_server.ssl_context = ssl_ctx
        except OSError as e:
            print(f"Could not start HTTPS listener on port {config.HTTPS_PORT}: {e}")

    config.HTTPS_ENABLED = https_server is not None
    if config.HTTPS_ENABLED:
        print(f"Admin panel (HTTPS): https://{socket.gethostname()}{_port_suffix(config.HTTPS_PORT, 443)}/admin")
    else:
        print(f"No usable SSL cert at {config.CERT_FILE} — admin panel served over HTTP only. Run scripts/generate-cert.sh to enable HTTPS.")

    http_server = make_server("0.0.0.0", config.APP_PORT, app, threaded=True)
    threads = [threading.Thread(target=http_server.serve_forever, daemon=True)]
    if https_server:
        threads.append(threading.Thread(target=https_server.serve_forever, daemon=True))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
