"""Remote-source mode: fetch, validate and apply a JSON payload from a
currency-server. Source config lives in source.json (mode 600, holds the
token). data.json is always the *active* data; on a mode switch it is
snapshotted to data.<old>.json and data.<new>.json is restored, so each mode
keeps its own last known values. Failures never touch the current data.
"""
import json
import os
import re
import shutil
import socket
import ssl
import threading
import time
import urllib.request
import uuid
from urllib.parse import urlparse

from config import (
    APP_DIR, DATA_FILE, FLAGS_DIR, MAX_CODE_LEN, MAX_NAME_LEN, MAX_PRICE_VALUE, MAX_SUBTITLE_LEN,
    MAX_SYMBOL_LEN, MAX_TITLE_LEN, PALETTE_CHOICES,
)
from helpers.storage import MAX_ROW_CURRENCIES, ROWS, invalidate_cache, load_data, save_data
from helpers.validation import clean_text, norm_price
from helpers.version import APP_VERSION_STRING

SOURCE_FILE = os.path.join(APP_DIR, "source.json")
SNAPSHOTS = {"manual": os.path.join(APP_DIR, "data.local.json"), "url": os.path.join(APP_DIR, "data.remote.json")}
SCHEMA = 1
POLL_SECONDS = 60
MAX_PAYLOAD_BYTES = 256 * 1024
MAX_FLAG_BYTES = 500 * 1024
MAX_CURRENCIES = 40
FX_KEYS = ("fx_glass", "fx_scan", "fx_flash", "fx_glow")

_lock = threading.RLock()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects: a redirect must not carry the token elsewhere."""

    def redirect_request(self, *a, **kw):
        return None


def get_source():
    src = {"mode": "manual", "url": "", "token": "", "insecure": False, "version": 0, "last_sync": 0, "last_status": ""}
    try:
        with open(SOURCE_FILE, encoding="utf-8") as f:
            src.update(json.load(f))
    except (OSError, json.JSONDecodeError):
        pass
    return src


def save_source(src):
    tmp = SOURCE_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(src, f, indent=2)
    os.replace(tmp, SOURCE_FILE)


def client_id():
    """Stable random ID for this dashboard, created once and kept in source.json.
    The server uses it to count distinct clients (hostnames aren't unique)."""
    with _lock:
        src = get_source()
        if not src.get("client_id"):
            src["client_id"] = str(uuid.uuid4())
            save_source(src)
        return src["client_id"]


def check_url(url, insecure):
    """Error string, or None if acceptable. https only unless insecure is on."""
    p = urlparse(url)
    if p.scheme not in ("http", "https") or not p.netloc:
        return "URL must start with https:// (or http:// with the insecure option)"
    if p.scheme == "http" and not insecure:
        return "plain http needs the insecure option; use https"
    return None


def _get(url, max_bytes, insecure, token="", identify=False):
    # Secure: normal certificate verification (Let's Encrypt or any trusted CA).
    # Insecure: no verification at all (self-signed certs, plain http).
    ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), _NoRedirect)
    headers = {"User-Agent": "currency-dashboard"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if identify:
        headers["X-Client-Id"] = client_id()
        headers["X-Client-Name"] = socket.gethostname()
        headers["X-Client-Version"] = APP_VERSION_STRING
    with opener.open(urllib.request.Request(url, headers=headers), timeout=8) as resp:
        body = resp.read(max_bytes + 1)
    if len(body) > max_bytes:
        raise ValueError("response too large")
    return body


def validate_payload(obj):
    """Returns (clean_dict, None) or (None, error string)."""
    if not isinstance(obj, dict):
        return None, "payload is not a JSON object"
    if obj.get("schema") != SCHEMA:
        return None, f"unsupported schema {obj.get('schema')!r} (expected {SCHEMA})"
    version = obj.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version < 0:
        return None, "version must be a non-negative integer"
    s = obj.get("settings")
    if not isinstance(s, dict):
        return None, "settings missing"
    title = clean_text(s.get("title") if isinstance(s.get("title"), str) else None, MAX_TITLE_LEN)
    subtitle = clean_text(s.get("subtitle") if isinstance(s.get("subtitle"), str) else "", MAX_SUBTITLE_LEN)
    if not title:
        return None, "settings.title missing or too long"
    if subtitle is None:
        return None, "settings.subtitle too long"
    if s.get("color_palette") not in PALETTE_CHOICES:
        return None, f"settings.color_palette must be one of {PALETTE_CHOICES}"
    settings = {"title": title, "subtitle": subtitle, "color_palette": s["color_palette"],
                "show_updated_at": bool(s.get("show_updated_at", True))}
    for k in FX_KEYS:
        settings[k] = bool(s.get(k, True))

    rows_in = obj.get("rows")
    if rows_in is None:
        # Server without two-row support: its flat list becomes row 1, row 2 stays off.
        rows_in = [{"enabled": True, "title": title, "subtitle": subtitle, "currencies": obj.get("currencies")},
                   {"enabled": False, "title": "", "subtitle": "", "currencies": []}]
        limit = MAX_CURRENCIES
    else:
        limit = MAX_ROW_CURRENCIES
    if not isinstance(rows_in, list) or not 1 <= len(rows_in) <= ROWS:
        return None, f"rows must be a list of 1..{ROWS}"
    rows = []
    for n, r in enumerate(rows_in):
        if not isinstance(r, dict):
            return None, f"rows[{n}] is not an object"
        r_title = clean_text(r.get("title") if isinstance(r.get("title"), str) else "", MAX_TITLE_LEN)
        r_sub = clean_text(r.get("subtitle") if isinstance(r.get("subtitle"), str) else "", MAX_SUBTITLE_LEN)
        if r_title is None or r_sub is None:
            return None, f"rows[{n}] title/subtitle too long"
        currencies, err = _validate_currencies(r.get("currencies"), limit)
        if err:
            return None, f"rows[{n}]: {err}"
        rows.append({"enabled": bool(r.get("enabled", False)), "title": r_title, "subtitle": r_sub, "currencies": currencies})
    while len(rows) < ROWS:
        rows.append({"enabled": False, "title": "", "subtitle": "", "currencies": []})
    if not any(r["enabled"] for r in rows):
        rows[0]["enabled"] = True
    return {"version": version, "settings": settings, "rows": rows}, None


def _validate_currencies(cur_in, limit):
    """(list, None) or (None, error). Codes must be unique within the list."""
    if not isinstance(cur_in, list) or len(cur_in) > limit:
        return None, f"currencies must be a list (max {limit})"
    currencies, seen = [], set()
    for i, c in enumerate(cur_in):
        if not isinstance(c, dict):
            return None, f"currencies[{i}] is not an object"
        code = c.get("code")
        if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9]{1,%d}" % MAX_CODE_LEN, code):
            return None, f"currencies[{i}].code invalid"
        code = code.upper()
        if code in seen:
            return None, f"duplicate code {code}"
        seen.add(code)
        name = clean_text(c.get("name") if isinstance(c.get("name"), str) else None, MAX_NAME_LEN)
        symbol = clean_text(c.get("symbol") if isinstance(c.get("symbol"), str) else "", MAX_SYMBOL_LEN)
        if not name or symbol is None:
            return None, f"{code}: name missing/too long or symbol too long"
        price = c.get("price")
        if isinstance(price, bool) or not isinstance(price, (int, float)) or not 0 <= price <= MAX_PRICE_VALUE:
            return None, f"{code}: price must be a number 0..{MAX_PRICE_VALUE}"
        price = norm_price(price)
        flag = c.get("flag")
        if flag is not None and (not isinstance(flag, str) or urlparse(flag).scheme not in ("http", "https")):
            return None, f"{code}: flag must be an http(s) URL or null"
        currencies.append({"code": code, "name": name, "symbol": symbol, "price": price,
                           "flag_src": flag, "enabled": bool(c.get("enabled", True))})
    return currencies, None


def fetch_payload(url, token="", insecure=False):
    """(clean, None) or (None, error). Never raises."""
    err = check_url(url, insecure)
    if err:
        return None, err
    try:
        obj = json.loads(_get(url, MAX_PAYLOAD_BYTES, insecure, token, identify=True))
    except Exception as e:  # noqa: BLE001 - network/TLS/JSON errors all mean "fetch failed"
        return None, f"fetch failed: {e}"
    return validate_payload(obj)


def _sync_flag(code, flag_src, old, insecure):
    """Download the flag when its source changed (or file missing).
    Returns local path (or None). Falls back to the previous flag on error."""
    if not flag_src:
        return None
    path = f"/static/flags/{code.lower()}.png"
    dest = os.path.join(FLAGS_DIR, f"{code.lower()}.png")
    if old and old.get("flag_src") == flag_src and os.path.isfile(dest):
        return path
    try:
        body = _get(flag_src, MAX_FLAG_BYTES, insecure)  # no token: flags are public
        if not body.startswith(b"\x89PNG"):
            raise ValueError("not a PNG")
        with open(dest, "wb") as f:
            f.write(body)
        return path
    except Exception:  # noqa: BLE001
        return path if os.path.isfile(dest) else None


def apply_payload(clean, insecure):
    """Overwrite settings and both rows from a validated payload."""
    data = load_data()
    old_by_code = {c["code"]: c for r in data["rows"] for c in r["currencies"]}
    rows = []
    for r in clean["rows"]:
        currencies = []
        for c in r["currencies"]:
            c = dict(c)
            c["flag"] = _sync_flag(c["code"], c["flag_src"], old_by_code.get(c["code"]), insecure)
            currencies.append(c)
        rows.append({**r, "currencies": currencies})
    keep = data["settings"].get("admin_language")
    data["settings"].update(clean["settings"])
    data["settings"]["admin_language"] = keep
    data["rows"] = rows
    save_data(data)


def switch_mode(new_mode):
    """Snapshot the active data under the old mode, restore the new mode's
    last known data (if any). Returns the updated source dict."""
    with _lock:
        src = get_source()
        old_mode = src["mode"]
        if new_mode == old_mode:
            return src
        # A url-mode data.json only counts as "remote data" once a sync has succeeded.
        if os.path.isfile(DATA_FILE) and (old_mode == "manual" or src["version"] > 0):
            shutil.copyfile(DATA_FILE, SNAPSHOTS[old_mode] + ".tmp")
            os.replace(SNAPSHOTS[old_mode] + ".tmp", SNAPSHOTS[old_mode])
        snap = SNAPSHOTS[new_mode]
        if os.path.isfile(snap):
            lang = load_data()["settings"].get("admin_language")
            with open(snap, encoding="utf-8") as f:
                restored = json.load(f)
            if lang:
                restored.setdefault("settings", {})["admin_language"] = lang
            tmp = DATA_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(restored, f, indent=2)
            os.replace(tmp, DATA_FILE)
            invalidate_cache()  # written behind load_data's back
        elif new_mode == "url":
            src["version"] = 0  # nothing remote known yet: first sync must apply
        src["mode"] = new_mode
        save_source(src)
        return src


def sync(force=False, apply=True, src=None):
    """One sync attempt. Returns (ok, message). With force, applies even if
    the remote version isn't newer. `src` overrides saved settings (used by
    Test so unsaved form values can be tried without persisting)."""
    with _lock:
        client_id()  # ensure it exists (and is saved) before we read/write source.json below
        saved = get_source()
        cfg = src or saved
        clean, err = fetch_payload(cfg["url"], cfg["token"], cfg["insecure"])
        if err:
            msg = err
        elif not apply:
            return True, f"version {clean['version']}, {sum(len(r['currencies']) for r in clean['rows'])} currencies (not applied)"
        elif force or clean["version"] > saved["version"]:
            apply_payload(clean, cfg["insecure"])
            saved["version"] = clean["version"]
            msg = f"applied version {clean['version']}"
        else:
            msg = f"up to date (version {saved['version']})"
        saved["last_sync"] = int(time.time())
        saved["last_status"] = ("error: " if err else "") + msg
        save_source(saved)
        return err is None, msg


def _loop():
    while True:
        time.sleep(POLL_SECONDS)
        try:
            src = get_source()
            if src["mode"] == "url" and src["url"]:
                sync()
        except Exception:  # noqa: BLE001 - keep the poller alive no matter what
            pass


def start_poller():
    threading.Thread(target=_loop, daemon=True).start()
