"""Input validation for admin-submitted text, prices, and Wi-Fi fields."""
import math
import re
import unicodedata

from config import MAX_PRICE_RAW_LEN, MAX_PRICE_VALUE, MAX_SSID_LEN, MAX_WIFI_PASS_LEN, MIN_WIFI_PASS_LEN


def clean_text(raw, max_len):
    """Strip control chars, collapse whitespace, cap length. None if too
    long — caller reports that rather than silently truncating."""
    if raw is None:
        return ""
    cleaned = "".join(ch for ch in raw if ch == " " or unicodedata.category(ch)[0] != "C")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if len(cleaned) > max_len:
        return None
    return cleaned


def parse_price(raw):
    """None unless a valid, finite, non-negative, bounded number."""
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
    """Same rules as clean_text(), plus: reject a leading '-' (nmcli can
    mistake it for a flag). Empty is allowed — an empty slot is unused."""
    cleaned = clean_text(raw, MAX_SSID_LEN)
    if cleaned is None or cleaned.startswith("-"):
        return None
    return cleaned


def validate_wifi_password(raw):
    """Empty or MIN-MAX chars, else None. Empty means "field left alone",
    not "open network" — callers resolve that to the saved password or an error."""
    if raw is None:
        return ""
    cleaned = "".join(ch for ch in raw if unicodedata.category(ch)[0] != "C")
    if not cleaned:
        return ""
    if len(cleaned) < MIN_WIFI_PASS_LEN or len(cleaned) > MAX_WIFI_PASS_LEN:
        return None
    return cleaned
