# Currency Dashboard — CLAUDE.md

Flask kiosk app for a Raspberry Pi / Orange Pi Zero 3 (Armbian): a public
dashboard of admin-managed currency prices, plus a password-protected admin
panel. No live FX, no database, no build step.

you are senior system engineer working with embedded linux like armbian and rpi os and orange pi. 
you ONLY make things works for user without adding too uch complexity while maintaining reliablity. you ask user about opinion before procedding ( in short exxplaination less than 5 lines when needed) you output small phrase each time you execute stage to tell user WTF are you doing now, if you fail in something you tell user explicitely and ask fo help ( like faliling connecting to board )

## Layout of the project 

| Path | What |
|---|---|
| `app.py` | Entrypoint only: registers hooks/routes on `core.app`, runs the HTTP(S) server. |
| `core.py` | The one `Flask(__name__)` instance. Its own file so `routes/*.py` can import it without re-executing `app.py` as a second module (see its docstring). |
| `config.py` | Paths, ports, and validation-limit constants. Pure data, no logic. |
| `i18n.py` | `TRANSLATIONS` (en/ar) + `get_translations()`. Admin UI chrome only. |
| `logging_setup.py` | Error-only logging setup (journald + rotating file), imported once for its side effect. |
| `helpers/` | `version.py`, `storage.py` (data.json/net_config.json), `validation.py`, `flags.py`, `security.py` (auth/CSRF/HTTPS-redirect). One concern per file. |
| `routes/` | `dashboard.py` (public), `admin.py` (currencies/settings), `admin_system.py` (Wi-Fi/updates/reboot). Each does `from core import app` and `@app.route(...)` directly — no Blueprints (would prefix `url_for()` endpoint names and break every template link). |
| `templates/` | Real Jinja files (`dashboard.html`, `admin.html`, `admin_system.html`), loaded via `render_template()`. |
| `static/css/`, `static/js/` | Plain CSS/JS, no build step — just files Flask serves as-is. |
| `data.json` | Currencies + settings, written by the app. Gitignored, seeded from `data.default.json`. |
| `.env` | `ADMIN_PASSWORD`. Gitignored, seeded from `.env.example`. |
| `net_config.json` | Desired Wi-Fi/hotspot state, mode 600 (plaintext PSKs). Gitignored, seeded from `net_config.default.json`. |
| `auto-update.enabled` / `.check-now` | Flag files — presence *is* the boolean. |
| `VERSION` | Bumped by hand, shown in the admin panel. |
| `ssl/` | Self-signed cert from `scripts/generate-cert.sh`. Gitignored. |
| `static/flags/` | Flag PNGs, fetched from flagcdn.com or uploaded. |
| `scripts/lib.sh` | The file-install helpers every script uses. |
| `scripts/files/` | Every config file installed anywhere on the system, as a real file. |

## Provisioning

`provision-pi.sh` (network + clone only) → `harden-system.sh` (apt, user, ufw,
ssh, fail2ban, journald) → `deploy-dashboard.sh` (venv, cert, systemd, updater,
kiosk, net-apply daemon). Each `exec`s into the next; `--auto_default` runs the
chain unattended. `deploy-dashboard.sh` is also safe standalone — that's how
redeploys and the auto-updater use it.

## Rules that bite

**Installed files.** Everything installed to the system is a real file under
`scripts/files/`, put in place via `lib.sh` (`install_file`, `install_user_file`,
`ensure_block_in_file`, `ensure_tokens_in_cmdline`). Every file under
`scripts/files/` is byte-for-byte final content — no `{{TOKEN}}` placeholders,
no KEY=VALUE substitution; a value that varies per-deploy (paths, ports, the
run user) gets hardcoded straight into the file rather than templated in, and
`install_file`/`install_user_file` just copy verbatim. No heredoc into `/etc`,
no `sed -i` on an installed file — two separate bugs came from hand-rolled
`sed` idempotency checks (NOTES).

**Git.** Never re-track `data.json` / `config.py` / `net_config.json`, and
never reach for `skip-worktree`. Every update path runs `git rm --cached` on
them before `fetch` + `reset --hard`, because a tracked-and-modified file is
silently *deleted* by `reset --hard` (NOTES).

**Networking is zero-privilege.** Flask never holds sudo. It writes desired
state to `net_config.json` / `reboot.request`; the root daemon
`/usr/local/sbin/dashboard-net-apply` polls every 5s, reconciles through nmcli
or netplan (auto-detected per tick), and publishes observed state to
`/run/dashboard-net/status.json`. Don't add a `sudo` call to `app.py`.

**Emergency AP.** The drop-in stays `/etc/systemd/network/05-dashboard-ap.network`
— networkd applies only the first matching file *by filename*, so anything
numbered above netplan's `10-` loses. ufw must open UDP/67 interface-scoped (a
DHCP DISCOVER's source is `0.0.0.0`, so no from-subnet rule can match). Both
were independently fatal and looked identical: client associates, never gets an
IP (NOTES).

**Wi-Fi passwords.** A blank password field means "keep the saved one" and
resolves only for an *unchanged* SSID, keyed by SSID rather than slot position.
Open networks are rejected outright (NOTES).

**HTTPS.** Build the listener *without* `make_server(ssl_context=...)`; wrap the
socket manually with `do_handshake_on_connect=False`, or one stalled client
wedges `accept()` for everyone (NOTES).

**Logging.** `security_log` uses `.error()` because journald is pinned to
`MaxLevelStore=err` — anything lower is never stored, so fail2ban never sees
it. The jail matches the literal string `Failed admin login from <ip>`.

**Admin routes.** Every state-changing admin POST needs a hidden `csrf_token`
plus a `check_csrf()` call. Auth is Basic; the comparison is
`hmac.compare_digest`. Validation is server-side (`clean_text`, `parse_price`);
client-side `maxlength`/`min`/`max` only mirror it for feedback.

**Dashboard JS.** Cards are built with `innerHTML`, so everything interpolated
goes through `esc()`, and flag `src=` additionally through `safeFlagSrc()`.

**Kiosk.** `.xinitrc` must *end* with `exec sh -c '...'` — no trailing `&`, or
X tears down instantly. The launch command hardcoded into that `sh -c` (and
into the labwc/lxde/wayfire autostart files) resolves the browser binary at
runtime with `$(command -v chromium-browser || command -v chromium)` since
Raspberry Pi OS ships `chromium-browser` and Armbian/Debian ships plain
`chromium` — don't hardcode just one name. The console+X path needs
`matchbox-window-manager` for `--kiosk` to fill the screen, and
`startx -- -nocursor` to hide the pointer (NOTES). `HEADLESS` defaults to
`false`; never reintroduce hardware-guessing.

**systemd.** `systemctl enable --now` does *not* restart an already-running
unit — redeploys must `restart` explicitly.

**i18n.** `TRANSLATIONS` (`en`/`ar`) covers admin UI chrome only; keep both
languages at key parity. Currency names and the dashboard title/subtitle are
admin-typed free text and are never auto-translated.

**Scope.** Targets a Pi Zero W: no database, no ORM, no build step, no asset
pipeline (CSS/JS are plain static files, not bundled/minified). Split into
`config`/`i18n`/`helpers`/`routes`/`templates`/`static` per the layout table
above — keep new code in the matching file rather than growing `app.py` again
or re-merging things back into one file. Still no Blueprints: `routes/*.py`
import the shared `app` from `core.py` and register routes directly, since
Blueprints would prefix every endpoint name and break `url_for()` calls
throughout the templates.
