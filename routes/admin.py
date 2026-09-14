"""Admin routes: dashboard title/settings + currency management. System
concerns (Wi-Fi, hotspot, updates, reboot) live in routes/admin_system.py.
"""
import re

from flask import redirect, render_template, request, url_for

from config import (
    DEFAULT_PALETTE, MAX_CODE_LEN, MAX_NAME_LEN, MAX_PRICE_VALUE, MAX_SUBTITLE_LEN, MAX_SYMBOL_LEN,
    MAX_TITLE_LEN, PALETTE_CHOICES,
)
from core import app
from helpers.flags import fetch_suggested_flag, save_uploaded_flag, delete_flag_file
from helpers.security import check_csrf, csrf_token, require_admin_auth
from helpers.storage import find_currency, load_data, save_data
from helpers.validation import clean_text, parse_price
from i18n import TRANSLATIONS, get_translations


@app.route("/admin", methods=["GET"])
def admin_page():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    lang, t = get_translations(data)
    return render_template(
        "admin.html",
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
        palette_options=[(pid, t[f"palette_{pid}"]) for pid in PALETTE_CHOICES],
        csrf_token=csrf_token(),
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

    palette = request.form.get("color_palette", DEFAULT_PALETTE)
    if palette not in PALETTE_CHOICES:
        palette = DEFAULT_PALETTE

    data["settings"]["title"] = title
    data["settings"]["subtitle"] = subtitle
    data["settings"]["color_palette"] = palette
    data["settings"]["show_updated_at"] = "show_updated_at" in request.form
    data["settings"]["fx_glass"] = "fx_glass" in request.form
    data["settings"]["fx_scan"] = "fx_scan" in request.form
    data["settings"]["fx_flash"] = "fx_flash" in request.form
    data["settings"]["fx_glow"] = "fx_glow" in request.form

    save_data(data)
    return redirect(url_for("admin_page", msg=t["settings_saved"]))


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
