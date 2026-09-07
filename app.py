#!/usr/bin/env python3
"""Currency dashboard: a static, admin-managed price per currency — no live
conversion, no external API calls at runtime.

Single-file Flask app: dashboard at /, password-protected control panel at
/admin. Admin can add/remove/enable/disable currencies and set each one's
price by hand. Flag icons are stored locally under static/flags/ — either
auto-fetched once from flagcdn.com by guessing the ISO country code from the
currency code, or uploaded by the admin. Everything persists to data.json.
"""
import json
import math
import os
import re
import time
import unicodedata
import urllib.request

from flask import Flask, Response, jsonify, redirect, render_template_string, request, url_for
from werkzeug.utils import secure_filename

import config

APP_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(APP_DIR, "data.json")
FLAGS_DIR = os.path.join(APP_DIR, "static", "flags")
ALLOWED_FLAG_EXTS = {"png", "jpg", "jpeg", "webp", "svg"}

# Length limits are in *characters* (Python strings are code points, so this
# is fair to Arabic too — combining marks aside, a name like "الليرة
# السورية الجديدة" is ~24 characters, well under any of these caps).
MAX_TITLE_LEN = 80
MAX_SUBTITLE_LEN = 140
MAX_NAME_LEN = 60
MAX_SYMBOL_LEN = 6
MAX_CODE_LEN = 8
MAX_PRICE_RAW_LEN = 24
MAX_PRICE_VALUE = 1_000_000_000_000  # 1e12 — comfortably above any real price, guards against typos/overflow

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
        "code_ph": "الرمز (مثال: GBP)",
        "name_req_ph": "الاسم",
        "symbol_opt_ph": "الرمز (اختياري)",
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
    },
}

app = Flask(__name__)
os.makedirs(FLAGS_DIR, exist_ok=True)


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

def require_admin_auth():
    auth = request.authorization
    if not auth or auth.password != config.ADMIN_PASSWORD:
        return Response(
            "Authentication required.",
            401,
            {"WWW-Authenticate": 'Basic realm="Admin Panel"'},
        )
    return None


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
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: radial-gradient(circle at 20% 20%, var(--bg-2), var(--bg-1) 60%);
    color: var(--text-main);
    padding: 24px;
  }
  .wrap { width: 94vw; max-width: 2000px; min-width: 320px; }
  .header { text-align: center; margin-bottom: 44px; }
  .header h1 {
    font-size: clamp(2.2rem, 4.2vw, 3.4rem);
    margin: 0 0 12px;
    font-weight: 800;
    letter-spacing: -0.02em;
  }
  .header .sub { color: var(--text-dim); font-size: clamp(1.1rem, 1.6vw, 1.5rem); }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 28px;
  }
  .empty {
    text-align: center;
    color: var(--text-dim);
    font-size: 1.2rem;
    padding: 60px 20px;
    border: 1px dashed var(--card-border);
    border-radius: 24px;
  }
  .card {
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 28px;
    padding: 48px 32px;
    backdrop-filter: blur(12px);
    transition: transform 0.2s ease;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 18px;
    min-height: 38vh;
  }
  .card:hover { transform: translateY(-4px); }
  .icon-badge {
    width: 140px;
    height: 96px;
    border-radius: 16px;
    overflow: hidden;
    box-shadow: 0 8px 24px -8px rgba(0,0,0,0.5), 0 0 0 1px var(--card-border);
    background: rgba(255,255,255,0.05);
  }
  .icon-badge img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .card .code {
    font-size: 1.3rem;
    color: var(--text-main);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    font-weight: 700;
  }
  .card .name { font-size: 1.1rem; color: var(--text-dim); margin-top: -14px; }
  .card .value {
    font-size: clamp(2rem, 3.4vw, 2.8rem);
    font-weight: 800;
    letter-spacing: -0.01em;
    word-break: break-word;
    color: var(--accent);
  }
  .footer { margin-top: 36px; text-align: center; color: var(--text-dim); font-size: 1rem; }
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <h1 id="dash-title">{{ settings.title }}</h1>
    <div class="sub" id="dash-subtitle">{{ settings.subtitle }}</div>
  </div>

  <div id="grid-wrap"></div>

  <div class="footer" id="footer" {% if not settings.show_updated_at %}hidden{% endif %}><div id="updated-at">Loading&hellip;</div></div>
</div>

<script>
let lastUpdatedAt = null;

function fmt(n) {
  if (n === null || n === undefined) return '—';
  return Number(n).toLocaleString(undefined, {maximumFractionDigits: 2});
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

async function refresh() {
  try {
    const res = await fetch('/api/data');
    const d = await res.json();

    if (d.updated_at === lastUpdatedAt) {
      return; // nothing changed since last poll — skip the re-render
    }
    lastUpdatedAt = d.updated_at;

    document.getElementById('dash-title').textContent = d.title || '';
    document.getElementById('dash-subtitle').textContent = d.subtitle || '';

    const wrap = document.getElementById('grid-wrap');
    if (!d.currencies || d.currencies.length === 0) {
      wrap.innerHTML = '<div class="empty">No currencies enabled. Add or enable some from the control panel.</div>';
    } else {
      const grid = document.createElement('div');
      grid.className = 'grid';
      d.currencies.forEach(c => {
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
    }

    document.getElementById('footer').hidden = !d.show_updated_at;
    const updated = document.getElementById('updated-at');
    if (d.updated_at) {
      const dt = new Date(d.updated_at * 1000);
      updated.textContent = 'Last updated ' + dt.toLocaleTimeString();
    }
  } catch (e) {
    document.getElementById('updated-at').textContent = 'Could not load data';
  }
}

refresh();
setInterval(refresh, 3000);
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
  input[name=symbol] { width: 60px; }
  input[name=price] { width: 130px; }
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
  .add-card .fields input[name=code] { width: 90px; text-transform: uppercase; }
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
  <form id="delete-{{ c.code }}" method="post" action="{{ url_for('admin_delete_currency', code=c.code) }}"></form>
  {% endfor %}

  <form method="post" action="{{ url_for('admin_save_all') }}">
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
        <input type="number" name="price_{{ c.code }}" value="{{ c.price }}" step="any" min="0" max="{{ max_price_value }}" placeholder="{{ t.price_ph }}" required>
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
      <div class="fields">
        <input type="text" name="code" placeholder="{{ t.code_ph }}" maxlength="{{ max_code_len }}" required>
        <input type="text" name="name" placeholder="{{ t.name_req_ph }}" maxlength="{{ max_name_len }}" required>
        <input type="text" name="symbol" placeholder="{{ t.symbol_opt_ph }}" maxlength="{{ max_symbol_len }}">
        <input type="number" name="price" placeholder="{{ t.price_req_ph }}" step="any" min="0" max="{{ max_price_value }}" required>
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
    )


@app.route("/admin/language", methods=["POST"])
def admin_set_language():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
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


@app.route("/admin/currency/<code>/delete", methods=["POST"])
def admin_delete_currency(code):
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
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
    app.run(host="0.0.0.0", port=5000, debug=False)
