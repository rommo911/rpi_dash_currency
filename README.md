# Currency Dashboard

A small Flask kiosk app for a Raspberry Pi / Orange Pi: a full-screen dashboard
of currency prices that you set yourself, plus a password-protected admin panel.
No live exchange rates, no database, no build step.

## Features

- Public dashboard at `/` — auto-refreshes every 30 seconds
- Admin panel at `/admin` (HTTP Basic Auth, password from `.env`)
  - Edit each currency's name, symbol and price
  - Show/hide currencies, add new ones (flag auto-fetched or uploaded), remove them
  - Set title, subtitle, colour palette and visual effects
  - Wi-Fi, updates and reboot under `/admin/system`
- Admin UI in English and Arabic
- Admin served over HTTPS (self-signed cert); the dashboard stays on plain HTTP
- Optional auto-update from git, and an emergency Wi-Fi hotspot fallback

## Quick start (any Linux machine)

```bash
cp .env.example .env            # then set ADMIN_PASSWORD in .env
cp data.default.json data.json
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python app.py
```

- Dashboard: `http://<host>/`
- Admin: `http://<host>/admin` (any username, password from `.env`)

On Windows, run `scripts\run-local-windows.bat` instead.
Ports can be changed with `APP_PORT` / `HTTPS_PORT`.

## Deploy to a Raspberry Pi / Orange Pi Zero 3

Flash Raspberry Pi OS or Armbian, SSH in, then:

```bash
scp scripts/provision-pi.sh <user>@<board-ip>:~
ssh <user>@<board-ip>
bash provision-pi.sh            # add --auto_default to skip all prompts
```

The script chain does the rest:

| Stage | Script | Does |
|---|---|---|
| 1 | `provision-pi.sh` | Gets online, clones the repo |
| 2 | `harden-system.sh` | Updates, firewall, SSH/fail2ban, log limits |
| 3 | `deploy-dashboard.sh` | venv, HTTPS cert, systemd service, updater, kiosk |

`deploy-dashboard.sh` is also safe to re-run on its own to redeploy.
Boards with a display boot straight into a fullscreen Chromium;
Pi Zero boards run headless.

## Project layout

```
app.py          entrypoint          config.py    paths and limits
core.py         Flask instance      i18n.py      admin UI translations
helpers/        storage, validation, security, flags
routes/         dashboard, admin, admin_system
templates/      Jinja pages         static/      CSS, JS, flags
scripts/        provisioning + installed config files (scripts/files/)
```

## Security

Built for a trusted home LAN: login lockout, fail2ban jail, CSRF tokens and
security headers are included, but it is not a substitute for real
authentication. Set a strong `ADMIN_PASSWORD` and don't expose it to the internet.

## More

See [NOTES.md](NOTES.md) for the detailed provisioning steps, HTTPS,
updates, logging, headless boards and the Armbian checklist.
