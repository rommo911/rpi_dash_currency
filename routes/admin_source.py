"""Admin routes for the data source: manual vs. remote URL."""
from flask import redirect, request, url_for

from core import app
from helpers import remote
from helpers.security import check_csrf, require_admin_auth
from helpers.storage import load_data
from helpers.validation import clean_text
from i18n import get_translations


def _back(ok=True, msg=""):
    return redirect(url_for("admin_page", **({"msg": msg} if ok else {"error": msg})))


@app.route("/admin/source", methods=["POST"])
def admin_source():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    _, t = get_translations(load_data())
    if not check_csrf():
        return _back(False, t["err_csrf"])

    action = request.form.get("action", "save")
    mode = "url" if request.form.get("mode") == "url" else "manual"
    if action == "switch":
        # Radio clicked: swap in that mode's last known data right away (no URL
        # validation, no fetch — the poller / Fetch button refreshes URL data).
        remote.switch_mode(mode)
        return _back(True, t["source_switched"])
    saved = remote.get_source()
    cand = dict(saved)
    if mode == "manual":
        # The URL/token/insecure/Test/Fetch controls are disabled in manual
        # mode (so not submitted): keep the saved remote settings untouched.
        return _finish(mode, cand, "save", t)
    cand["url"] = (clean_text(request.form.get("url"), 300) or "").strip()
    cand["insecure"] = "insecure" in request.form
    if "clear_token" in request.form:
        cand["token"] = ""
    else:
        # Blank field means "keep the saved token".
        cand["token"] = (request.form.get("token") or "").strip() or saved["token"]
    if len(cand["token"]) > 300 or any(ord(c) < 33 for c in cand["token"]):
        return _back(False, t["err_source_token"])

    return _finish(mode, cand, action, t)


def _finish(mode, cand, action, t):
    if action == "test":
        ok, msg = remote.sync(apply=False, src=cand)
        return _back(ok, f"{t['source_test_ok' if ok else 'source_test_fail']}: {msg}")

    if mode == "url":
        err = remote.check_url(cand["url"], cand["insecure"])
        if err:
            return _back(False, f"{t['err_source_url']} ({err})")

    with remote._lock:
        remote.switch_mode(mode)  # restores that mode's last known data
        src = remote.get_source()
        src.update(url=cand["url"], token=cand["token"], insecure=cand["insecure"])
        remote.save_source(src)
        if mode == "url":
            ok, msg = remote.sync(force=(action == "fetch"))
            return _back(ok, f"{t['source_saved']} — {msg}")
    return _back(True, t["source_saved"])
