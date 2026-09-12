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

# Wi-Fi/hotspot-fallback/reboot control: this app never holds sudo or any
# other privilege. NET_CONFIG_FILE/REBOOT_REQUEST_FLAG are plain files the
# admin panel writes describing DESIRED state only; a separate root-run
# systemd daemon (scripts/files/network/dashboard-net-apply.sh, installed
# by deploy-dashboard.sh) polls them every few seconds and does the actual
# nmcli/systemctl work, then publishes OBSERVED state (never secrets) to
# NET_STATUS_FILE for this app to read back. Same one-way-file-drop idiom
# as AUTO_UPDATE_ENABLED_FLAG above, just with a faster-polling daemon on
# the other end instead of a 6h timer.
NET_CONFIG_FILE = os.path.join(APP_DIR, "net_config.json")
REBOOT_REQUEST_FLAG = os.path.join(APP_DIR, "reboot.request")
NET_STATUS_FILE = "/run/dashboard-net/status.json"


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
APP_VERSION_STRING = f"{APP_VERSION}+{APP_COMMIT}" if APP_COMMIT else APP_VERSION

APP_PORT = int(os.environ.get("APP_PORT", "80"))
HTTPS_PORT = int(os.environ.get("HTTPS_PORT", "443"))
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
# journald policy provision-pi.sh sets up ). Two pieces:
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

MAX_SSID_LEN = 32  # 802.11 SSID byte cap, treated as a char cap here (ASCII in practice)
MIN_WIFI_PASS_LEN = 8
MAX_WIFI_PASS_LEN = 63  # WPA2-PSK bounds. A blank field means "keep the saved
                        # password", never an open network — see admin_wifi_save().
MAX_WIFI_SLOTS = 2

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
        "network_heading": "Wi-Fi",
        "wifi_status_label": "Status",
        "wifi_connected_fmt": "Connected to {ssid} ({ip})",
        "wifi_not_connected": "Not connected",
        "wifi_unavailable": "Wi-Fi management is unavailable in this environment (no network reconciler detected — normal for local/Windows testing).",
        "wifi_slot_label": "Network {n}",
        "wifi_ssid_ph": "SSID",
        "wifi_password_ph": "Password (blank = keep saved)",
        "wifi_password_note": "Passwords are never shown again after saving. Leave one blank only to keep the password already saved for that exact SSID — adding or changing an SSID requires typing its password. Open (password-less) networks are not allowed. Changes apply within a few seconds.",
        "wifi_save_btn": "Save Wi-Fi networks",
        "wifi_save_started": "Saved — the Pi will try these networks within a few seconds.",
        "hotspot_heading": "Emergency Hotspot Fallback",
        "hotspot_not_installed": "Not installed — save a hotspot SSID/password below to enable it.",
        "hotspot_installed_inactive": "Installed, watching for Wi-Fi loss (not currently broadcasting).",
        "hotspot_active": "Currently broadcasting — primary Wi-Fi appears to be down. You may be viewing this page over the hotspot right now.",
        "hotspot_ssid_ph": "Hotspot SSID",
        "hotspot_password_ph": "Hotspot password (min 8, blank = keep saved)",
        "hotspot_save_btn": "Save hotspot",
        "hotspot_disable_btn": "Disable hotspot",
        "hotspot_disable_confirm": "Disable the emergency hotspot? If this Pi ever loses its primary Wi-Fi, it will have no fallback way to reach it remotely.",
        "hotspot_saved": "Saved — the hotspot will be configured within a few seconds.",
        "hotspot_disabled": "Hotspot fallback disabled.",
        "err_hotspot_password_len": "Hotspot password must be {min}-{max} characters.",
        "err_hotspot_password_required": "The hotspot needs a password — open hotspots aren't allowed. Leave the field blank only to keep the saved password for an unchanged SSID.",
        "restart_heading": "System",
        "restart_btn": "Restart board",
        "restart_confirm": "Restart the Raspberry Pi now? The dashboard and admin panel will be unreachable for roughly a minute.",
        "restart_started": "Reboot requested — the board will restart within a few seconds.",
        "err_ssid_invalid": "{field} is invalid or too long (max {max} characters, can't start with '-').",
        "err_wifi_password_len": "{field} must be {min}-{max} characters.",
        "err_wifi_password_required": "{field} needs a password — open networks aren't allowed. Leave the field blank only to keep the password already saved for that same SSID.",
        "system_nav_btn": "System, Network & Updates",
        "system_heading": "System & Network",
        "system_sub": "Wi-Fi, hotspot fallback, updates, and board restart.",
        "back_to_admin": "← Back to dashboard settings",
        "wifi_prefilled_note": "Showing currently configured network(s). Leave a password blank to keep the one already saved for that SSID; if you change an SSID, you must type its password too.",
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
        "network_heading": "واي فاي",
        "wifi_status_label": "الحالة",
        "wifi_connected_fmt": "متصل بـ {ssid} ({ip})",
        "wifi_not_connected": "غير متصل",
        "wifi_unavailable": "إدارة واي فاي غير متاحة في هذه البيئة (لم يتم العثور على خدمة المطابقة — طبيعي عند الاختبار المحلي على ويندوز).",
        "wifi_slot_label": "الشبكة {n}",
        "wifi_ssid_ph": "اسم الشبكة (SSID)",
        "wifi_password_ph": "كلمة المرور (فارغة = الإبقاء على المحفوظة)",
        "wifi_password_note": "لا تُعرض كلمات المرور مجددًا بعد الحفظ. اترك الحقل فارغًا فقط للإبقاء على كلمة المرور المحفوظة لنفس الـ SSID — أمّا إضافة SSID أو تغييره فتتطلب كتابة كلمة مروره. الشبكات المفتوحة (بدون كلمة مرور) غير مسموح بها. تُطبَّق التغييرات خلال ثوانٍ قليلة.",
        "wifi_save_btn": "حفظ شبكات الواي فاي",
        "wifi_save_started": "تم الحفظ — سيحاول الجهاز الاتصال بهذه الشبكات خلال ثوانٍ قليلة.",
        "hotspot_heading": "نقطة الاتصال الاحتياطية للطوارئ",
        "hotspot_not_installed": "غير مُثبَّتة — احفظ اسم وكلمة مرور نقطة الاتصال أدناه لتفعيلها.",
        "hotspot_installed_inactive": "مُثبَّتة وتراقب انقطاع الواي فاي (لا تبث حاليًا).",
        "hotspot_active": "تبث حاليًا — يبدو أن الواي فاي الأساسي معطل. قد تكون تشاهد هذه الصفحة عبر نقطة الاتصال الآن.",
        "hotspot_ssid_ph": "اسم نقطة الاتصال",
        "hotspot_password_ph": "كلمة مرور نقطة الاتصال (8 أحرف على الأقل، فارغة = الإبقاء على المحفوظة)",
        "hotspot_save_btn": "حفظ نقطة الاتصال",
        "hotspot_disable_btn": "تعطيل نقطة الاتصال",
        "hotspot_disable_confirm": "هل تريد تعطيل نقطة الاتصال الاحتياطية؟ إذا فقد هذا الجهاز اتصال الواي فاي الأساسي، فلن يكون لديه وسيلة احتياطية للوصول إليه عن بُعد.",
        "hotspot_saved": "تم الحفظ — سيتم تهيئة نقطة الاتصال خلال ثوانٍ قليلة.",
        "hotspot_disabled": "تم تعطيل نقطة الاتصال الاحتياطية.",
        "err_hotspot_password_len": "يجب أن تكون كلمة مرور نقطة الاتصال بين {min} و{max} حرفًا.",
        "err_hotspot_password_required": "نقطة الاتصال تحتاج إلى كلمة مرور — نقاط الاتصال المفتوحة غير مسموح بها. اترك الحقل فارغًا فقط للإبقاء على الكلمة المحفوظة لـ SSID لم يتغيّر.",
        "restart_heading": "النظام",
        "restart_btn": "إعادة تشغيل الجهاز",
        "restart_confirm": "هل تريد إعادة تشغيل جهاز Raspberry Pi الآن؟ ستكون لوحة العرض ولوحة التحكم غير متاحتين لمدة دقيقة تقريبًا.",
        "restart_started": "تم طلب إعادة التشغيل — سيُعاد تشغيل الجهاز خلال ثوانٍ قليلة.",
        "err_ssid_invalid": "{field} غير صالح أو طويل جدًا (الحد الأقصى {max} حرفًا، ولا يمكن أن يبدأ بـ '-').",
        "err_wifi_password_len": "يجب أن تكون قيمة {field} بين {min} و{max} حرفًا.",
        "err_wifi_password_required": "{field} تحتاج إلى كلمة مرور — الشبكات المفتوحة غير مسموح بها. اترك الحقل فارغًا فقط للإبقاء على الكلمة المحفوظة لنفس الـ SSID.",
        "system_nav_btn": "النظام والشبكة والتحديثات",
        "system_heading": "النظام والشبكة",
        "system_sub": "الواي فاي، نقطة الاتصال الاحتياطية، التحديثات، وإعادة تشغيل الجهاز.",
        "back_to_admin": "← العودة إلى إعدادات لوحة التحكم",
        "wifi_prefilled_note": "يتم عرض الشبكة (الشبكات) المُهيأة حاليًا. اترك كلمة المرور فارغة للإبقاء على المحفوظة لنفس الـ SSID؛ وإذا غيّرت الـ SSID فيجب كتابة كلمة مروره أيضًا.",
    },
}

app = Flask(__name__)
os.makedirs(FLAGS_DIR, exist_ok=True)


def _port_suffix(port: int, default_port: int) -> str:
    return "" if port == default_port else f":{port}"


@app.before_request
def redirect_admin_to_https():
    # The public dashboard (/, /api/data, /static/*) stays on plain HTTP so
    # the kiosk browser never has to deal with a self-signed cert — only
    # /admin gets pushed onto HTTPS, and only once the HTTPS listener is
    # actually confirmed up (HTTPS_ENABLED, set for real once __main__ has
    # successfully bound it — see bottom of this file).
    if HTTPS_ENABLED and request.path.startswith("/admin") and request.scheme != "https":
        host = request.host.split(":")[0]
        target = f"https://{host}{_port_suffix(HTTPS_PORT, 443)}{request.full_path}".rstrip("?")
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


_DEFAULT_NET_CONFIG = {"wifi": [], "ap_fallback": {"enabled": False, "ssid": "", "password": ""}}


def load_net_config():
    """Desired Wi-Fi/hotspot state, written by the admin panel and polled
    by scripts/files/network/dashboard-net-apply.sh. Kept in its own file,
    separate from data.json, since data.json is loaded by the public,
    unauthenticated dashboard()/api_data() routes and this file holds
    plaintext Wi-Fi/hotspot passwords."""
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


def _read_net_status():
    """Best-effort read of the daemon-published status file. A missing or
    corrupt file — the daemon never ran (e.g. local/Windows dev testing),
    or it's the few-second window right after boot before its first tick —
    is treated as "unavailable", not an error; never raises."""
    try:
        with open(NET_STATUS_FILE, encoding="utf-8") as f:
            status = json.load(f)
        status["available"] = True
        return status
    except (OSError, json.JSONDecodeError):
        return {"available": False}


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


def clean_ssid(raw):
    """Same control-char-strip/length-cap handling as clean_text(), plus one
    SSID-specific rule: reject a leading '-', since nmcli's own argument
    parsing can mistake it for a flag — the same limitation
    provision-pi.sh's connect_wifi() already has unhandled, not worth
    solving here. Empty is allowed (an empty slot is simply unused)."""
    cleaned = clean_text(raw, MAX_SSID_LEN)
    if cleaned is None or cleaned.startswith("-"):
        return None
    return cleaned


def validate_wifi_password(raw):
    """Empty, or MIN_WIFI_PASS_LEN-MAX_WIFI_PASS_LEN chars (WPA2-PSK
    bounds). Unlike clean_text(), doesn't collapse/strip whitespace — a
    Wi-Fi password may legitimately contain meaningful spaces. Returns
    None if outside the allowed length range.

    Empty is NOT "open network" here — open networks are rejected outright
    by the callers. It only means "the admin left the field alone", which
    admin_wifi_save()/admin_ap_save() resolve to the saved password for an
    unchanged SSID, or to an error."""
    if raw is None:
        return ""
    cleaned = "".join(ch for ch in raw if unicodedata.category(ch)[0] != "C")
    if not cleaned:
        return ""
    if len(cleaned) < MIN_WIFI_PASS_LEN or len(cleaned) > MAX_WIFI_PASS_LEN:
        return None
    return cleaned


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
const PAGE_LOAD_VERSION = {{ version | tojson }};
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

    if (d.app_version && d.app_version !== PAGE_LOAD_VERSION) {
      // A deploy/auto-update swapped in new app code (e.g. changed JS in
      // this very template) after this tab's page was loaded — restarting
      // the systemd service does not touch an already-open kiosk tab, so
      // without this the kiosk would keep running stale JS indefinitely.
      location.reload();
      return;
    }

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

# Shared by ADMIN_HTML and SYSTEM_HTML (plain CSS, no Jinja placeholders,
# so it's safe to concatenate with `+` into either template string) — the
# admin panel was split into two pages (dashboard/currency settings vs.
# system/network/updates) so both need the same look without duplicating
# this whole block twice.
ADMIN_STYLE = """
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
  button.save, a.save { background: var(--accent); color: #0f172a; }
  button.save:hover, a.save:hover { opacity: 0.9; }
  button.delete, a.delete { background: rgba(248,113,113,0.15); border: 1px solid rgba(248,113,113,0.4); color: var(--danger); }
  button.delete:hover, a.delete:hover { background: rgba(248,113,113,0.25); }
  a.save, a.delete { display: inline-block; text-decoration: none; padding: 9px 16px; font-size: 0.9rem; font-weight: 600; border-radius: 10px; }
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
"""

ADMIN_HTML = ADMIN_STYLE + """
<!doctype html>
<html lang="{{ lang }}" dir="{{ 'rtl' if lang == 'ar' else 'ltr' }}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Control Panel &mdash; Currency Dashboard</title>
</head>
<body>
<div class="wrap">
  <div class="top-bar">
    <div>
      <h1>&#9881; {{ t.panel_title }}</h1>
      <p class="sub" style="margin-bottom:0;">{{ t.panel_sub }}</p>
    </div>
    <div style="display:flex; flex-direction:column; align-items:flex-end; gap:10px;">
      <form class="lang-form" method="post" action="{{ url_for('admin_set_language') }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
        <select name="admin_language" onchange="this.form.submit()">
          <option value="en" {% if lang == 'en' %}selected{% endif %}>English</option>
          <option value="ar" {% if lang == 'ar' %}selected{% endif %}>العربية</option>
        </select>
      </form>
      <a class="save" href="{{ url_for('admin_system_page') }}">&#9881; {{ t.system_nav_btn }}</a>
    </div>
  </div>

  {% if msg %}<div class="msg ok">{{ msg }}</div>{% endif %}
  {% if error %}<div class="msg err">{{ error }}</div>{% endif %}

  <!-- Each currency's Remove button lives visually inside the row below,
       but submits one of these standalone per-currency forms instead of the
       big save-all form, via the button's form="..." attribute (HTML5). -->
  {% for c in currencies %}
  <form id="delete-{{ c.code }}" method="post" action="{{ url_for('admin_delete_currency', code=c.code) }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  {% endfor %}

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

# Split out of ADMIN_HTML on request: the dashboard/currency admin page was
# getting crowded with system-level concerns (Wi-Fi, hotspot fallback,
# updates, reboot) that have nothing to do with prices/currencies and carry
# a different risk profile (can drop the admin's own connection, restart
# the board). Reachable from ADMIN_HTML via the "System, Network & Updates"
# link in its top-bar; links back to admin_page in turn.
SYSTEM_HTML = ADMIN_STYLE + """
<!doctype html>
<html lang="{{ lang }}" dir="{{ 'rtl' if lang == 'ar' else 'ltr' }}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>System &amp; Network &mdash; Currency Dashboard</title>
</head>
<body>
<div class="wrap">
  <div class="top-bar">
    <div>
      <h1>&#9881; {{ t.system_heading }}</h1>
      <p class="sub" style="margin-bottom:0;">{{ t.system_sub }}</p>
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

  <!-- None of these run anything privileged directly — each just writes
       desired state that a separate root-run daemon polls and applies
       (see NET_CONFIG_FILE's comment in app.py). Standalone forms (csrf
       token only, plus auto-update-toggle's checkbox) so their visible
       fields/buttons can live inside the settings-cards below, associated
       purely via each input's form="..." attribute, without nesting one
       form inside another. -->
  <form id="auto-update-toggle" method="post" action="{{ url_for('admin_toggle_auto_update') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  <form id="check-update-now" method="post" action="{{ url_for('admin_check_update_now') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  <form id="wifi-save" method="post" action="{{ url_for('admin_wifi_save') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  <form id="ap-save" method="post" action="{{ url_for('admin_ap_save') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  <form id="ap-disable" method="post" action="{{ url_for('admin_ap_disable') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>
  <form id="restart-board" method="post" action="{{ url_for('admin_reboot') }}"><input type="hidden" name="csrf_token" value="{{ csrf_token }}"></form>

  <div class="settings-card">
    <h2>{{ t.updates_heading }}</h2>
    <div class="fields">
      <div style="color:var(--text-dim); font-size:0.9rem;">
        {{ t.version_label }}: <strong style="color:var(--text-main);">{{ app_version }}</strong>{% if app_commit %} <span style="opacity:0.7;">({{ app_commit }})</span>{% endif %}
      </div>
      <label class="chk"><input type="checkbox" name="auto_update_enabled" form="auto-update-toggle" onchange="this.form.submit()" {% if auto_update_enabled %}checked{% endif %}> {{ t.auto_update_label }}</label>
      <button type="submit" form="check-update-now" class="save">{{ t.check_now_btn }}</button>
    </div>
  </div>

  <div class="settings-card">
    <h2>{{ t.network_heading }}</h2>
    <div class="fields">
      <div style="color:var(--text-dim); font-size:0.9rem; width:100%;">
        {{ t.wifi_status_label }}:
        {% if net_status.available %}
          <strong style="color:var(--text-main);">{% if net_status.connected %}{{ t.wifi_connected_fmt.format(ssid=net_status.ssid or '?', ip=net_status.ip or '?') }}{% else %}{{ t.wifi_not_connected }}{% endif %}</strong>
        {% else %}
          <span style="opacity:0.7;">{{ t.wifi_unavailable }}</span>
        {% endif %}
      </div>
      {% for slot in wifi_slots %}
      <div>
        <label class="field-label">{{ t.wifi_slot_label.format(n=loop.index) }}</label>
        <input type="text" name="wifi_ssid_{{ loop.index }}" form="wifi-save" value="{{ slot.ssid or '' }}" placeholder="{{ t.wifi_ssid_ph }}" maxlength="{{ max_ssid_len }}">
        <input type="password" name="wifi_password_{{ loop.index }}" form="wifi-save" placeholder="{{ t.wifi_password_ph }}" autocomplete="off" minlength="{{ min_wifi_pass_len }}" maxlength="{{ max_wifi_pass_len }}">
      </div>
      {% endfor %}
      {% if wifi_prefilled %}<div style="color:var(--text-dim); font-size:0.85rem; width:100%;">{{ t.wifi_prefilled_note }}</div>{% endif %}
      <div style="color:var(--text-dim); font-size:0.85rem; width:100%;">{{ t.wifi_password_note }}</div>
      <button type="submit" form="wifi-save" class="save">{{ t.wifi_save_btn }}</button>
    </div>
  </div>

  <div class="settings-card">
    <h2>{{ t.hotspot_heading }}</h2>
    <div class="fields">
      <div style="color:var(--text-dim); font-size:0.9rem; width:100%;">
        {% if not net_status.available %}
          <span style="opacity:0.7;">{{ t.wifi_unavailable }}</span>
        {% elif net_status.ap_active %}
          <strong style="color:var(--text-main);">{{ t.hotspot_active }}</strong>
        {% elif net_status.ap_installed %}
          {{ t.hotspot_installed_inactive }}
        {% else %}
          {{ t.hotspot_not_installed }}
        {% endif %}
      </div>
      <input type="text" name="ap_ssid" form="ap-save" value="{{ ap_fallback.ssid or '' }}" placeholder="{{ t.hotspot_ssid_ph }}" maxlength="{{ max_ssid_len }}">
      <input type="password" name="ap_password" form="ap-save" placeholder="{{ t.hotspot_password_ph }}" autocomplete="off" minlength="{{ min_wifi_pass_len }}" maxlength="{{ max_wifi_pass_len }}">
      <button type="submit" form="ap-save" class="save">{{ t.hotspot_save_btn }}</button>
      {% if ap_fallback.enabled %}
      <button type="submit" form="ap-disable" class="delete" onclick="return confirm('{{ t.hotspot_disable_confirm }}');">{{ t.hotspot_disable_btn }}</button>
      {% endif %}
    </div>
  </div>

  <div class="settings-card">
    <h2>{{ t.restart_heading }}</h2>
    <div class="fields">
      <button type="submit" form="restart-board" class="delete" onclick="return confirm('{{ t.restart_confirm }}');" {% if not net_status.available %}disabled{% endif %}>{{ t.restart_btn }}</button>
      {% if not net_status.available %}<span style="color:var(--text-dim); font-size:0.85rem;">{{ t.wifi_unavailable }}</span>{% endif %}
    </div>
  </div>

  <a class="back" href="{{ url_for('admin_page') }}">{{ t.back_to_admin }}</a>
</div>
</body>
</html>
"""


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

@app.route("/")
def dashboard():
    data = load_data()
    return render_template_string(DASHBOARD_HTML, settings=data["settings"], version=APP_VERSION_STRING)


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
        "app_version": APP_VERSION_STRING,
    })


@app.route("/admin", methods=["GET"])
def admin_page():
    # Dashboard title/subtitle + currency management only — system-level
    # concerns (Wi-Fi, hotspot fallback, updates, reboot) live on
    # admin_system_page(), reachable via the link in this page's top-bar.
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
    )


@app.route("/admin/system", methods=["GET"])
def admin_system_page():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    lang, t = get_translations(data)
    net_config = load_net_config()
    net_status = _read_net_status()
    wifi_slots = (net_config.get("wifi") or [])[:MAX_WIFI_SLOTS]
    # If no Wi-Fi profile has ever been saved through this panel, show
    # whatever the device is ALREADY configured with (e.g. from
    # provision-pi.sh's initial setup, or nmcli by hand) instead of blank
    # fields — discovered from the daemon's status file, SSID only (a
    # saved WPA2 secret can't be read back without privilege, which this
    # app deliberately never has). Purely a display convenience: nothing
    # is written to net_config.json until the admin actually hits Save.
    wifi_prefilled = False
    if not wifi_slots:
        known = (net_status.get("known_ssids") or [])[:MAX_WIFI_SLOTS]
        if known:
            wifi_slots = [{"ssid": s} for s in known]
            wifi_prefilled = True
    wifi_slots = wifi_slots + [{}] * (MAX_WIFI_SLOTS - len(wifi_slots))
    return render_template_string(
        SYSTEM_HTML,
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

    save_data(data)
    return redirect(url_for("admin_page", msg=t["settings_saved"]))


@app.route("/admin/toggle-auto-update", methods=["POST"])
def admin_toggle_auto_update():
    # Split out of admin_save_all() when the Updates card moved to
    # admin_system_page() — auto-update enabled/disabled is a flag FILE,
    # not a data.json field (scripts/auto-update.sh checks for this file's
    # existence directly, see its own comments), so this is the one place
    # that file gets created/removed. Auto-submits on checkbox change
    # (same pattern as the language selector), no separate save button.
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

    return redirect(url_for("admin_system_page", msg=t["check_now_started"]))


@app.route("/admin/wifi/save", methods=["POST"])
def admin_wifi_save():
    # No sudo/subprocess anywhere in this route: it only writes desired
    # state to NET_CONFIG_FILE. scripts/files/network/dashboard-net-apply.sh
    # (a separate root-run daemon) polls that file and does the actual
    # nmcli work — see the comment on NET_CONFIG_FILE near the top of this
    # file for the full design.
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_system_page", error=t["err_csrf"]))

    cfg = load_net_config()
    # Password inputs are type="password" and never pre-filled (same reason
    # ADMIN_PASSWORD itself has no admin-panel edit UI: don't echo secrets
    # back into HTML). So a blank submission for an SSID that already has a
    # saved password must mean "leave it unchanged," not "make it open" —
    # keyed by SSID (not slot position) so reordering slots doesn't lose a
    # password.
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
            # No open networks, ever: every saved slot must carry a password.
            # A blank field is purely the "keep what is already stored"
            # sentinel, and it only resolves for an SSID that is unchanged
            # AND already has a non-empty password on file — keyed by SSID, so
            # renaming or adding a network always demands its own password
            # instead of silently inheriting the previous one.
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
    # Same never-pre-filled password field as the Wi-Fi client slots above,
    # and the same rule: a blank submission means "keep the saved hotspot
    # password", but ONLY while the SSID is unchanged. Renaming the hotspot
    # requires typing its password again rather than silently carrying the
    # old one over, and an open AP is never written — WPA2-PSK needs a key.
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
    # present, removes it and calls `systemctl reboot` itself. Nothing here
    # runs as root or calls systemctl directly.
    open(REBOOT_REQUEST_FLAG, "a", encoding="utf-8").close()
    return redirect(url_for("admin_system_page", msg=t["restart_started"]))


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
        print(f"Admin panel (HTTPS): https://{socket.gethostname()}{_port_suffix(HTTPS_PORT, 443)}/admin")
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
