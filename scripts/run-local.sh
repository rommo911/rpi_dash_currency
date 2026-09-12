#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PY_CMD="python3"
if ! command -v "$PY_CMD" >/dev/null 2>&1; then
  echo "Python3 was not found on PATH. Install it from https://www.python.org/downloads/ and re-run this script."
  exit 1
fi

if [ ! -x ".venv/bin/python" ]; then
  echo "Creating virtual environment in .venv ..."
  "$PY_CMD" -m venv .venv
fi

echo "Installing/updating dependencies ..."
.venv/bin/python -m pip install --upgrade pip >/dev/null
.venv/bin/python -m pip install -r requirements.txt

if [ ! -f data.json ]; then
  if [ -f data.default.json ]; then
    echo "Creating data.json from data.default.json ..."
    cp data.default.json data.json
  else
    echo "Warning: data.default.json not found; creating empty data.json"
    printf '%s' '{"currencies":[],"settings":{},"updated_at":0}' > data.json
  fi
fi

if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    echo "Creating .env from .env.example ..."
    cp .env.example .env
  else
    touch .env
  fi
fi

# Export variables from .env into the environment for the Python process.
# Uses a simple, local-only source; .env is expected to be KEY=VALUE lines.
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  . .env
  set +a
fi

if [ -z "${ADMIN_PASSWORD-}" ]; then
  echo "ERROR: ADMIN_PASSWORD is not set in .env; configure it before starting the app"
  echo "Create or edit .env and add a line like: ADMIN_PASSWORD=changeme123"
  exit 1
fi

export APP_PORT="${APP_PORT:-5000}"
export HTTPS_PORT="${HTTPS_PORT:-5443}"

echo
echo "Starting the dashboard ..."
echo "  Dashboard: http://127.0.0.1:${APP_PORT}/"
echo "  Admin:     http://127.0.0.1:${APP_PORT}/admin  (HTTP only here - HTTPS is set up by scripts/deploy-dashboard.sh on the Pi)"
echo "Press Ctrl+C to stop."
echo

exec env APP_PORT="$APP_PORT" HTTPS_PORT="$HTTPS_PORT" .venv/bin/python app.py
