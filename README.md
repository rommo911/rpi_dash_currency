# Currency Dashboard

Single-file Flask app showing a set of currencies with **static, manually
set prices** — no live conversion, no external API calls at runtime. There's
no link to it from the dashboard — go to `/admin` directly; it's password
protected (HTTP Basic Auth, password in `config.py`).

From `/admin` you can:

- Edit each currency's name, symbol, and price
- Enable/disable which currencies show on the dashboard (checkbox, no delete
  needed)
- Add a new currency — enter its code (e.g. `GBP`), name, symbol, and price,
  and either let the app auto-suggest a flag icon (guessed from the currency
  code, fetched once from flagcdn.com and stored locally) or upload your own
  image
- Remove a currency (also deletes its stored flag image)

Everything persists to `data.json`. The dashboard page polls `/api/data`
every 30s, so any change made in `/admin` — from any browser on the network
— shows up automatically within 30 seconds, no refresh needed.

Ships with 4 default currencies: **SYP** (new Syrian pound flag),
**USD**, **EUR**, **TRY**.

## Files

- `app.py` — the whole app (backend + embedded HTML/CSS/JS)
- `config.py` — `ADMIN_PASSWORD` for `/admin` — **change this before
  deploying**
- `data.json` — persisted currency list, edited via `/admin`
- `requirements.txt` — just Flask
- `static/flags/` — local flag icons; the 4 defaults ship in the repo, more
  are added here automatically (or by upload) as you add currencies
- `scripts/provision-pi.sh` — one-time hardening for a **fresh SD card**
  (updates, new user, Wi-Fi, firewall, SSH hardening, fail2ban)
- `scripts/deploy-dashboard.sh` — clones this repo, sets up the venv,
  installs the systemd service, and configures kiosk boot (or skips kiosk
  entirely on a headless board — see below)

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

## 2. Deploying to a Raspberry Pi (fresh SD card → running)

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
plus the Wi-Fi IP if configured). Reboot when it finishes, then log back in
as whichever user you kept.

### Step 2 — `scripts/deploy-dashboard.sh` (installs the app)

```bash
REPO_URL=https://github.com/<you>/rpi_dash_currency.git \
  bash scripts/deploy-dashboard.sh
```

(Or clone the repo first and run it from inside — either works; it's
idempotent, safe to re-run any time to pull updates.)

It:

1. Installs `git`, `python3-venv`, `curl` (and Chromium, unless headless —
   see below)
2. Clones (or pulls) this repo into `~/currency-dashboard`
3. Creates a venv and installs `requirements.txt`
4. Installs and enables the `currency-dashboard` systemd service
5. Sets up kiosk autostart **if the board has a display** — detects
   labwc/wayfire (Raspberry Pi OS Bookworm), LXDE (older Pi OS Desktop), or
   console+X (Pi OS Lite) and configures Chromium accordingly, plus
   autologin via `raspi-config`

```bash
sudo reboot
```

A Pi with a screen comes up straight into fullscreen Chromium showing the
dashboard. Check the service any time with:

```bash
sudo systemctl status currency-dashboard
```

### Headless boards (e.g. Raspberry Pi Zero W)

The script auto-detects a Pi Zero / Zero W (checked via
`/proc/device-tree/model`) and skips Chromium and kiosk setup entirely —
those boards are too weak to run a browser and are normally run with no
display attached anyway. It only installs the systemd service; you reach
the dashboard from another device's browser on the network:

```
http://<pi-ip-or-hostname>.local:5000/
```

The script prints that address at the end. Override the auto-detection with
`HEADLESS=true` (force headless) or `HEADLESS=false` (force kiosk setup even
if it looks like a Zero) if needed.

**Note on the original Pi Zero W** (not Zero 2 W): it's an armv6 chip, which
current Raspberry Pi OS (Bookworm) doesn't support. Flash **Raspberry Pi OS
Lite (Legacy, Bullseye, 32-bit)** for it instead — that image also uses
`dhcpcd`/`wpa_supplicant` rather than NetworkManager, so the Wi-Fi step in
`provision-pi.sh` (which uses `nmcli`) will warn and skip; connect it to
Wi-Fi via `raspi-config` or the Raspberry Pi Imager's OS customization
option before/instead of that step. A Pi Zero 2 W (armv7, quad-core) runs
current Raspberry Pi OS fine and isn't auto-treated as headless unless you
set `HEADLESS=true`.

## Notes

- `/admin` is protected by a single hardcoded password in `config.py`
  (HTTP Basic Auth — any username, that password). Fine for a trusted home
  LAN; change the default before deploying. If you ever want it reachable
  outside your network, put it behind a reverse proxy with proper auth too,
  and restrict the firewall rule to your LAN subnet in `provision-pi.sh`.
- SSH password auth is left on per request; fail2ban mitigates brute-force
  attempts. For stronger security later, copy an SSH key over and switch
  `PasswordAuthentication` to `no` in `/etc/ssh/sshd_config`.
- Auto-suggested flags require internet access at the moment you add a
  currency in `/admin` (one-time fetch from flagcdn.com, then cached
  locally forever). If the Pi has no internet at that moment, upload an
  image instead.
