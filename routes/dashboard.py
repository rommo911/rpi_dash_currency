"""Public routes: the kiosk dashboard and its polling API. No auth."""
import socket

from flask import jsonify, render_template

from core import app
from helpers.storage import get_lan_ip, load_data
from helpers.version import APP_VERSION_STRING


@app.route("/")
def dashboard():
    data = load_data()
    return render_template("dashboard.html", settings=data["settings"], version=APP_VERSION_STRING)


@app.route("/api/data")
def api_data():
    data = load_data()
    enabled = [c for c in data["currencies"] if c.get("enabled")]
    return jsonify({
        "currencies": enabled,
        "updated_at": data.get("updated_at"),
        "title": data["settings"]["title"],
        "subtitle": data["settings"]["subtitle"],
        "show_updated_at": data["settings"]["show_updated_at"],
        "admin_language": data["settings"]["admin_language"],
        "color_palette": data["settings"]["color_palette"],
        "hostname": socket.gethostname(),
        "ip": get_lan_ip(),
        "app_version": APP_VERSION_STRING,
    })
