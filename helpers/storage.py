"""data.json / net_config.json persistence, plus the small read-only
lookups (net status, LAN IP, find-by-code) built on top of them.
"""
import copy
import json
import os
import socket
import time

from config import DATA_FILE, DEFAULT_PALETTE, NET_CONFIG_FILE, NET_STATUS_FILE, PALETTE_CHOICES
from i18n import TRANSLATIONS

DEFAULT_CURRENCIES = [
    {"code": "SYP", "name": "Syrian Pound", "symbol": "", "price": 700000, "flag": "/static/flags/sy.png", "enabled": True},
    {"code": "USD", "name": "US Dollar", "symbol": "$", "price": 1, "flag": "/static/flags/us.png", "enabled": True},
    {"code": "EUR", "name": "Euro", "symbol": "€", "price": 1, "flag": "/static/flags/eu.png", "enabled": True},
    {"code": "TRY", "name": "Turkish Lira", "symbol": "₺", "price": 1, "flag": "/static/flags/tr.png", "enabled": True},
]

ROWS = 2
# Per-row card limits live here, not config.py: config.py is a local runtime
# file that OTA updates must not depend on (an old copy would lack new names).
MIN_ROW_CURRENCIES = 2
MAX_ROW_CURRENCIES = 4


def default_rows():
    """Row 1 = today's default list (3 cards), row 2 = disabled, ready to switch on."""
    cur = [dict(c) for c in DEFAULT_CURRENCIES]
    return [
        {"enabled": True, "title": "Prices Dashboard", "subtitle": "Current prices", "currencies": cur[:3]},
        {"enabled": False, "title": "", "subtitle": "", "currencies": [cur[1], cur[2], cur[3]]},
    ]


DEFAULT_SETTINGS = {
    "title": "Prices Dashboard",
    "subtitle": "Current prices",
    "admin_language": "ar",
    "show_updated_at": True,
    "color_palette": DEFAULT_PALETTE,
    # Per-effect toggles (dashboard.css fx-* classes), default True — lets
    # a weak board drop just the expensive ones (e.g. glass blur).
    "fx_glass": True,
    "fx_scan": True,
    "fx_flash": True,
    "fx_glow": True,
}

_DEFAULT_NET_CONFIG = {"wifi": [], "ap_fallback": {"enabled": False, "ssid": "", "password": ""}}

# In-memory cache keyed by mtime — avoids re-reading data.json off the SD
# card on every 5s dashboard poll when nothing has actually changed.
_data_cache = {"mtime": None, "data": None}


def invalidate_cache():
    _data_cache.update(mtime=None, data=None)


def mirror_legacy(data):
    """Old code (and old dashboards pulling this file's shape) reads the flat
    `currencies` + settings.title/subtitle: keep them equal to the first enabled row."""
    first = next((r for r in data["rows"] if r["enabled"]), data["rows"][0])
    data["settings"]["title"] = first["title"]
    data["settings"]["subtitle"] = first["subtitle"]
    data["currencies"] = first["currencies"]


def normalize_rows(data):
    """Make data["rows"] exactly ROWS well-formed rows. Files without `rows`
    (every pre-two-row install) become row 1 = old list, row 2 = disabled.
    Returns True if anything changed."""
    before = json.dumps(data.get("rows"), sort_keys=True)
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        st = data["settings"]
        first = {"enabled": True, "title": st.get("title", ""), "subtitle": st.get("subtitle", ""),
                 "currencies": data.get("currencies") or []}
        # Row 2 starts as a disabled copy of row 1 (as many cards as fit), ready to edit.
        second = copy.deepcopy(first)
        second["enabled"] = False
        second["currencies"] = second["currencies"][:MAX_ROW_CURRENCIES]
        rows = [first, second]
    out = []
    for r in rows[:ROWS]:
        r = r if isinstance(r, dict) else {}
        out.append({"enabled": bool(r.get("enabled", False)), "title": str(r.get("title") or ""),
                    "subtitle": str(r.get("subtitle") or ""),
                    "currencies": [c for c in (r.get("currencies") or []) if isinstance(c, dict) and c.get("code")]})
    while len(out) < ROWS:
        out.append({"enabled": False, "title": "", "subtitle": "", "currencies": []})
    if not any(r["enabled"] for r in out):
        out[0]["enabled"] = True
    data["rows"] = out
    mirror_legacy(data)
    return json.dumps(out, sort_keys=True) != before


def load_data():
    if not os.path.exists(DATA_FILE):
        data = {
            "currencies": [],
            "settings": dict(DEFAULT_SETTINGS),
            "rows": default_rows(),
            "updated_at": int(time.time()),
        }
        mirror_legacy(data)
        save_data(data)
        return data

    mtime = os.path.getmtime(DATA_FILE)
    if _data_cache["data"] is not None and _data_cache["mtime"] == mtime:
        # Deep copy, never the cached object — callers mutate what they get
        # back in place before save_data(), which would poison the cache.
        return copy.deepcopy(_data_cache["data"])

    with open(DATA_FILE) as f:
        data = json.load(f)
    dirty = False
    if "currencies" not in data:
        # Migrate from the old live-conversion format: keep the previous
        # base currency's static amount as its new fixed price.
        old_base = data.get("base_currency")
        old_amount = data.get("amount", data.get("syp_amount"))
        currencies = [dict(c) for c in DEFAULT_CURRENCIES]
        if old_base and old_amount is not None:
            for c in currencies:
                if c["code"] == old_base:
                    c["price"] = old_amount
        data["currencies"] = currencies
        dirty = True
    if "settings" not in data:
        data["settings"] = dict(DEFAULT_SETTINGS)
        dirty = True
    else:
        for key, val in DEFAULT_SETTINGS.items():
            if key not in data["settings"]:
                data["settings"][key] = val
                dirty = True
    if data["settings"].get("admin_language") not in TRANSLATIONS:
        data["settings"]["admin_language"] = DEFAULT_SETTINGS["admin_language"]
        dirty = True
    if data["settings"].get("color_palette") not in PALETTE_CHOICES:
        data["settings"]["color_palette"] = DEFAULT_PALETTE
        dirty = True
    if normalize_rows(data):
        dirty = True
    if dirty:
        save_data(data)
        mtime = os.path.getmtime(DATA_FILE)
    _data_cache["mtime"] = mtime
    _data_cache["data"] = data
    return copy.deepcopy(data)


def save_data(data):
    if "rows" in data:
        mirror_legacy(data)
    data["updated_at"] = int(time.time())
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)
    # mtime has coarse resolution: two writes in one tick would look unchanged.
    _data_cache.update(mtime=None, data=None)


def load_net_config():
    """Desired Wi-Fi/hotspot state, kept separate from data.json since
    that file is loaded by public routes and this one holds plaintext PSKs."""
    if not os.path.exists(NET_CONFIG_FILE):
        return {k: (v.copy() if isinstance(v, dict) else list(v)) for k, v in _DEFAULT_NET_CONFIG.items()}
    try:
        with open(NET_CONFIG_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {k: (v.copy() if isinstance(v, dict) else list(v)) for k, v in _DEFAULT_NET_CONFIG.items()}
    cfg.setdefault("wifi", [])
    cfg.setdefault("ap_fallback", {"enabled": False, "ssid": "", "password": ""})
    return cfg


def save_net_config(cfg):
    with open(NET_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(NET_CONFIG_FILE, 0o600)


def read_net_status():
    """Best-effort read of the daemon-published status file — missing or
    corrupt just means "unavailable", never raises."""
    try:
        with open(NET_STATUS_FILE, encoding="utf-8") as f:
            status = json.load(f)
        status["available"] = True
        return status
    except (OSError, json.JSONDecodeError):
        return {"available": False}


def get_lan_ip():
    """LAN IP via a UDP "connect" (no packet sent) — just reads back which
    local address the routing table would use."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"
    finally:
        s.close()


def find_currency(data, row, code):
    """Currency `code` inside row index `row`, or None. Codes are unique per row, not across rows."""
    for c in data["rows"][row]["currencies"]:
        if c["code"] == code:
            return c
    return None
