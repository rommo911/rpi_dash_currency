# Currency Dashboard

Single-file Flask app. Dashboard shows a static amount in a chosen base
currency (SYP, USD, EUR, or TRY) converted live to the other three via
[open.er-api.com](https://open.er-api.com) (free, no API key). There's no
link to it from the dashboard — go to `/admin` directly, it's password
protected (HTTP Basic Auth, password in `config.py`) to change the base
currency and amount. Rates are cached 5 minutes server-side; the dashboard
page polls `/api/data` every 30s, so any change made in `/admin` — from any
browser on the network — shows up on the Pi's screen within 30 seconds
automatically, no refresh needed.

To add more currencies later, extend the `CURRENCIES` dict at the top of
`app.py` with the ISO code, flag emoji, and symbol — the dashboard and admin
form pick it up automatically.

## Files

- `app.py` — the whole app (backend + embedded HTML/CSS/JS)
- `config.py` — `ADMIN_PASSWORD` for `/admin` — **change this before
  deploying**
- `data.json` — persisted base currency + amount, edited via `/admin`
- `requirements.txt` — just Flask
- `static/flags/` — local PNG flag icons (SYP/USD/EUR/TRY)
- `scripts/provision-pi.sh` — one-time hardening for a **fresh SD card**
  (updates, new user, firewall, SSH hardening, fail2ban)
- `scripts/deploy-dashboard.sh` — clones this repo, sets up the venv,
  installs the systemd service, and configures kiosk boot

## 1. Test now on your homelab machine

```bash
cd /home/rami/remote_ws/rpi_dash_currency
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python app.py
```

Then from any browser on your LAN:

- Dashboard: `http://<homelab-ip>:5000/`
- Control panel: `http://<homelab-ip>:5000/admin` — enter any username and
  the password from `config.py` (default `changeme123`, change it)

Find `<homelab-ip>` with `hostname -I` on the homelab box. Stop the app with
Ctrl+C when done testing.

### Optional: run it persistently on the homelab (systemd only, no kiosk)

```bash
REPO_URL=https://github.com/<you>/rpi_dash_currency.git \
INSTALL_DIR="$PWD" \
  bash scripts/deploy-dashboard.sh
```

This installs the systemd service and also sets up kiosk autostart for
whatever desktop the machine has — skip that part if you just want the
service. It's meant for the Pi, but works on any Debian-based box.

## 2. Deploying to a Raspberry Pi (fresh SD card → running kiosk)

Two scripts, run in order.

### Step 1 — `scripts/provision-pi.sh` (once, right after first boot)

Flash Raspberry Pi OS, boot it, SSH in as the default user, then either
clone the repo or just copy this one script over and run it:

```bash
scp scripts/provision-pi.sh pi@<pi-ip>:~
ssh pi@<pi-ip>
chmod +x provision-pi.sh
./provision-pi.sh
```

It interactively:

1. Updates and upgrades all system packages
2. Optionally creates a new sudo user and locks the old one's password
   (prompts before locking anything)
3. Optionally sets a new hostname
4. Optionally scans for nearby Wi-Fi networks (via `nmcli`) and connects to
   one you pick, with a choice of DHCP or a static IP (address, gateway,
   DNS) — then verifies the link came up and that it can reach the
   internet
5. Installs and enables **ufw**, default-deny incoming, opens SSH (22) and
   the dashboard port (5000) — optionally restricted to a LAN subnet you
   specify
6. Hardens `sshd`: disables root login, keeps **password auth on** (as
   requested — fail2ban covers brute-force risk), tightens `MaxAuthTries`
   and `LoginGraceTime`
7. Installs and enables **fail2ban** with an `sshd` jail (5 tries / 10 min →
   1 hour ban)
8. Enables **unattended-upgrades** for automatic security patches

At the end it prints the dashboard URL (`http://<hostname>.local:<port>/`,
plus the Wi-Fi IP if configured) for once you've deployed the app. Reboot
when it finishes, then log back in as whichever user you kept.

### Step 2 — `scripts/deploy-dashboard.sh` (installs + boots to kiosk)

```bash
REPO_URL=https://github.com/<you>/rpi_dash_currency.git \
  bash scripts/deploy-dashboard.sh
```

(Or clone the repo first and run it from inside — either works; it's
idempotent, safe to re-run any time to pull updates.)

It:

1. Installs `git`, `python3-venv`, `curl`, and Chromium if missing
2. Clones (or pulls) this repo into `~/currency-dashboard`
3. Creates a venv and installs `requirements.txt`
4. Installs and enables the `currency-dashboard` systemd service
5. Detects the desktop stack — **labwc**/**wayfire** (Raspberry Pi OS
   Bookworm), **LXDE** (older Pi OS with Desktop), or console-only
   (**Pi OS Lite**) — and configures kiosk-mode Chromium autostart for
   whichever is present, plus autologin via `raspi-config`

```bash
sudo reboot
```

The Pi should come up straight into fullscreen Chromium showing the
dashboard, with the Flask service already running underneath.

Check the service any time with:

```bash
sudo systemctl status currency-dashboard
```

## Notes

- `/admin` is protected by a single hardcoded password in `config.py`
  (HTTP Basic Auth — any username, that password). Fine for a trusted home
  LAN; change the default before deploying. If you ever want it reachable
  outside your network, put it behind a reverse proxy with proper auth too,
  and restrict the firewall rule to your LAN subnet in `provision-pi.sh`.
- SSH password auth is left on per request; fail2ban mitigates brute-force
  attempts. For stronger security later, copy an SSH key over and switch
  `PasswordAuthentication` to `no` in `/etc/ssh/sshd_config`.
- Most free FX APIs don't accept SYP/TRY as a `base` currency, so the app
  always pivots through USD internally regardless of which currency you
  pick as the dashboard's base.
