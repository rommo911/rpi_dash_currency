"""Logging config: errors only, everywhere, on purpose — matches the
system-wide journald policy (see harden-system.sh). Routine request
logging is off entirely; only real problems get logged, in two places:
journald (via the root logger) and a dedicated rotating file.

security_log uses .error() (not .warning()) deliberately: journald's
MaxLevelStore=err drops anything lower from being stored at all, and the
fail2ban jail depends on this exact message reaching the journal.
"""
import logging
import os
from logging.handlers import TimedRotatingFileHandler

from config import LOG_DIR, LOG_FILE

logging.basicConfig(level=logging.ERROR, format="%(asctime)s %(message)s")
logging.getLogger("werkzeug").setLevel(logging.ERROR)

os.makedirs(LOG_DIR, exist_ok=True)
_file_handler = TimedRotatingFileHandler(LOG_FILE, when="midnight", backupCount=7, encoding="utf-8")
_file_handler.setLevel(logging.ERROR)
_file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
logging.getLogger().addHandler(_file_handler)

security_log = logging.getLogger("admin-auth")
security_log.setLevel(logging.ERROR)
