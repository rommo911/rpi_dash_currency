"""System-level admin routes: Wi-Fi, hotspot fallback, updates, reboot.
Split from routes/admin.py since these carry a different risk profile
(can drop the admin's own connection, restart the board) than plain
currency/price edits.
"""
import os
import subprocess

from flask import redirect, render_template, request, url_for

from config import (
    AUTO_UPDATE_CHECK_NOW_FLAG, AUTO_UPDATE_ENABLED_FLAG, MAX_SSID_LEN, MAX_WIFI_PASS_LEN,
    MAX_WIFI_SLOTS, MIN_WIFI_PASS_LEN, REBOOT_REQUEST_FLAG, SERVICE_NAME,
)
from core import app
from helpers.security import check_csrf, csrf_token, require_admin_auth
from helpers.storage import load_data, load_net_config, read_net_status, save_net_config
from helpers.validation import clean_ssid, validate_wifi_password
from helpers.version import APP_COMMIT, APP_VERSION
from i18n import get_translations


@app.route("/admin/system", methods=["GET"])
def admin_system_page():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    lang, t = get_translations(data)
    net_config = load_net_config()
    net_status = read_net_status()
    wifi_slots = (net_config.get("wifi") or [])[:MAX_WIFI_SLOTS]
    # If no Wi-Fi profile has ever been saved through this panel, show
    # whatever the device is ALREADY configured with (e.g. from
    # provision-pi.sh) instead of blank fields — SSID only, since a saved
    # WPA2 secret can't be read back without privilege this app doesn't
    # have. Display only: nothing is written until the admin hits Save.
    wifi_prefilled = False
    if not wifi_slots:
        known = (net_status.get("known_ssids") or [])[:MAX_WIFI_SLOTS]
        if known:
            wifi_slots = [{"ssid": s} for s in known]
            wifi_prefilled = True
    wifi_slots = wifi_slots + [{}] * (MAX_WIFI_SLOTS - len(wifi_slots))
    return render_template(
        "admin_system.html",
        lang=lang,
        t=t,
        msg=request.args.get("msg"),
        error=request.args.get("error"),
        max_ssid_len=MAX_SSID_LEN,
        min_wifi_pass_len=MIN_WIFI_PASS_LEN,
        max_wifi_pass_len=MAX_WIFI_PASS_LEN,
        csrf_token=csrf_token(),
        app_version=APP_VERSION,
        app_commit=APP_COMMIT,
        auto_update_enabled=os.path.isfile(AUTO_UPDATE_ENABLED_FLAG),
        wifi_slots=wifi_slots,
        wifi_prefilled=wifi_prefilled,
        ap_fallback=net_config.get("ap_fallback") or {},
        net_status=net_status,
    )


@app.route("/admin/toggle-auto-update", methods=["POST"])
def admin_toggle_auto_update():
    # Auto-update enabled/disabled is a flag FILE, not a data.json field —
    # scripts/auto-update.sh checks for this file's existence directly.
    # Auto-submits on checkbox change, no separate save button.
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))
    if "auto_update_enabled" in request.form:
        open(AUTO_UPDATE_ENABLED_FLAG, "a", encoding="utf-8").close()
    else:
        try:
            os.remove(AUTO_UPDATE_ENABLED_FLAG)
        except FileNotFoundError:
            pass
    return redirect(url_for("admin_system_page"))


@app.route("/admin/check-update-now", methods=["POST"])
def admin_check_update_now():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    # Touching this flag makes auto-update.sh check unconditionally on its
    # next run and delete the flag afterward. Starting the updater service
    # directly makes that "next run" happen now instead of waiting for the
    # timer — fire-and-forget (Popen): if an update is actually applied,
    # the updater restarts this very service partway through, so nothing
    # here can safely wait on it.
    open(AUTO_UPDATE_CHECK_NOW_FLAG, "a", encoding="utf-8").close()
    try:
        subprocess.Popen(
            ["sudo", "-n", "systemctl", "start", f"{SERVICE_NAME}-updater.service"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass  # the flag file alone still guarantees a check on the next scheduled tick

    return redirect(url_for("admin_system_page", msg=t["check_now_started"]))


@app.route("/admin/wifi/save", methods=["POST"])
def admin_wifi_save():
    # No sudo/subprocess here: this only writes desired state to
    # net_config.json. The root-run dashboard-net-apply daemon polls it
    # and does the real nmcli work — see config.py's NET_CONFIG_FILE comment.
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    cfg = load_net_config()
    # Password fields are never pre-filled (same reason ADMIN_PASSWORD has
    # no edit UI: don't echo secrets back into HTML), so a blank
    # submission for an SSID that already has a saved password means
    # "leave it unchanged" — keyed by SSID so reordering slots doesn't
    # lose a password.
    old_by_ssid = {w.get("ssid"): w.get("password", "") for w in cfg.get("wifi", []) if w.get("ssid")}

    slots = []
    for i in range(1, MAX_WIFI_SLOTS + 1):
        field_label = t["wifi_slot_label"].format(n=i)
        ssid = clean_ssid(request.form.get(f"wifi_ssid_{i}"))
        if ssid is None:
            return redirect(url_for("admin_system_page", error=t["err_ssid_invalid"].format(field=field_label, max=MAX_SSID_LEN)))
        password = validate_wifi_password(request.form.get(f"wifi_password_{i}"))
        if password is None:
            return redirect(url_for("admin_system_page", error=t["err_wifi_password_len"].format(
                field=field_label, min=MIN_WIFI_PASS_LEN, max=MAX_WIFI_PASS_LEN)))
        if ssid:
            # No open networks, ever. A blank field only means "keep what
            # is stored", and only resolves for an SSID that is unchanged
            # AND already has a password on file — renaming/adding a
            # network always demands its own password.
            if not password:
                password = old_by_ssid.get(ssid) or ""
            if not password:
                return redirect(url_for("admin_system_page", error=t["err_wifi_password_required"].format(field=field_label)))
            slots.append({"ssid": ssid, "password": password})

    cfg["wifi"] = slots
    save_net_config(cfg)
    return redirect(url_for("admin_system_page", msg=t["wifi_save_started"]))


@app.route("/admin/ap/save", methods=["POST"])
def admin_ap_save():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    ssid = clean_ssid(request.form.get("ap_ssid"))
    if not ssid:
        return redirect(url_for("admin_system_page", error=t["err_ssid_invalid"].format(field=t["hotspot_ssid_ph"], max=MAX_SSID_LEN)))
    password = validate_wifi_password(request.form.get("ap_password"))
    if password is None:
        return redirect(url_for("admin_system_page", error=t["err_hotspot_password_len"].format(
            min=MIN_WIFI_PASS_LEN, max=MAX_WIFI_PASS_LEN)))

    cfg = load_net_config()
    old_ap = cfg.get("ap_fallback") or {}
    # Same never-pre-filled rule as the Wi-Fi client slots: blank means
    # "keep saved password", only while the SSID is unchanged. An open AP
    # is never written — WPA2-PSK always needs a key.
    if not password:
        if ssid == old_ap.get("ssid"):
            password = old_ap.get("password") or ""
        if not password:
            return redirect(url_for("admin_system_page", error=t["err_hotspot_password_required"]))
    if len(password) < MIN_WIFI_PASS_LEN:
        return redirect(url_for("admin_system_page", error=t["err_hotspot_password_len"].format(
            min=MIN_WIFI_PASS_LEN, max=MAX_WIFI_PASS_LEN)))
    cfg["ap_fallback"] = {"enabled": True, "ssid": ssid, "password": password}
    save_net_config(cfg)
    return redirect(url_for("admin_system_page", msg=t["hotspot_saved"]))


@app.route("/admin/ap/disable", methods=["POST"])
def admin_ap_disable():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    cfg = load_net_config()
    ap = cfg.get("ap_fallback") or {}
    ap["enabled"] = False
    cfg["ap_fallback"] = ap
    save_net_config(cfg)
    return redirect(url_for("admin_system_page", msg=t["hotspot_disabled"]))


@app.route("/admin/reboot", methods=["POST"])
def admin_reboot():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    # Touch-file idiom, same as AUTO_UPDATE_CHECK_NOW_FLAG: the root-run
    # dashboard-net-apply daemon checks for this file every ~5s and, if
    # present, removes it and calls `systemctl reboot` itself. Nothing
    # here runs as root or calls systemctl directly.
    open(REBOOT_REQUEST_FLAG, "a", encoding="utf-8").close()
    return redirect(url_for("admin_system_page", msg=t["restart_started"]))
