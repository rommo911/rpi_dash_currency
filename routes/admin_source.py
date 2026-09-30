"""Admin routes for the data source: manual vs. remote URL."""
from urllib.parse import urlparse

from flask import redirect, request, url_for

from core import app
from helpers import remote
from helpers.security import check_csrf, require_admin_auth
from helpers.storage import load_data, save_data
from helpers.validation import clean_text
from i18n import get_translations


def _back(**kw):
    return redirect(url_for("admin_page", **kw))


@app.route("/admin/source", methods=["POST"])
def admin_source():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return _back(error=t["err_csrf"])

    action = request.form.get("action", "save")
    mode = request.form.get("mode", "manual")
    url = (clean_text(request.form.get("url"), 300) or "").strip()
    if mode == "url":
        p = urlparse(url)
        if p.scheme not in ("http", "https") or not p.netloc:
            return _back(error=t["err_source_url"])

    src = remote.get_source(data)
    src["mode"] = "url" if mode == "url" else "manual"
    src["url"] = url
    data["source"] = src
    # Raw write: saving the source config alone must not bump the data's updated_at.
    remote._write_source_only(data)

    if action == "test":
        ok, msg = remote.sync(apply=False)
        return _back(**({"msg": f"{t['source_test_ok']}: {msg}"} if ok else {"error": f"{t['source_test_fail']}: {msg}"}))
    if action == "fetch":
        ok, msg = remote.sync(force=True)
        return _back(**({"msg": msg} if ok else {"error": msg}))
    if src["mode"] == "url":
        ok, msg = remote.sync()
        return _back(**({"msg": f"{t['source_saved']} — {msg}"} if ok else {"error": f"{t['source_saved']} — {msg}"}))
    return _back(msg=t["source_saved"])
