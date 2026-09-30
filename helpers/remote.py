"""Remote-source mode: fetch, validate and apply a JSON payload from a
currency-server. State lives in data.json under "source"; the manual mode
just leaves it at mode="manual". Failures never touch the current data.
"""
import json
import os
import re
import threading
import time
import urllib.request
from urllib.parse import urlparse

from config import (
    FLAGS_DIR, MAX_CODE_LEN, MAX_NAME_LEN, MAX_PRICE_VALUE, MAX_SUBTITLE_LEN, MAX_SYMBOL_LEN,
    MAX_TITLE_LEN, PALETTE_CHOICES,
)
from helpers.storage import load_data, save_data
from helpers.validation import clean_text

SCHEMA = 1
POLL_SECONDS = 60
MAX_PAYLOAD_BYTES = 256 * 1024
MAX_FLAG_BYTES = 500 * 1024
MAX_CURRENCIES = 40
FX_KEYS = ("fx_glass", "fx_scan", "fx_flash", "fx_glow")

_lock = threading.Lock()


def get_source(data):
    src = {"mode": "manual", "url": "", "version": 0, "last_sync": 0, "last_status": ""}
    src.update(data.get("source") or {})
    return src


def _get(url, max_bytes):
    req = urllib.request.Request(url, headers={"User-Agent": "currency-dashboard"})
    with urllib.request.urlopen(req, timeout=8) as resp:
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

    cur_in = obj.get("currencies")
    if not isinstance(cur_in, list) or len(cur_in) > MAX_CURRENCIES:
        return None, f"currencies must be a list (max {MAX_CURRENCIES})"
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
        flag = c.get("flag")
        if flag is not None and (not isinstance(flag, str) or urlparse(flag).scheme not in ("http", "https")):
            return None, f"{code}: flag must be an http(s) URL or null"
        currencies.append({"code": code, "name": name, "symbol": symbol, "price": float(price),
                           "flag_src": flag, "enabled": bool(c.get("enabled", True))})
    return {"version": version, "settings": settings, "currencies": currencies}, None


def fetch_payload(url):
    """(clean, None) or (None, error). Never raises."""
    if urlparse(url).scheme not in ("http", "https") or not urlparse(url).netloc:
        return None, "URL must start with http:// or https://"
    try:
        obj = json.loads(_get(url, MAX_PAYLOAD_BYTES))
    except Exception as e:  # noqa: BLE001 - network/JSON errors all mean "fetch failed"
        return None, f"fetch failed: {e}"
    return validate_payload(obj)


def _sync_flag(code, flag_src, old):
    """Download the flag when its source changed (or file missing).
    Returns local path (or None). Falls back to the previous flag on error."""
    if not flag_src:
        return None
    path = f"/static/flags/{code.lower()}.png"
    dest = os.path.join(FLAGS_DIR, f"{code.lower()}.png")
    if old and old.get("flag_src") == flag_src and os.path.isfile(dest):
        return path
    try:
        body = _get(flag_src, MAX_FLAG_BYTES)
        if not body.startswith(b"\x89PNG"):
            raise ValueError("not a PNG")
        with open(dest, "wb") as f:
            f.write(body)
        return path
    except Exception:  # noqa: BLE001
        return path if os.path.isfile(dest) else None


def apply_payload(clean):
    """Overwrite title/settings/currencies from a validated payload."""
    data = load_data()
    old_by_code = {c["code"]: c for c in data["currencies"]}
    currencies = []
    for c in clean["currencies"]:
        c = dict(c)
        c["flag"] = _sync_flag(c["code"], c["flag_src"], old_by_code.get(c["code"]))
        currencies.append(c)
    keep = data["settings"].get("admin_language")
    data["settings"].update(clean["settings"])
    data["settings"]["admin_language"] = keep
    data["currencies"] = currencies
    src = get_source(data)
    src["version"] = clean["version"]
    data["source"] = src
    save_data(data)


def sync(force=False, apply=True):
    """One sync attempt. Returns (ok, message). With force, applies even if
    the remote version isn't newer (e.g. the server's data was reset)."""
    with _lock:
        data = load_data()
        src = get_source(data)
        clean, err = fetch_payload(src["url"])
        if err:
            msg = err
        elif not apply:
            return True, f"OK: version {clean['version']}, {len(clean['currencies'])} currencies (not applied)"
        elif clean["version"] > src["version"] or (force and clean["version"] >= 0):
            apply_payload(clean)
            msg = f"applied version {clean['version']}"
            err = None
        else:
            msg = f"up to date (version {src['version']})"
        data = load_data()
        src = get_source(data)
        src["last_sync"] = int(time.time())
        src["last_status"] = ("error: " if err else "") + msg
        data["source"] = src
        # save_data() bumps updated_at, so write the status without it when nothing changed.
        _write_source_only(data)
        return err is None, msg


def _write_source_only(data):
    from config import DATA_FILE
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)


def _loop():
    while True:
        time.sleep(POLL_SECONDS)
        try:
            src = get_source(load_data())
            if src["mode"] == "url" and src["url"]:
                sync()
        except Exception:  # noqa: BLE001 - keep the poller alive no matter what
            pass


def start_poller():
    threading.Thread(target=_loop, daemon=True).start()
