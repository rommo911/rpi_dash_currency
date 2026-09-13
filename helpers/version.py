"""App version string shown in the admin panel: VERSION file + git commit."""
import subprocess

from config import APP_DIR, VERSION_FILE


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
