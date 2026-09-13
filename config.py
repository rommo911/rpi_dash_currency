"""Paths and constants shared across the app. Pure config — no logic."""
import os

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

# scripts/auto-update.sh polls these two flag files; presence/absence *is*
# the state, no content is read. ENABLED = admin's "auto-update" checkbox.
# CHECK_NOW = one-shot "check now" button, deleted by the script after one run.
AUTO_UPDATE_ENABLED_FLAG = os.path.join(APP_DIR, "auto-update.enabled")
AUTO_UPDATE_CHECK_NOW_FLAG = os.path.join(APP_DIR, "auto-update.check-now")
SERVICE_NAME = "currency-dashboard"

# This app never holds sudo. These are plain files describing DESIRED
# state; scripts/files/network/dashboard-net-apply.sh (root daemon) polls
# them and does the real nmcli/systemctl work, then publishes OBSERVED
# state to NET_STATUS_FILE for the app to read back.
NET_CONFIG_FILE = os.path.join(APP_DIR, "net_config.json")
REBOOT_REQUEST_FLAG = os.path.join(APP_DIR, "reboot.request")
NET_STATUS_FILE = "/run/dashboard-net/status.json"

APP_PORT = int(os.environ.get("APP_PORT", "80"))
HTTPS_PORT = int(os.environ.get("HTTPS_PORT", "443"))
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
if not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_PASSWORD is not set; configure the project .env file before starting the app")

# Best-effort guess from file presence; app.py sets this for real once it
# has actually confirmed the HTTPS listener bound. Mutated after import —
# always access as `config.HTTPS_ENABLED`, never `from config import
# HTTPS_ENABLED` (that copies the value once and misses the later update).
HTTPS_ENABLED = os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE)

# Admin login lockout: N failures from one IP within WINDOW seconds blocks
# that IP. In-memory, resets on restart — fine for a single-instance Pi
# app. fail2ban is the firewall-level backstop (see helpers/security.py).
ADMIN_MAX_FAILURES = 3
ADMIN_LOCKOUT_WINDOW = 300  # seconds

# Character caps (not bytes — fair to Arabic too).
MAX_TITLE_LEN = 80
MAX_SUBTITLE_LEN = 140
MAX_NAME_LEN = 25
MAX_SYMBOL_LEN = 3
MAX_CODE_LEN = 5
MAX_PRICE_RAW_LEN = 8
MAX_PRICE_VALUE = 1_000_000  # comfortably above any real price; guards against typos/overflow

MAX_SSID_LEN = 32  # 802.11 SSID byte cap, treated as chars here (ASCII in practice)
MIN_WIFI_PASS_LEN = 8
MAX_WIFI_PASS_LEN = 63  # WPA2-PSK bounds
MAX_WIFI_SLOTS = 2
