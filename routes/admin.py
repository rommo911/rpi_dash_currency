"""Admin routes: dashboard title/settings + currency management. System
concerns (Wi-Fi, hotspot, updates, reboot) live in routes/admin_system.py.
"""
import re

from flask import abort, redirect, render_template, request, url_for

from config import (
    DEFAULT_PALETTE, MAX_CODE_LEN, MAX_NAME_LEN, MAX_PRICE_VALUE, MAX_SUBTITLE_LEN, MAX_SYMBOL_LEN,
    MAX_TITLE_LEN, PALETTE_CHOICES,
)
from core import app
from helpers.flags import fetch_suggested_flag, save_uploaded_flag, delete_flag_file
from helpers.security import check_csrf, csrf_token, require_admin_auth
from helpers.remote import get_source
from helpers.storage import (
    LAYOUTS, MATRIX_MIN_ROWS, MAX_ROW_CURRENCIES, MIN_ROW_CURRENCIES, ROWS, ensure_min_matrix_rows,
    find_currency, find_matrix_currency, load_data, norm_matrix, rows_to_matrix, save_data,
)
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
        rows=data["rows"],
        matrix=data.get("matrix"),
        layout=data["settings"]["layout"],
        matrix_min_rows=MATRIX_MIN_ROWS,
        min_row=MIN_ROW_CURRENCIES,
        max_row=MAX_ROW_CURRENCIES,
        settings=data["settings"],
        source=get_source(),
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

    def fail(msg):
        return redirect(url_for("admin_page", error=msg))

    if data["settings"]["layout"] == "matrix":
        return _save_matrix(data, t, fail)

    # Validate everything before writing anything, so a bad field doesn't
    # leave rows half-updated.
    new_rows = []
    for n, row in enumerate(data["rows"]):
        p = f"r{n}_"
        label = f"{t['row_heading'].format(n=n + 1)}: "
        title = clean_text(request.form.get(p + "title"), MAX_TITLE_LEN)
        if title is None:
            return fail(label + t["err_too_long"].format(field=t["field_title"], max=MAX_TITLE_LEN))
        subtitle = clean_text(request.form.get(p + "subtitle"), MAX_SUBTITLE_LEN)
        if subtitle is None:
            return fail(label + t["err_too_long"].format(field=t["field_subtitle"], max=MAX_SUBTITLE_LEN))
        enabled = p + "enabled" in request.form
        if enabled and not title:
            return fail(label + t["err_title_required"])
        if enabled and len(row["currencies"]) < MIN_ROW_CURRENCIES:
            return fail(label + t["err_row_count"].format(min=MIN_ROW_CURRENCIES, max=MAX_ROW_CURRENCIES))
        updates = []
        for c in row["currencies"]:
            code = c["code"]
            name_val = clean_text(request.form.get(f"{p}name_{code}"), MAX_NAME_LEN)
            symbol_val = clean_text(request.form.get(f"{p}symbol_{code}"), MAX_SYMBOL_LEN)
            price_raw = request.form.get(f"{p}price_{code}", "")
            if name_val is None:
                return fail(label + t["err_too_long"].format(field=f"{code} {t['name_ph']}", max=MAX_NAME_LEN))
            if symbol_val is None:
                return fail(label + t["err_too_long"].format(field=f"{code} {t['symbol_ph']}", max=MAX_SYMBOL_LEN))
            if not name_val or not price_raw:
                return fail(label + t["err_missing_fields"].format(code=code))
            price_val = parse_price(price_raw)
            if price_val is None:
                return fail(label + t["err_invalid_price"].format(code=code, max=f"{MAX_PRICE_VALUE:,}"))
            updates.append({**c, "name": name_val, "symbol": symbol_val, "price": price_val,
                            "enabled": f"{p}enabled_{code}" in request.form})
        new_rows.append({"enabled": enabled, "title": title, "subtitle": subtitle, "currencies": updates})
    if not any(r["enabled"] for r in new_rows):
        return fail(t["err_no_row_enabled"])

    data["rows"] = new_rows
    _save_common_settings(data)
    save_data(data)
    return redirect(url_for("admin_page", msg=t["settings_saved"]))


def _save_common_settings(data):
    palette = request.form.get("color_palette", DEFAULT_PALETTE)
    if palette not in PALETTE_CHOICES:
        palette = DEFAULT_PALETTE
    data["settings"]["color_palette"] = palette
    data["settings"]["show_updated_at"] = "show_updated_at" in request.form
    for fx in ("fx_glass", "fx_scan", "fx_flash", "fx_glow"):
        data["settings"][fx] = fx in request.form


def _save_matrix(data, t, fail):
    """Matrix layout: shared currencies (m_*) + per-row title/subtitle/prices (mr<n>_*)."""
    m = data["matrix"]
    defs = []
    for c in m["currencies"]:
        code = c["code"]
        name_val = clean_text(request.form.get(f"m_name_{code}"), MAX_NAME_LEN)
        symbol_val = clean_text(request.form.get(f"m_symbol_{code}"), MAX_SYMBOL_LEN)
        if name_val is None:
            return fail(t["err_too_long"].format(field=f"{code} {t['name_ph']}", max=MAX_NAME_LEN))
        if symbol_val is None:
            return fail(t["err_too_long"].format(field=f"{code} {t['symbol_ph']}", max=MAX_SYMBOL_LEN))
        if not name_val:
            return fail(t["err_missing_fields"].format(code=code))
        defs.append({**c, "name": name_val, "symbol": symbol_val, "enabled": f"m_enabled_{code}" in request.form})
    rows = []
    for n, row in enumerate(m["rows"]):
        p = f"mr{n}_"
        label = f"{t['row_heading'].format(n=n + 1)}: "
        title = clean_text(request.form.get(p + "title"), MAX_TITLE_LEN)
        if title is None:
            return fail(label + t["err_too_long"].format(field=t["field_title"], max=MAX_TITLE_LEN))
        subtitle = clean_text(request.form.get(p + "subtitle"), MAX_SUBTITLE_LEN)
        if subtitle is None:
            return fail(label + t["err_too_long"].format(field=t["field_subtitle"], max=MAX_SUBTITLE_LEN))
        enabled = p + "enabled" in request.form
        if enabled and not title:
            return fail(label + t["err_title_required"])
        prices = {}
        for c in defs:
            raw = request.form.get(f"{p}price_{c['code']}", "")
            if not raw and not enabled:
                prices[c["code"]] = row["prices"].get(c["code"], 0)  # a switched-off row may leave prices empty
                continue
            price = parse_price(raw)
            if price is None:
                return fail(label + t["err_invalid_price"].format(code=c["code"], max=f"{MAX_PRICE_VALUE:,}"))
            prices[c["code"]] = price
        rows.append({"enabled": enabled, "title": title, "subtitle": subtitle, "prices": prices})
    if sum(r["enabled"] for r in rows) < MATRIX_MIN_ROWS:
        return fail(t["err_matrix_rows"].format(min=MATRIX_MIN_ROWS))
    data["matrix"] = {"currencies": defs, "rows": rows}
    _save_common_settings(data)
    save_data(data)
    return redirect(url_for("admin_page", msg=t["settings_saved"]))


@app.route("/admin/layout", methods=["POST"])
def admin_layout():
    """Switch between the card layout and the matrix layout; each keeps its own data."""
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    mode = request.form.get("layout")
    if mode not in LAYOUTS:
        abort(400)
    if mode == "matrix":
        m = data.get("matrix") or norm_matrix(rows_to_matrix(data["rows"]))  # first time: seeded from the card rows
        if len(m["currencies"]) < MIN_ROW_CURRENCIES:
            return redirect(url_for("admin_page", error=t["err_matrix_count"].format(min=MIN_ROW_CURRENCIES, max=MAX_ROW_CURRENCIES)))
        ensure_min_matrix_rows(m)
        data["matrix"] = m
    data["settings"]["layout"] = mode
    save_data(data)
    return redirect(url_for("admin_page", msg=t["layout_switched"]))


def _flag_unused(data, code):
    """True when no row of either layout still uses this currency code (flags are shared by code)."""
    return not (any(find_currency(data, n, code) for n in range(ROWS))
                or (data.get("matrix") and find_matrix_currency(data, code)))


@app.route("/admin/row/<int:row>/currency/<code>/delete", methods=["POST"])
def admin_delete_currency(row, code):
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    if not 0 <= row < ROWS:
        abort(404)
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    c = find_currency(data, row, code)
    if not c:
        return redirect(url_for("admin_page", error=t["err_not_found"].format(code=code)))
    r = data["rows"][row]
    if r["enabled"] and len(r["currencies"]) <= MIN_ROW_CURRENCIES:
        return redirect(url_for("admin_page", error=t["err_row_count"].format(min=MIN_ROW_CURRENCIES, max=MAX_ROW_CURRENCIES)))
    r["currencies"] = [x for x in r["currencies"] if x["code"] != code]
    save_data(data)
    # The flag file is shared by code: only delete it when no row still uses it.
    if _flag_unused(data, code):
        delete_flag_file(c.get("flag"))
    return redirect(url_for("admin_page", msg=f"{code}{t['removed_suffix']}"))


@app.route("/admin/row/<int:row>/currency/add", methods=["POST"])
def admin_add_currency(row):
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    if not 0 <= row < ROWS:
        abort(404)

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

    if len(data["rows"][row]["currencies"]) >= MAX_ROW_CURRENCIES:
        return redirect(url_for("admin_page", error=t["err_row_full"].format(max=MAX_ROW_CURRENCIES)))
    if find_currency(data, row, code):
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

    data["rows"][row]["currencies"].append({
        "code": code,
        "name": name,
        "symbol": symbol,
        "price": price,
        "flag": flag_path,
        "enabled": True,
    })
    save_data(data)
    return redirect(url_for("admin_page", msg=f"{code}{t['added_suffix']}"))


@app.route("/admin/matrix/currency/<code>/delete", methods=["POST"])
def admin_matrix_delete(code):
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    m = data.get("matrix")
    c = m and find_matrix_currency(data, code)
    if not c:
        return redirect(url_for("admin_page", error=t["err_not_found"].format(code=code)))
    if len(m["currencies"]) <= MIN_ROW_CURRENCIES:
        return redirect(url_for("admin_page", error=t["err_matrix_count"].format(min=MIN_ROW_CURRENCIES, max=MAX_ROW_CURRENCIES)))
    m["currencies"] = [x for x in m["currencies"] if x["code"] != code]
    for r in m["rows"]:
        r["prices"].pop(code, None)
    save_data(data)
    if _flag_unused(data, code):
        delete_flag_file(c.get("flag"))
    return redirect(url_for("admin_page", msg=f"{code}{t['removed_suffix']}"))


@app.route("/admin/matrix/currency/add", methods=["POST"])
def admin_matrix_add():
    unauthorized = require_admin_auth()
    if unauthorized:
        return unauthorized
    data = load_data()
    _, t = get_translations(data)
    if not check_csrf():
        return redirect(url_for("admin_page", error=t["err_csrf"]))
    m = data.get("matrix")
    if not m:
        abort(400)

    def fail(msg):
        return redirect(url_for("admin_page", error=msg))

    code = re.sub(r"[^A-Za-z0-9]", "", request.form.get("code", "")).upper()[:MAX_CODE_LEN]
    name = clean_text(request.form.get("name"), MAX_NAME_LEN)
    symbol = clean_text(request.form.get("symbol"), MAX_SYMBOL_LEN)
    price = parse_price(request.form.get("price", ""))
    if not code:
        return fail(t["err_invalid_code"])
    if name is None:
        return fail(t["err_too_long"].format(field=t["name_ph"], max=MAX_NAME_LEN))
    if symbol is None:
        return fail(t["err_too_long"].format(field=t["symbol_ph"], max=MAX_SYMBOL_LEN))
    if not name:
        return fail(t["err_code_required"])
    if price is None:
        return fail(t["err_invalid_price"].format(code=code, max=f"{MAX_PRICE_VALUE:,}"))
    if len(m["currencies"]) >= MAX_ROW_CURRENCIES:
        return fail(t["err_row_full"].format(max=MAX_ROW_CURRENCIES))
    if find_matrix_currency(data, code):
        return fail(t["err_code_exists"].format(code=code))

    if request.form.get("flag_source", "auto") == "upload" and "flag_file" in request.files and request.files["flag_file"].filename:
        flag_path = save_uploaded_flag(code, request.files["flag_file"])
        if not flag_path:
            return fail(t["err_unsupported_image"])
    else:
        flag_path = fetch_suggested_flag(code)
        if not flag_path:
            return fail(t["err_flag_fetch_failed"].format(code=code))

    m["currencies"].append({"code": code, "name": name, "symbol": symbol, "flag": flag_path, "enabled": True})
    for r in m["rows"]:
        r["prices"][code] = price
    save_data(data)
    return redirect(url_for("admin_page", msg=f"{code}{t['added_suffix']}"))
