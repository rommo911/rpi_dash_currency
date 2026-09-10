#!/usr/bin/env python3
"""Currency dashboard: a static, admin-managed price per currency — no live
conversion, no external API calls at runtime.

Single-file Flask app: dashboard at /, password-protected control panel at
/admin. Admin can add/remove/enable/disable currencies and set each one's
price by hand. Flag icons are stored locally under static/flags/ — either
auto-fetched once from flagcdn.com by guessing the ISO country code from the
currency code, or uploaded by the admin. Everything persists to data.json.
"""
import hashlib
import hmac
import json
import logging
from logging.handlers import TimedRotatingFileHandler
import math
import os
import re
import secrets
import socket
import ssl
import subprocess
import threading
import time
import unicodedata
import urllib.request

from flask import Flask, Response, jsonify, redirect, render_template_string, request, url_for
from werkzeug.serving import make_server
from werkzeug.utils import secure_filename

APP_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(APP_DIR, "data.json")
FLAGS_DIR = os.path.join(APP_DIR, "static", "flags")
SSL_DIR = os.path.join(APP_DIR, "ssl")
CERT_FILE = os.path.join(SSL_DIR, "cert.pem")
KEY_FILE = os.path.join(SSL_DIR, "key.pem")
LOG_DIR = os.path.join(APP_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, "app.log")
VERSION_FILE = os.path.join(APP_DIR, "VERSION")
ALLOWED_FLAG_EXTS = {"png", "jpg", "jpeg"}

# Auto-update control: scripts/auto-update.sh (run every 6h by a systemd
# timer) checks these two flag files before doing any git/network work.
# AUTO_UPDATE_ENABLED_FLAG's presence is the admin-panel "Enable automatic
# updates" checkbox (admin_save_all() touches/removes it); its absence
# means the scheduled run is a no-op. AUTO_UPDATE_CHECK_NOW_FLAG is a
# one-shot override — the "Check for updates now" button touches it and
# also starts the updater service immediately (via sudo, see
# deploy-dashboard.sh's sudoers rule) instead of waiting for the next
# scheduled tick; the script deletes it after one run regardless of the
# enabled flag, so a manual check always happens once.
AUTO_UPDATE_ENABLED_FLAG = os.path.join(APP_DIR, "auto-update.enabled")
AUTO_UPDATE_CHECK_NOW_FLAG = os.path.join(APP_DIR, "auto-update.check-now")
SERVICE_NAME = "currency-dashboard"


def _read_version():
    try:
        with open(VERSION_FILE, encoding="utf-8") as f:
            return f.read().strip() or "unknown"
    except OSError:
        return "unknown"


def _read_git_commit():
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=APP_DIR, capture_output=True, text=True, timeout=3, check=False,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


APP_VERSION = _read_version()
APP_COMMIT = _read_git_commit()

APP_PORT = int(os.environ.get("APP_PORT", "5000"))
HTTPS_PORT = int(os.environ.get("HTTPS_PORT", "5443"))
# The admin password must come from the process environment. The deployment
# scripts load it from the project-local .env file before starting the app.
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
if not ADMIN_PASSWORD:
  raise RuntimeError("ADMIN_PASSWORD is not set; configure the project .env file before starting the app")
# Best-effort default based on file presence; refined in __main__ once we've
# actually confirmed the HTTPS listener can bind and load the cert.
HTTPS_ENABLED = os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE)

# In-memory admin login lockout: N failures from one IP within WINDOW seconds
# blocks further attempts from that IP until the window rolls past them.
# Resets on process restart — acceptable for a single-instance Pi app.
# fail2ban (scripts/deploy-dashboard.sh installs a jail watching the log
# line emitted below) provides the firewall-level backstop for this.
ADMIN_MAX_FAILURES = 3
ADMIN_LOCKOUT_WINDOW = 300  # seconds
_admin_failures_lock = threading.Lock()
_admin_failures = {}  # ip -> [failure timestamps]

# Logging: errors only, everywhere, on purpose (matches the system-wide
# journald policy provision-pi.sh sets up — see CLAUDE.md). Two pieces:
#  - The root logger (and "werkzeug" specifically, which otherwise logs
#    every single request at INFO — that's the noisy "GET /api/data ...
#    200 -" line) is capped at ERROR, so routine traffic never gets logged
#    at all, only real problems.
#  - security_log ("admin-auth") logs failed-login/lockout events via
#    .error() (not .warning()) — deliberately: journald's MaxLevelStore=err
#    (see provision-pi.sh) drops anything below error from being *stored*
#    at all, and the fail2ban jail depends on this exact message reaching
#    the journal. A failed admin login is a legitimate error-level event
#    anyway, not just informational, so this isn't a stretch — but don't
#    downgrade it back to .warning() without also loosening MaxLevelStore,
#    or fail2ban silently stops seeing anything.
# A dedicated rotating file (logs/app.log, ERROR+, 7 daily backups = 1
# week) captures the same errors independently of whatever the system
# journal is doing, since journald's retention is a system-wide policy
# and rotation here is this app's own, explicit guarantee.
logging.basicConfig(level=logging.ERROR, format="%(asctime)s %(message)s")
logging.getLogger("werkzeug").setLevel(logging.ERROR)

os.makedirs(LOG_DIR, exist_ok=True)
_file_handler = TimedRotatingFileHandler(LOG_FILE, when="midnight", backupCount=7, encoding="utf-8")
_file_handler.setLevel(logging.ERROR)
_file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
logging.getLogger().addHandler(_file_handler)

security_log = logging.getLogger("admin-auth")
security_log.setLevel(logging.ERROR)

# Per-process secret for the CSRF synchronizer token. The admin panel has no
# session/cookie (plain HTTP Basic Auth), so the token is a fixed HMAC over a
# constant string rather than a per-session nonce — it stays valid for the
# life of the process, which is fine since its only job is to be unguessable
# to a cross-origin page (the Same-Origin Policy already stops such a page
# from reading it out of a fetched admin page).
CSRF_SECRET = secrets.token_bytes(32)

# Length limits are in *characters* (Python strings are code points, so this
# is fair to Arabic too — combining marks aside, a name like "الليرة
# السورية الجديدة" is ~24 characters, well under any of these caps).
MAX_TITLE_LEN = 80
MAX_SUBTITLE_LEN = 140
MAX_NAME_LEN = 25
MAX_SYMBOL_LEN = 3
MAX_CODE_LEN = 5
MAX_PRICE_RAW_LEN = 8
MAX_PRICE_VALUE = 1_000_000  # 1e12 — comfortably above any real price, guards against typos/overflow

# ISO-4217 currency code -> ISO-3166 country code, for currencies where the
# "first two letters" heuristic doesn't hold. Extend as needed.
COUNTRY_OVERRIDES = {
    "EUR": "eu",
    "XOF": "sn",  # West African CFA franc - no single flag, default to a member state
    "XAF": "cm",  # Central African CFA franc - same idea
}

DEFAULT_CURRENCIES = [
    {"code": "SYP", "name": "Syrian Pound", "symbol": "", "price": 700000, "flag": "/static/flags/sy.png", "enabled": True},
    {"code": "USD", "name": "US Dollar", "symbol": "$", "price": 1, "flag": "/static/flags/us.png", "enabled": True},
    {"code": "EUR", "name": "Euro", "symbol": "€", "price": 1, "flag": "/static/flags/eu.png", "enabled": True},
    {"code": "TRY", "name": "Turkish Lira", "symbol": "₺", "price": 1, "flag": "/static/flags/tr.png", "enabled": True},
]

DEFAULT_SETTINGS = {
    "title": "Currency Dashboard",
    "subtitle": "Current prices",
    "admin_language": "en",
    "show_updated_at": True,
}

# Admin-panel UI strings only. Currency data (names, dashboard title/subtitle)
# is whatever the admin typed and is never auto-translated.
TRANSLATIONS = {
    "en": {
        "panel_title": "Control Panel",
        "panel_sub": "Set each currency's price directly. Enable/disable which ones show on the dashboard. Add or remove currencies below.",
        "settings_heading": "Dashboard settings",
        "field_title": "Dashboard title",
        "field_subtitle": "Dashboard subtitle",
        "field_language": "Admin panel language",
        "show_updated_label": "Show \"last updated\" time on dashboard",
        "save_settings": "Save settings",
        "name_ph": "Name",
        "symbol_ph": "Symbol",
        "price_ph": "Price",
        "enabled_label": "Enabled",
        "save_btn": "Save",
        "remove_btn": "Remove",
        "add_heading": "Add a currency",
        "code_ph": "Code (e.g. GBP)",
        "name_req_ph": "Name",
        "symbol_opt_ph": "Symbol (optional)",
        "price_req_ph": "Price",
        "flag_auto": "Auto-suggest flag from code",
        "flag_upload": "Upload image",
        "add_btn": "Add currency",
        "back_link": "← Back to dashboard",
        "updated_suffix": " updated",
        "removed_suffix": " removed",
        "added_suffix": " added",
        "settings_saved": "Settings saved",
        "confirm_remove": "Remove {code}?",
        "err_title_required": "Title is required",
        "err_too_long": "{field} is too long (max {max} characters)",
        "err_invalid_price": "Price for {code} must be a number between 0 and {max}",
        "err_missing_fields": "Name and price are required for {code}",
        "err_invalid_code": "Code must be 1–8 letters or numbers",
        "err_code_required": "Code and name are required",
        "err_code_exists": "{code} already exists",
        "err_unsupported_image": "Unsupported image file — use png/jpg/webp/svg",
        "err_flag_fetch_failed": "Couldn't auto-suggest a flag for {code} (no internet, or no match) — add it again and upload an image instead",
        "err_not_found": "Currency {code} not found",
        "err_csrf": "Session expired — please try again.",
        "updates_heading": "Updates",
        "version_label": "Version",
        "auto_update_label": "Enable automatic updates (checks every 6 hours)",
        "check_now_btn": "Check for updates now",
        "check_now_started": "Update check started — this page may briefly stop responding if an update is applied. Refresh in about 30 seconds.",
    },
    "ar": {
        "panel_title": "لوحة التحكم",
        "panel_sub": "حدد سعر كل عملة يدويًا. فعّل أو عطّل العملات التي تظهر في لوحة العرض. أضف أو احذف عملات أدناه.",
        "settings_heading": "إعدادات لوحة العرض",
        "field_title": "عنوان لوحة العرض",
        "field_subtitle": "العنوان الفرعي",
        "field_language": "لغة لوحة التحكم",
        "show_updated_label": "إظهار وقت آخر تحديث في لوحة العرض",
        "save_settings": "حفظ الإعدادات",
        "name_ph": "الاسم",
        "symbol_ph": "الرمز",
        "price_ph": "السعر",
        "enabled_label": "مُفعّل",
        "save_btn": "حفظ",
        "remove_btn": "حذف",
        "add_heading": "إضافة عملة",
        "code_ph": "الرمز (USD)",
        "name_req_ph": "اسم العملة",
        "symbol_opt_ph": " ($) محرف اختياري",
        "price_req_ph": "السعر",
        "flag_auto": "اقتراح العلم تلقائيًا حسب الرمز",
        "flag_upload": "رفع صورة",
        "add_btn": "إضافة العملة",
        "back_link": "العودة إلى لوحة العرض →",
        "updated_suffix": " تم تحديثها",
        "removed_suffix": " تم حذفها",
        "added_suffix": " تمت إضافتها",
        "settings_saved": "تم حفظ الإعدادات",
        "confirm_remove": "حذف {code}؟",
        "err_title_required": "العنوان مطلوب",
        "err_too_long": "{field} طويل جدًا (الحد الأقصى {max} حرفًا)",
        "err_invalid_price": "يجب أن يكون سعر {code} رقمًا بين 0 و {max}",
        "err_missing_fields": "الاسم والسعر مطلوبان لـ {code}",
        "err_invalid_code": "يجب أن يتكون الرمز من 1 إلى 8 أحرف أو أرقام",
        "err_code_required": "الرمز والاسم مطلوبان",
        "err_code_exists": "{code} موجود بالفعل",
        "err_unsupported_image": "صيغة صورة غير مدعومة — استخدم png/jpg/webp/svg",
        "err_flag_fetch_failed": "تعذّر اقتراح علم لـ {code} (لا يوجد اتصال بالإنترنت أو لا تطابق) — أضفه مرة أخرى وارفع صورة بدلاً من ذلك",
        "err_not_found": "العملة {code} غير موجودة",
        "err_csrf": "انتهت الجلسة — يرجى المحاولة مرة أخرى.",
        "updates_heading": "التحديثات",
        "version_label": "الإصدار",
        "auto_update_label": "تفعيل التحديثات التلقائية (تحقق كل 6 ساعات)",
        "check_now_btn": "التحقق من التحديثات الآن",
        "check_now_started": "بدأ التحقق من التحديث — قد تتوقف هذه الصفحة عن الاستجابة لفترة وجيزة إذا تم تطبيق تحديث. حدّث الصفحة بعد حوالي 30 ثانية.",
    },
}

app = Flask(__name__)
os.makedirs(FLAGS_DIR, exist_ok=True)


@app.before_request
def redirect_admin_to_https():
    # The public dashboard (/, /api/data, /static/*) stays on plain HTTP so
    # the kiosk browser never has to deal with a self-signed cert — only
    # /admin gets pushed onto HTTPS, and only once the HTTPS listener is
    # actually confirmed up (HTTPS_ENABLED, set for real once __main__ has
    # successfully bound it — see bottom of this file).
    if HTTPS_ENABLED and request.path.startswith("/admin") and request.scheme != "https":
        host = request.host.split(":")[0]
        target = f"https://{host}:{HTTPS_PORT}{request.full_path}".rstrip("?")
        # 307 preserves the HTTP method/body, so a POSTed form doesn't
        # silently turn into a GET when it crosses from HTTP to HTTPS.
        return redirect(target, code=307)


@app.after_request
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


# --------------------------------------------------------------------------
# Persistence
# --------------------------------------------------------------------------

def load_data():
    if not os.path.exists(DATA_FILE):
        data = {
            "currencies": DEFAULT_CURRENCIES,
            "settings": dict(DEFAULT_SETTINGS),
            "updated_at": int(time.time()),
        }
        save_data(data)
        return data
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
    if dirty:
        save_data(data)
    return data


def save_data(data):
    data["updated_at"] = int(time.time())
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)


def get_lan_ip():
    """Best-effort LAN IP for the on-screen overlay: opens a UDP socket
    "connected" to a public address (no packet actually sent for UDP
    connect — it just picks the outbound route) and reads back the local
    address that route would use."""
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


def find_currency(data, code):
    for c in data["currencies"]:
        if c["code"] == code:
            return c
    return None


def get_translations(data):
    lang = data.get("settings", {}).get("admin_language", "en")
    return lang, TRANSLATIONS.get(lang, TRANSLATIONS["en"])


# --------------------------------------------------------------------------
# Input validation
# --------------------------------------------------------------------------

def clean_text(raw, max_len):
    """Strip control/newline characters (keeps normal spaces, Arabic and
    other scripts intact), collapse whitespace, and cap length by character
    count. Returns None if the result is longer than max_len — the caller
    decides how to report that rather than silently truncating a mistake."""
    if raw is None:
        return ""
    # Drop Unicode control characters (category "C*") except plain spaces —
    # this catches stray NULs/newlines/tabs from copy-paste without
    # rejecting legitimate Arabic/other-script text.
    cleaned = "".join(ch for ch in raw if ch == " " or unicodedata.category(ch)[0] != "C")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if len(cleaned) > max_len:
        return None
    return cleaned


def parse_price(raw):
    """Parse a price string with sane bounds. Returns a float, or None if
    the input isn't a valid, finite, non-negative, reasonably-sized number
    (guards against "inf"/"nan", absurdly long digit strings, negative
    values, and fat-fingered huge numbers)."""
    if raw is None:
        return None
    raw = raw.strip()
    if not raw or len(raw) > MAX_PRICE_RAW_LEN:
        return None
    if not re.fullmatch(r"-?\d*\.?\d+(?:[eE][+-]?\d+)?", raw):
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    if not math.isfinite(value) or value < 0 or value > MAX_PRICE_VALUE:
        return None
    return value


# --------------------------------------------------------------------------
# Flag handling
# --------------------------------------------------------------------------

def guess_country_code(currency_code):
    return COUNTRY_OVERRIDES.get(currency_code, currency_code[:2].lower())


def fetch_suggested_flag(currency_code):
    """Try to download a flag PNG for this currency code. Returns the
    web path on success, or None on failure (caller should ask for an
    upload instead)."""
    cc = guess_country_code(currency_code)
    url = f"https://flagcdn.com/w320/{cc}.png"
    dest_name = f"{currency_code.lower()}.png"
    dest_path = os.path.join(FLAGS_DIR, dest_name)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "currency-dashboard"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            content = resp.read()
        if not content.startswith(b"\x89PNG"):
            return None
        with open(dest_path, "wb") as f:
            f.write(content)
        return f"/static/flags/{dest_name}"
    except Exception:  # noqa: BLE001 - network/DNS/HTTP errors all mean "no suggestion"
        return None


def save_uploaded_flag(currency_code, file_storage):
    filename = secure_filename(file_storage.filename or "")
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext not in ALLOWED_FLAG_EXTS:
        return None
    dest_name = f"{currency_code.lower()}.{ext}"
    dest_path = os.path.join(FLAGS_DIR, dest_name)
    file_storage.save(dest_path)
    return f"/static/flags/{dest_name}"


def delete_flag_file(flag_path):
    if not flag_path or not flag_path.startswith("/static/flags/"):
        return
    real_path = os.path.join(APP_DIR, flag_path.lstrip("/"))
    real_path = os.path.abspath(real_path)
    if os.path.commonpath([real_path, FLAGS_DIR]) == FLAGS_DIR and os.path.isfile(real_path):
        try:
            os.remove(real_path)
        except OSError:
            pass


# --------------------------------------------------------------------------
# Auth
# --------------------------------------------------------------------------

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
    # hmac.compare_digest for a constant-time comparison — auth.password is
    # attacker-controlled input compared against a real secret.
    if not auth or not hmac.compare_digest(auth.password or "", ADMIN_PASSWORD):
        _record_admin_failure(ip)
        # fail2ban (see scripts/deploy-dashboard.sh) tails the journal for
        # this exact message to ban repeat offenders at the firewall level.
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


# --------------------------------------------------------------------------
# Templates
# --------------------------------------------------------------------------

DASHBOARD_HTML = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Currency Dashboard</title>
<style>
  :root {
    --bg-1: #0f172a;
    --bg-2: #1e1b4b;
    --card-bg: rgba(255, 255, 255, 0.06);
    --card-border: rgba(255, 255, 255, 0.12);
    --text-main: #f8fafc;
    --text-dim: #94a3b8;
    --accent: #22d3ee;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(circle at 20% 20%, var(--bg-2), var(--bg-1) 60%);
    color: var(--text-main);
    overflow: hidden;
  }
  /* Screen is inset 5% on every side from the viewport edges — that 5%
     margin is the only space not used by the header or the price grid. */
  .screen {
    position: fixed;
    top: 5vh; bottom: 5vh; left: 5vw; right: 5vw;
    display: flex;
    flex-direction: column;
  }
  /* Fixed 15% of the full screen height, regardless of how much text the
     title/subtitle hold — long text shrinks via clamp() rather than
     growing this band. */
  .header {
    flex: 0 0 10vh;
    height: 10vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    overflow: hidden;
  }
  .header h1 {
    margin: 0;
    font-weight: 800;
    letter-spacing: -0.02em;
    font-size: clamp(2rem, 6vh, 5rem);
    line-height: 1.05;
  }
  .header .sub {
    color: var(--text-dim);
    font-size: clamp(1.1rem, 2.5vh, 2.2rem);
    margin-top: 0.6vh;
    line-height: 1.1;
  }
  /* Everything left after the header fills with the price grid. */
  #grid-wrap {
    margin-top: 4vh;
    margin-bottom: 2vh;
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
  }
  .grid {
    display: grid;
    width: 100%;
    height: 100%;
    gap: 6vh 2vw;
  }
  .empty {
    margin: auto;
    text-align: center;
    color: var(--text-dim);
    font-size: clamp(1.2rem, 3vh, 2rem);
    padding: 5%;
    border: 1px dashed var(--card-border);
    border-radius: 24px;
  }
  .card {
    background: var(--card-bg);
    border: 4px solid var(--card-border);
    border-radius: 1.9vh;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: var(--card-gap, 19px);
    overflow: hidden;
    padding: var(--card-pad, 19px);
    min-width: 0;
    min-height: 0;
  }
  .icon-badge {
    width: var(--icon-w, 90%);
    height: var(--icon-h, auto);
    aspect-ratio: 3 / 2;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 8px 24px -8px rgba(0,0,0,0.5), 0 0 0 1px var(--card-border);
    background: rgba(255,255,255,0.05);
    flex-shrink: 0;
  }
  .icon-badge img { width: 100%; height: 100%; object-fit: fill; display: block; }
  .card .code {
    font-size: var(--code-size, 1.8rem);
    width: 50%;
    color: var(--text-main);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    font-weight: 900;
    line-height: 1;
  }
  .card .name {
    font-size: var(--name-size, 1.6rem);
    color: var(--text-dim);
    line-height: 1.9;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* The price itself is the biggest thing on a card — bigger than the
     currency code, which is bigger than the currency name. */
  .card .value {
    font-size: var(--value-size, 3rem);
    width: 100%;
    font-weight: 700;
    letter-spacing: -0.01em;
    color: var(--accent);
    line-height: 1;
    max-width: 100%;
    overflow: visible;
    text-overflow: clip;
    white-space: nowrap;
  }
  /* Lives in the reserved bottom 5% margin rather than stealing height
     from the price grid. */
  .footer {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    margin-top: 0.6vh;
    text-align: center;
    color: var(--text-dim);
    font-size: clamp(0.8rem, 1.4vh, 1.1rem);
  }
  .hostinfo {
    position: fixed;
    left: 16px;
    bottom: 14px;
    font-size: 0.85rem;
    color: var(--text-dim);
    background: rgba(0, 0, 0, 0.35);
    padding: 6px 12px;
    border-radius: 8px;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.6s ease;
  }
  .hostinfo.show { opacity: 1; }
</style>
</head>
<body>
<div class="screen">
  <div class="header">
    <h1 id="dash-title">{{ settings.title }}</h1>
    <div class="sub" id="dash-subtitle">{{ settings.subtitle }}</div>
  </div>

  <div id="grid-wrap"></div>

  <div class="footer" id="footer" {% if not settings.show_updated_at %}hidden{% endif %}><div id="updated-at">Loading&hellip;</div></div>
</div>
<div class="hostinfo" id="hostinfo"></div>

<script>
const MAX_DISPLAYED_CURRENCIES = 5;
let lastUpdatedAt = null;
let lastCount = 0;
let lastHostInfo = { hostname: '', ip: '' };

let hostInfoShown = false;

function showHostInfo() {
  if (hostInfoShown) return;
  const el = document.getElementById('hostinfo');
  if (!lastHostInfo.hostname && !lastHostInfo.ip) return;
  hostInfoShown = true;
  // textContent, not innerHTML — no escaping needed, the browser can't
  // interpret this as markup regardless of what the values contain.
  el.textContent = [lastHostInfo.hostname, lastHostInfo.ip].filter(Boolean).join('   ');
  el.classList.add('show');
  setTimeout(() => el.classList.remove('show'), 10000);
}

// Show the hostname/IP once — 10s, starting 2 minutes after page load —
// not a repeating cycle. Stays hidden after that until the kiosk session
// restarts (service restart or reboot reloads the page, resetting
// hostInfoShown).
setTimeout(showHostInfo, 120000);

function fmt(n) {
  if (n === null || n === undefined) return '—';
  return Number(n).toLocaleString(undefined, {minimumFractionDigits: 1, maximumFractionDigits: 2});
}

function esc(s) {
  // Full escaper (incl. quotes) — safe for both text and attribute
  // contexts, unlike a textContent/innerHTML round-trip which leaves
  // quote characters untouched.
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safeFlagSrc(src) {
  // Only ever expect a same-origin /static/flags/... path from the API.
  // Reject anything else (e.g. a javascript: URL) before it reaches src=.
  return typeof src === 'string' && src.startsWith('/static/flags/') ? esc(src) : '';
}

// "Last updated" label only — not free text the admin typed, so (unlike
// currency names/dashboard title, which are never auto-translated by
// design) this follows admin_language like the /admin UI chrome does.
const LAST_UPDATED_LABEL = { en: 'Last updated', ar: 'آخر تحديث' };

function pad2(n) { return String(n).padStart(2, '0'); }

// Fixed HH:MM:SS DD/MM/YYYY (24h, zero-padded) regardless of browser/OS
// locale — toLocaleString() output varies unpredictably by locale, which
// is exactly what a wall-mounted kiosk display shouldn't have.
function formatDateTime(dt) {
  const time = `${pad2(dt.getHours())}:${pad2(dt.getMinutes())}:${pad2(dt.getSeconds())}`;
  const date = `${pad2(dt.getDate())}/${pad2(dt.getMonth() + 1)}/${dt.getFullYear()}`;
  return `${time} ${date}`;
}

// Picks the column/row split (out of every split that fits n cards) whose
// resulting cell is the largest — so 2 cards fill the screen as two big
// tiles, 3 as three, 7 as a balanced 4x2ish block, and so on, instead of
// a fixed column count leaving unused space.
function bestGridSplit(n, w, h, gapX, gapY) {
  let best = null;
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols);
    const cellW = (w - gapX * (cols - 1)) / cols;
    const cellH = (h - gapY * (rows - 1)) / rows;
    if (cellW <= 0 || cellH <= 0) continue;
    const cellSize = Math.min(cellW, cellH);
    if (!best || cellSize > best.cellSize) {
      best = { cols, rows, cellSize };
    }
  }
  return best || { cols: 1, rows: 1, cellSize: Math.min(w, h) };
}

function fitGrid() {
  const gridWrap = document.getElementById('grid-wrap');
  const grid = gridWrap.querySelector('.grid');
  if (!grid || lastCount === 0) return;
  const rect = gridWrap.getBoundingClientRect();
  const gapX = window.innerWidth * 0.02;
  const gapY = window.innerHeight * 0.02;
  const { cols, rows, cellSize } = bestGridSplit(lastCount, rect.width, rect.height, gapX, gapY);
  grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;

  // Budget the cell's actual pixels (padding + gaps first) instead of
  // guessing fixed fractions of cellSize — that's what let the price
  // digits get clipped once cells got bigger/smaller than expected.
  const compactLayout = lastCount <= 2;
  const cardPad = cellSize * (compactLayout ? 0.045 : 0.075);
  const cardGap = cellSize * (compactLayout ? 0.025 : 0.055);
  grid.style.setProperty('--card-pad', cardPad + 'px');
  grid.style.setProperty('--card-gap', cardGap + 'px');

  const available = Math.max(20, cellSize - cardPad * 2 - cardGap * 3);
  // Price is the star of the card: bigger than the code, which is
  // bigger than the currency name. Icon gets the single largest share
  // since it's the most recognizable element from across a room.
  const iconScale = 0.85;
  const iconHeight = available * (compactLayout ? 0.36 : 0.30) * iconScale;
  grid.style.setProperty('--icon-h', compactLayout ? iconHeight + 'px' : 'auto');
  // For two cards, derive the image width from its capped height. This keeps
  // the 3:2 image visible without allowing its width to consume the row.
  grid.style.setProperty('--icon-w', compactLayout ? (iconHeight * 1.5) + 'px' : (95 * iconScale) + '%');
  grid.style.setProperty('--code-size', (available * (compactLayout ? 0.12 : 0.22)) + 'px');
  grid.style.setProperty('--name-size', (available * (compactLayout ? 0.075 : 0.14)) + 'px');
  const valueSize = available * (compactLayout ? 0.22 : 0.38);
  grid.style.setProperty('--value-size', valueSize + 'px');

  // Keep every formatted price on one line without ellipsis. Longer values
  // get a smaller font, while short values keep the largest possible size.
  grid.querySelectorAll('.value').forEach(value => {
    const textLength = Math.max(1, value.textContent.trim().length);
    const width = value.getBoundingClientRect().width;
    const fittedSize = width / textLength * 1.55;
    value.style.fontSize = Math.min(valueSize, fittedSize) + 'px';
  });
}

async function refresh() {
  try {
    const res = await fetch('/api/data');
    if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
    }
    const d = await res.json();

    lastHostInfo = { hostname: d.hostname || '', ip: d.ip || '' };

    if (d.updated_at === lastUpdatedAt) {
      return; // nothing changed since last poll — skip the re-render
    }
    lastUpdatedAt = d.updated_at;

    document.getElementById('dash-title').textContent = d.title || '';
    document.getElementById('dash-subtitle').textContent = d.subtitle || '';

    const wrap = document.getElementById('grid-wrap');
    // The screen is sized for a handful of big tiles, not a scrolling
    // list — cap what's shown even if more are enabled in the panel.
    const shown = (d.currencies || []).slice(0, MAX_DISPLAYED_CURRENCIES);
    lastCount = shown.length;
    if (lastCount === 0) {
      wrap.innerHTML = '<div class="empty">No currencies enabled. Add or enable some from the control panel.</div>';
    } else {
      const grid = document.createElement('div');
      grid.className = 'grid';
      shown.forEach(c => {
        const card = document.createElement('div');
        card.className = 'card';
        card.innerHTML = `
          <div class="icon-badge">${c.flag ? `<img src="${safeFlagSrc(c.flag)}" alt="${esc(c.name)} flag">` : ''}</div>
          <div class="code">${esc(c.code)}</div>
          <div class="name">${esc(c.name)}</div>
          <div class="value">${esc(c.symbol)}${fmt(c.price)}</div>
        `;
        grid.appendChild(card);
      });
      wrap.innerHTML = '';
      wrap.appendChild(grid);
      fitGrid();
    }

    document.getElementById('footer').hidden = !d.show_updated_at;
    const updated = document.getElementById('updated-at');
    if (d.updated_at) {
      const dt = new Date(d.updated_at * 1000);
      const label = LAST_UPDATED_LABEL[d.admin_language] || LAST_UPDATED_LABEL.en;
      updated.textContent = `${label} ${formatDateTime(dt)}`;
    }
  } catch (e) {
    document.getElementById('updated-at').textContent = 'Could not load data';
  }
}

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(fitGrid, 100);
});

refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""

ADMIN_HTML = """
<!doctype html>
<html lang="{{ lang }}" dir="{{ 'rtl' if lang == 'ar' else 'ltr' }}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Control Panel &mdash; Currency Dashboard</title>
<style>
  :root {
    --bg-1: #0f172a;
    --bg-2: #1e1b4b;
    --card-bg: rgba(255, 255, 255, 0.06);
    --card-border: rgba(255, 255, 255, 0.12);
    --text-main: #f8fafc;
    --text-dim: #94a3b8;
    --accent: #22d3ee;
    --danger: #f87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(circle at 20% 20%, var(--bg-2), var(--bg-1) 60%);
    color: var(--text-main);
    padding: 32px 24px 80px;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 6px; }
  p.sub { color: var(--text-dim); margin: 0 0 28px; font-size: 0.95rem; }
  .msg {
    padding: 12px 16px;
    border-radius: 12px;
    margin-bottom: 20px;
    font-size: 0.9rem;
  }
  .msg.ok { background: rgba(52,211,153,0.12); border: 1px solid rgba(52,211,153,0.4); color: #86efac; }
  .msg.err { background: rgba(248,113,113,0.12); border: 1px solid rgba(248,113,113,0.4); color: #fca5a5; }
  .row {
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 18px;
    padding: 18px 20px;
    margin-bottom: 14px;
    display: flex;
    align-items: center;
    gap: 16px;
    flex-wrap: wrap;
  }
  .row.disabled { opacity: 0.55; }
  .row .thumb {
    width: 56px;
    height: 38px;
    border-radius: 8px;
    overflow: hidden;
    background: rgba(255,255,255,0.06);
    border: 1px solid var(--card-border);
    flex-shrink: 0;
  }
  .row .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .row .inline { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; flex: 1; }
  .row .code-badge {
    font-weight: 700;
    letter-spacing: 0.06em;
    font-size: 0.95rem;
    width: 56px;
    flex-shrink: 0;
  }
  input[type=text], input[type=number], select {
    padding: 9px 12px;
    font-size: 0.95rem;
    border-radius: 10px;
    border: 1px solid var(--card-border);
    background: rgba(255,255,255,0.05);
    color: var(--text-main);
  }
  input[name=name] { width: 150px; }
  input[name=symbol] { width: 150px; }
  input[name=price] { width: 100px; }
  label.chk { display: flex; align-items: center; gap: 6px; font-size: 0.85rem; color: var(--text-dim); }
  button {
    padding: 9px 16px;
    font-size: 0.9rem;
    font-weight: 600;
    border-radius: 10px;
    border: none;
    cursor: pointer;
  }
  button.save { background: var(--accent); color: #0f172a; }
  button.save:hover { opacity: 0.9; }
  button.delete { background: rgba(248,113,113,0.15); border: 1px solid rgba(248,113,113,0.4); color: var(--danger); }
  button.delete:hover { background: rgba(248,113,113,0.25); }
  .add-card {
    background: var(--card-bg);
    border: 1px dashed var(--card-border);
    border-radius: 18px;
    padding: 24px;
    margin-top: 30px;
  }
  .add-card h2 { font-size: 1.1rem; margin: 0 0 16px; }
  .add-card .fields { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 14px; }
  .add-card .fields input[name=code] {
    width: 150px;
    max-width: 100%;
    text-transform: uppercase;
  }
  .flag-choice { display: flex; gap: 18px; margin-bottom: 14px; font-size: 0.9rem; color: var(--text-dim); }
  .flag-choice label { display: flex; align-items: center; gap: 6px; }
  input[type=file] { color: var(--text-dim); font-size: 0.85rem; }
  .top-bar {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 16px;
    margin-bottom: 20px;
  }
  .lang-form select { min-width: 140px; }
  .settings-card {
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 18px;
    padding: 22px 24px;
    margin-bottom: 28px;
  }
  .settings-card h2 { font-size: 1.05rem; margin: 0 0 16px; }
  .settings-card .fields { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
  .settings-card label.field-label {
    display: block;
    font-size: 0.8rem;
    color: var(--text-dim);
    margin-bottom: 6px;
  }
  .settings-card input[type=text] { width: 260px; }
  a.back {
    display: inline-block;
    margin-top: 30px;
    color: var(--text-dim);
    text-decoration: none;
    font-size: 0.85rem;
  }
  a.back:hover { color: var(--text-main); }
</style>
</head>
<body>
<div class="wrap">
  <div class="top-bar">
    <div>
      <h1>&#9881; {{ t.panel_title }}</h1>
      <p class="sub" style="margin-bottom:0;">{{ t.panel_sub }}</p>
    </div>
    <form class="lang-form" method="post" action="{{ url_for('admin_set_language') }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
      <select name="admin_language" onchange="this.form.submit()">
        <option value="en" {% if lang == 'en' %}selected{% endif %}>English</option>
        <option value="ar" {% if lang == 'ar' %}selected{% endif %}>العربية</option>
      </select>
    </form>
  </div>

  {% if msg %}<div class="msg ok">{{ msg }}</div>{% endif %}
  {% if error %}<div class="msg err">{{ error }}</div>{% endif %}

  <!-- Each currency's Remove button lives visually inside the row below,
       but submits one of these standalone per-currency forms instead of the
       big save-all form, via the button's form="..." attribute (HTML5). -->
  {% for c in currencies %}
  <form id="delete-{{ c.code }}" method="post" action="{{ url_for('admin_delete_currency', code=c.code) }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  {% endfor %}

  <!-- Same standalone-form pattern as the per-currency delete forms above:
       "Check for updates now" is a distinct action from saving settings,
       so it submits its own tiny form via the button's form="..."
       attribute rather than nesting inside the big save-all form. -->
  <form id="check-update-now" method="post" action="{{ url_for('admin_check_update_now') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>

  <form method="post" action="{{ url_for('admin_save_all') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="settings-card">
      <h2>{{ t.settings_heading }}</h2>
      <div class="fields">
        <div>
          <label class="field-label" for="title">{{ t.field_title }}</label>
          <input type="text" id="title" name="title" value="{{ settings.title }}" maxlength="{{ max_title_len }}" required>
        </div>
        <div>
          <label class="field-label" for="subtitle">{{ t.field_subtitle }}</label>
          <input type="text" id="subtitle" name="subtitle" value="{{ settings.subtitle }}" maxlength="{{ max_subtitle_len }}">
        </div>
        <label class="chk"><input type="checkbox" name="show_updated_at" {% if settings.show_updated_at %}checked{% endif %}> {{ t.show_updated_label }}</label>
      </div>
    </div>

    <div class="settings-card">
      <h2>{{ t.updates_heading }}</h2>
      <div class="fields">
        <div style="color:var(--text-dim); font-size:0.9rem;">
          {{ t.version_label }}: <strong style="color:var(--text-main);">{{ app_version }}</strong>{% if app_commit %} <span style="opacity:0.7;">({{ app_commit }})</span>{% endif %}
        </div>
        <label class="chk"><input type="checkbox" name="auto_update_enabled" {% if auto_update_enabled %}checked{% endif %}> {{ t.auto_update_label }}</label>
        <button type="submit" form="check-update-now" class="save">{{ t.check_now_btn }}</button>
      </div>
    </div>

    {% for c in currencies %}
    <div class="row {% if not c.enabled %}disabled{% endif %}">
      <div class="thumb">{% if c.flag %}<img src="{{ c.flag }}" alt="{{ c.name }} flag">{% endif %}</div>
      <div class="code-badge">{{ c.code }}</div>
      <div class="inline">
        <input type="text" name="name_{{ c.code }}" value="{{ c.name }}" placeholder="{{ t.name_ph }}" maxlength="{{ max_name_len }}" required>
        <input type="text" name="symbol_{{ c.code }}" value="{{ c.symbol }}" placeholder="{{ t.symbol_ph }}" maxlength="{{ max_symbol_len }}">
        <input type="text" inputmode="decimal" name="price_{{ c.code }}" value="{{ c.price }}" oninput="filterDecimalInput(this)" placeholder="{{ t.price_ph }}" required>
        <label class="chk"><input type="checkbox" name="enabled_{{ c.code }}" {% if c.enabled %}checked{% endif %}> {{ t.enabled_label }}</label>
      </div>
      <button type="submit" form="delete-{{ c.code }}" class="delete" onclick="return confirm('{{ t.confirm_remove.format(code=c.code) }}');">{{ t.remove_btn }}</button>
    </div>
    {% endfor %}

    <div style="margin-top:20px;"><button type="submit" class="save">{{ t.save_settings }}</button></div>
  </form>

  <div class="add-card">
    <h2>{{ t.add_heading }}</h2>
    <form method="post" action="{{ url_for('admin_add_currency') }}" enctype="multipart/form-data">
      <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
      <div class="fields">
        <input type="text" name="code" placeholder="{{ t.code_ph }}" maxlength="{{ max_code_len }}" required>
        <input type="text" name="name" placeholder="{{ t.name_req_ph }}" maxlength="{{ max_name_len }}" required>
        <input type="text" name="symbol" placeholder="{{ t.symbol_opt_ph }}" maxlength="{{ max_symbol_len }}">
        <input type="text" inputmode="decimal" name="price" placeholder="{{ t.price_req_ph }}" oninput="filterDecimalInput(this)" required>
      </div>
      <div class="flag-choice">
        <label><input type="radio" name="flag_source" value="auto" checked> {{ t.flag_auto }}</label>
        <label><input type="radio" name="flag_source" value="upload"> {{ t.flag_upload }}</label>
      </div>
      <input type="file" name="flag_file" accept="image/*">
      <div style="margin-top:16px;"><button type="submit" class="save">{{ t.add_btn }}</button></div>
    </form>
  </div>

  <a class="back" href="/">{{ t.back_link }}</a>
</div>
<script>
// Price fields are type="text" (not type="number") specifically to kill
// the browser's native spinner/scroll-to-change-value behavior on number
// inputs — this restores "only digits and one dot" by hand instead.
function filterDecimalInput(el) {
  let v = el.value.replace(/[^0-9.]/g, '');
  const i = v.indexOf('.');
  if (i !== -1) v = v.slice(0, i + 1) + v.slice(i + 1).replace(/\\./g, '');
  if (v !== el.value) el.value = v;
}
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

@app.route("/")
def dashboard():
    data = load_data()
    return render_template_string(DASHBOARD_HTML, settings=data["settings"])


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
        "hostname": socket.gethostname(),
        "ip": get_lan_ip(),
    })


@app.route("/admin", methods=["GET"])
def admin_page():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    lang, t = get_translations(data)
    return render_template_string(
        ADMIN_HTML,
        currencies=data["currencies"],
        settings=data["settings"],
        lang=lang,
        t=t,
        msg=request.args.get("msg"),
        error=request.args.get("error"),
        max_title_len=MAX_TITLE_LEN,
        max_subtitle_len=MAX_SUBTITLE_LEN,
        max_name_len=MAX_NAME_LEN,
        max_symbol_len=MAX_SYMBOL_LEN,
        max_code_len=MAX_CODE_LEN,
        max_price_value=MAX_PRICE_VALUE,
        csrf_token=csrf_token(),
        app_version=APP_VERSION,
        app_commit=APP_COMMIT,
        auto_update_enabled=os.path.isfile(AUTO_UPDATE_ENABLED_FLAG),
    )


@app.route("/admin/language", methods=["POST"])
def admin_set_language():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    lang = request.form.get("admin_language", "en")
    if lang not in TRANSLATIONS:
        lang = "en"
    data["settings"]["admin_language"] = lang
    save_data(data)
    return redirect(url_for("admin_page"))


@app.route("/admin/save-all", methods=["POST"])
def admin_save_all():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))

    title = clean_text(request.form.get("title"), MAX_TITLE_LEN)
    if title is None:
        return redirect(url_for("admin_page", error=t["err_too_long"].format(field=t["field_title"], max=MAX_TITLE_LEN)))
    if not title:
        return redirect(url_for("admin_page", error=t["err_title_required"]))

    subtitle = clean_text(request.form.get("subtitle"), MAX_SUBTITLE_LEN)
    if subtitle is None:
        return redirect(url_for("admin_page", error=t["err_too_long"].format(field=t["field_subtitle"], max=MAX_SUBTITLE_LEN)))

    # Validate everything before writing anything, so a bad field in one
    # currency doesn't leave others half-updated.
    updates = {}
    for c in data["currencies"]:
        code = c["code"]
        name_val = clean_text(request.form.get(f"name_{code}"), MAX_NAME_LEN)
        symbol_val = clean_text(request.form.get(f"symbol_{code}"), MAX_SYMBOL_LEN)
        price_raw = request.form.get(f"price_{code}", "")

        if name_val is None:
            return redirect(url_for("admin_page", error=t["err_too_long"].format(field=f"{code} {t['name_ph']}", max=MAX_NAME_LEN)))
        if symbol_val is None:
            return redirect(url_for("admin_page", error=t["err_too_long"].format(field=f"{code} {t['symbol_ph']}", max=MAX_SYMBOL_LEN)))
        if not name_val or not price_raw:
            return redirect(url_for("admin_page", error=t["err_missing_fields"].format(code=code)))

        price_val = parse_price(price_raw)
        if price_val is None:
            return redirect(url_for("admin_page", error=t["err_invalid_price"].format(code=code, max=f"{MAX_PRICE_VALUE:,}")))

        updates[code] = {
            "name": name_val,
            "symbol": symbol_val,
            "price": price_val,
            "enabled": f"enabled_{code}" in request.form,
        }

    for c in data["currencies"]:
        c.update(updates[c["code"]])

    data["settings"]["title"] = title
    data["settings"]["subtitle"] = subtitle
    data["settings"]["show_updated_at"] = "show_updated_at" in request.form

    # Auto-update enabled/disabled is a flag FILE, not a data.json field —
    # scripts/auto-update.sh checks for this file's existence directly (see
    # its own comments), so this is the one place that file gets
    # created/removed.
    if "auto_update_enabled" in request.form:
        open(AUTO_UPDATE_ENABLED_FLAG, "a", encoding="utf-8").close()
    else:
        try:
            os.remove(AUTO_UPDATE_ENABLED_FLAG)
        except FileNotFoundError:
            pass

    save_data(data)
    return redirect(url_for("admin_page", msg=t["settings_saved"]))


@app.route("/admin/check-update-now", methods=["POST"])
def admin_check_update_now():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))

    # Touching this flag makes auto-update.sh run its check unconditionally
    # on its next invocation, regardless of the enabled flag, and delete
    # the flag afterward (see that script). Starting the updater service
    # directly makes that "next invocation" happen right now instead of
    # waiting for the timer — fire-and-forget (Popen, not run/check_call):
    # if an update is actually applied, the updater restarts this very
    # service partway through, so nothing here can safely wait on it.
    open(AUTO_UPDATE_CHECK_NOW_FLAG, "a", encoding="utf-8").close()
    try:
        subprocess.Popen(
            ["sudo", "-n", "systemctl", "start", f"{SERVICE_NAME}-updater.service"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass  # the flag file alone still guarantees a check on the next scheduled tick

    return redirect(url_for("admin_page", msg=t["check_now_started"]))


@app.route("/admin/currency/<code>/delete", methods=["POST"])
def admin_delete_currency(code):
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    c = find_currency(data, code)
    if not c:
        return redirect(url_for("admin_page", error=t["err_not_found"].format(code=code)))
    data["currencies"] = [x for x in data["currencies"] if x["code"] != code]
    save_data(data)
    delete_flag_file(c.get("flag"))
    return redirect(url_for("admin_page", msg=f"{code}{t['removed_suffix']}"))


@app.route("/admin/currency/add", methods=["POST"])
def admin_add_currency():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized

    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))

    code = re.sub(r"[^A-Za-z0-9]", "", request.form.get("code", "")).upper()[:MAX_CODE_LEN]
    name = clean_text(request.form.get("name"), MAX_NAME_LEN)
    symbol = clean_text(request.form.get("symbol"), MAX_SYMBOL_LEN)
    price_raw = request.form.get("price", "")

    if not code:
        return redirect(url_for("admin_page", error=t["err_invalid_code"]))
    if name is None:
        return redirect(url_for("admin_page", error=t["err_too_long"].format(field=t["name_ph"], max=MAX_NAME_LEN)))
    if symbol is None:
        return redirect(url_for("admin_page", error=t["err_too_long"].format(field=t["symbol_ph"], max=MAX_SYMBOL_LEN)))
    if not name:
        return redirect(url_for("admin_page", error=t["err_code_required"]))

    price = parse_price(price_raw)
    if price is None:
        return redirect(url_for("admin_page", error=t["err_invalid_price"].format(code=code, max=f"{MAX_PRICE_VALUE:,}")))

    if find_currency(data, code):
        return redirect(url_for("admin_page", error=t["err_code_exists"].format(code=code)))

    flag_source = request.form.get("flag_source", "auto")
    flag_path = None
    if flag_source == "upload" and "flag_file" in request.files and request.files["flag_file"].filename:
        flag_path = save_uploaded_flag(code, request.files["flag_file"])
        if not flag_path:
            return redirect(url_for("admin_page", error=t["err_unsupported_image"]))
    else:
        flag_path = fetch_suggested_flag(code)
        if not flag_path:
            return redirect(url_for("admin_page", error=t["err_flag_fetch_failed"].format(code=code)))

    data["currencies"].append({
        "code": code,
        "name": name,
        "symbol": symbol,
        "price": price,
        "flag": flag_path,
        "enabled": True,
    })
    save_data(data)
    return redirect(url_for("admin_page", msg=f"{code}{t['added_suffix']}"))


if __name__ == "__main__":
    # The dashboard (/) always serves over plain HTTP on APP_PORT — the
    # kiosk browser points here and must never hit a self-signed-cert
    # warning. /admin is redirected to HTTPS by the before_request hook
    # above, but only once the HTTPS listener below is actually confirmed
    # working — until a cert exists (see scripts/generate-cert.sh), admin
    # stays reachable over HTTP as a fallback rather than being locked out.
    https_server = None
    if os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE):
        try:
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(CERT_FILE, KEY_FILE)
            # Built with NO ssl_context here, then the listening socket is
            # wrapped manually below with do_handshake_on_connect=False —
            # NOT the same as passing ssl_context= to make_server(), which
            # wraps with the default do_handshake_on_connect=True. That
            # default performs the TLS handshake SYNCHRONOUSLY inside the
            # shared accept() call, before threaded=True ever hands the
            # connection to a worker thread. One client whose handshake
            # stalls (network blip, a browser retrying against a stale
            # cert, anything) then wedges accept() forever — and with it,
            # every other client, including localhost. This was a real,
            # live bug (admin panel ERR_TIMED_OUT, reproduced with a
            # standalone script: a single stuck connection blocked a
            # second, completely unrelated client indefinitely) — a
            # restart "fixes" it by throwing away the wedged process, but
            # doesn't fix the underlying flaw. do_handshake_on_connect=False
            # defers the handshake to the first read/write on each
            # connection, which happens in that connection's own worker
            # thread — confirmed with the same repro that a stuck client
            # no longer affects anyone else.
            https_server = make_server("0.0.0.0", HTTPS_PORT, app, threaded=True)
            https_server.socket = ssl_ctx.wrap_socket(
                https_server.socket, server_side=True, do_handshake_on_connect=False
            )
            https_server.ssl_context = ssl_ctx
        except OSError as e:
            print(f"Could not start HTTPS listener on port {HTTPS_PORT}: {e}")

    HTTPS_ENABLED = https_server is not None
    if HTTPS_ENABLED:
        print(f"Admin panel (HTTPS): https://{socket.gethostname()}:{HTTPS_PORT}/admin")
    else:
        print(f"No usable SSL cert at {CERT_FILE} — admin panel served over HTTP only. Run scripts/generate-cert.sh to enable HTTPS.")

    http_server = make_server("0.0.0.0", APP_PORT, app, threaded=True)
    threads = [threading.Thread(target=http_server.serve_forever, daemon=True)]
    if https_server:
        threads.append(threading.Thread(target=https_server.serve_forever, daemon=True))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
