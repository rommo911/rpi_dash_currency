"""Flag icon handling: auto-suggest from flagcdn.com, or admin upload."""
import os
import urllib.request

from werkzeug.utils import secure_filename

from config import ALLOWED_FLAG_EXTS, APP_DIR, FLAGS_DIR

# ISO-4217 code -> ISO-3166 country code, for currencies where "first two
# letters" doesn't hold. Extend as needed.
COUNTRY_OVERRIDES = {
    "EUR": "eu",
    "XOF": "sn",  # West African CFA franc - no single flag, default to a member state
    "XAF": "cm",  # Central African CFA franc - same idea
}


def guess_country_code(currency_code):
    return COUNTRY_OVERRIDES.get(currency_code, currency_code[:2].lower())


def fetch_suggested_flag(currency_code):
    """Download a flag PNG for this currency code. Web path on success,
    None on failure (caller should ask for an upload instead)."""
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
    real_path = os.path.abspath(os.path.join(APP_DIR, flag_path.lstrip("/")))
    if os.path.commonpath([real_path, FLAGS_DIR]) == FLAGS_DIR and os.path.isfile(real_path):
        try:
            os.remove(real_path)
        except OSError:
            pass
