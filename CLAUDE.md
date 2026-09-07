# Currency Dashboard — CLAUDE.md

## What this is

A single-file Flask app for a Raspberry Pi kiosk display: shows a set of
currencies with **static, admin-managed prices** (no live FX conversion,
no external API calls at runtime). A password-protected `/admin` panel
lets you edit prices, add/remove currencies, upload or auto-suggest flag
icons, edit the dashboard title/subtitle, switch the admin UI language
(English/Arabic, RTL), and toggle the "last updated" footer.

Repo: https://github.com/rommo911/rpi_dash_currency

## File structure

```
app.py                        Entire app: Flask routes + HTML/CSS/JS templates
                               embedded as Python strings (render_template_string).
                               No separate templates/ or static build step.
config.py                     ADMIN_PASSWORD (plaintext, HTTP Basic Auth).
                               Committed to the repo — placeholder value by
                               default, change before any real deployment.
data.json                     Runtime state: currencies list + settings.
                               Written by the app itself (save_data()).
                               Auto-migrates older schema versions on load.
requirements.txt               Just Flask.
static/flags/                 Flag icon PNGs. 4 ship with the repo
                               (sy/us/eu/tr.png). More get added here
                               automatically (fetched from flagcdn.com) or
                               via admin upload when a currency is added.
scripts/provision-pi.sh       One-time fresh-SD-card hardening: apt
                               update/upgrade, new sudo user, Wi-Fi (nmcli),
                               ufw firewall, sshd hardening, fail2ban,
                               unattended-upgrades (security-only origins).
scripts/deploy-dashboard.sh   Clones the repo, builds the venv, installs
                               the systemd service, sets up kiosk-mode
                               Chromium autostart. Kiosk is ALWAYS on by
                               default — headless mode (skip Chromium) is
                               opt-in only via HEADLESS=true, never guessed.
README.md                     Full user-facing setup/deploy instructions.
```

No `templates/`, no `static/css` or `static/js` — everything HTML/CSS/JS
lives inside `app.py` as `DASHBOARD_HTML` and `ADMIN_HTML` triple-quoted
strings rendered with `render_template_string`. Flask's default static
folder (`static/`) is used only for flag images.

## Architecture notes

- **Two pages**: `/` (public dashboard, read-only, no auth) and `/admin`
  (HTTP Basic Auth, password from `config.py`). `/api/data` is the public
  JSON endpoint the dashboard polls every 3 seconds.
- **data.json shape**:
  ```json
  {
    "currencies": [
      {"code": "SYP", "name": "...", "symbol": "", "price": 130.0,
       "flag": "/static/flags/sy.png", "enabled": true}
    ],
    "settings": {
      "title": "...", "subtitle": "...",
      "admin_language": "en" | "ar",
      "show_updated_at": true
    },
    "updated_at": 1788788157
  }
  ```
  `load_data()` auto-migrates missing/old keys and writes the result back,
  so it's always safe to call — never read the file directly.
- **i18n**: `TRANSLATIONS` dict (`en`/`ar`) covers only the `/admin` UI
  chrome (labels, buttons, error messages). Currency names and the
  dashboard title/subtitle are free text the admin typed — never
  auto-translated, by design (the user explicitly asked for this).
- **Single save button**: `/admin` has ONE form covering dashboard
  settings + every currency row. Per-row "Remove" buttons are separate,
  submitted via the HTML5 `form="delete-{code}"` attribute pointing at a
  tiny standalone `<form>` elsewhere in the DOM — this is intentional, not
  a bug, because nested `<form>` tags are invalid HTML and per-row forms
  used to be a UX complaint the user asked to be removed. If touching the
  admin template, keep this pattern; don't nest a `<form>` inside the
  big save-all `<form>`.
- **Validation** (`clean_text()`, `parse_price()`): server-side length
  caps by *character count* (fair to Arabic — Python strings are code
  points), strips control chars/newlines, rejects `inf`/`nan`/negative/
  oversized prices. Client-side `maxlength`/`max` attrs mirror the same
  limits for instant feedback but are not the actual enforcement.
- **Flag icons**: `fetch_suggested_flag()` guesses an ISO country code
  from the currency code (`COUNTRY_OVERRIDES` dict for exceptions like
  EUR→eu, else first two letters lowercased) and fetches once from
  flagcdn.com, caching the PNG locally forever. Uploads go through
  `save_uploaded_flag()` (extension allowlist: png/jpg/jpeg/webp/svg).
  Deleting a currency also deletes its flag file (`delete_flag_file()`,
  path-traversal-guarded to stay inside `static/flags/`).
- **Client-side XSS**: the dashboard's JS builds currency cards via
  `innerHTML` from `/api/data` JSON (not server-rendered per-item, since
  it needs to auto-refresh without a full reload). Everything interpolated
  into that HTML MUST go through `esc()` (full escaper incl. quotes) and,
  for the flag `src=` specifically, `safeFlagSrc()` (origin/path allowlist
  on top of escaping). If you add new fields to card rendering, escape
  them the same way — don't reintroduce raw interpolation.

## Things to watch for

- **Dev-server restarts silently fail if the port's still bound.** Killing
  and restarting `app.py` via `nohup ... & disown` in the same shell
  command sometimes races — the old process can still hold port 5000, the
  new one dies with "Address already in use" in the background, and you
  keep talking to stale code without realizing it. Always verify after a
  restart: `curl -s http://127.0.0.1:5000/api/data` and check the response
  actually reflects the change, not just that a process is running. This
  bit us once mid-project — don't trust `ps aux` alone.
- **`config.py` is committed with a placeholder password**
  (`changeme123`). It's meant to be edited before any real deployment, but
  don't assume it's still the default — check before relying on it, and
  never commit a real password there.
- **`HEADLESS` in `deploy-dashboard.sh` defaults to `false`.** Kiosk setup
  always runs unless the caller explicitly passes `HEADLESS=true`. Do not
  reintroduce hardware-guessing logic that skips kiosk mode by default —
  that was a bug reported and fixed once already (Pi Zero auto-detection
  was silently skipping kiosk).
- **`data.json` holds live admin-entered content**, often in Arabic — when
  testing changes locally, snapshot it first (`curl .../api/data > /tmp/x`)
  and restore it after, rather than leaving test values in place.
- **Currency `code` is the primary key** (not a separate id) — form field
  names like `name_{code}`, `price_{code}` depend on codes being unique
  and stable. `admin_add_currency` already rejects duplicates.
- **No database, no ORM, no build step** — this stays a single Python file
  with embedded templates by design (Pi Zero W target, fastest-path
  philosophy from the original ask). Resist the urge to split into
  templates/blueprints/etc. unless the user asks.
