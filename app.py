#!/usr/bin/env python3
"""Entrypoint: registers routes on core.app, runs HTTP(S) via werkzeug."""
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
    # / stays plain HTTP always; /admin redirects to HTTPS once bound (see
    # redirect_admin_to_https), falling back to HTTP until a cert exists.
    https_server = None
    if os.path.isfile(config.CERT_FILE) and os.path.isfile(config.KEY_FILE):
        try:
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(config.CERT_FILE, config.KEY_FILE)
            # Manual socket wrap, do_handshake_on_connect=False: the default
            # blocks accept() for everyone on one stalled client's handshake.
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
