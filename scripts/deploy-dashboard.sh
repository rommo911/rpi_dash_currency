#!/usr/bin/env bash
# Stage 3 of 3 (also safe to run entirely standalone): clone/update the
# currency dashboard on a Raspberry Pi and boot straight into it in kiosk
# mode. This is the default and always what happens unless you explicitly
# opt out — kiosk mode is not skipped based on guessing what hardware
# this is.
#
# Every installed config file below (systemd units, fail2ban, sudoers,
# kiosk autostart, boot config) is a real file under scripts/files/,
# rendered via lib.sh's render_template/ensure_block_in_file — nothing
# here authors config content inline or edits an OS file with sed. See
# scripts/lib.sh for why.
#
# Run this as the normal user the Pi boots into (e.g. "pi" or
# "dashboard"), normally invoked automatically by harden-system.sh, but
# also fine to run entirely on its own if you just want the app without
# the security hardening.
#
# Usage:
#   REPO_URL=https://github.com/<you>/rpi_dash_currency.git ./deploy-dashboard.sh
#
#   # Only for a board with no display attached (e.g. a headless Pi Zero W
#   # you're reaching over the network) — skips Chromium/kiosk entirely.
#   # You must ask for this explicitly; it is never assumed.
#   HEADLESS=true REPO_URL=... ./deploy-dashboard.sh
#
# Re-running this script is safe: it pulls the latest code, reinstalls deps,
# and re-applies the service/kiosk/cert/updater config.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/rommo911/rpi_dash_currency.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/currency-dashboard}"
SERVICE_NAME="currency-dashboard"
APP_PORT="${APP_PORT:-5000}"
HTTPS_PORT="${HTTPS_PORT:-5443}"
HEADLESS="${HEADLESS:-false}"
LAN_SUBNET="${LAN_SUBNET:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
if [[ -f "$SCRIPT_DIR/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib.sh"
else
  # Running copied-alone, before the repo (and lib.sh/scripts/files with
  # it) exists on disk yet — bare log/warn/is_auto cover everything used
  # before the clone step below; render_template & friends are only
  # called after it, by which point lib.sh is re-sourced from the fresh
  # checkout (see FILES_DIR re-point below).
  log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
  warn() { echo -e "\033[1;33m$*\033[0m"; }
  is_auto() { [[ "${AUTO_DEFAULT:-false}" == "true" ]]; }
fi

if [[ "$REPO_URL" == *"<your-username>"* ]]; then
  echo "Set REPO_URL to your GitHub repo before running, e.g.:"
  echo "  REPO_URL=https://github.com/you/rpi_dash_currency.git $0"
  exit 1
fi

is_headless() {
  [[ "$HEADLESS" == "true" ]]
}

if ! is_headless; then
  # Just a heads-up, never a decision — kiosk mode still proceeds regardless.
  model=""
  [[ -f /proc/device-tree/model ]] && model="$(tr -d '\0' < /proc/device-tree/model)"
  if [[ "$model" == *"Zero"* && "$model" != *"Zero 2"* ]]; then
    warn "This looks like a Pi Zero / Zero W — it's quite weak for a browser."
    warn "If it has no display attached, re-run with HEADLESS=true instead. Continuing with kiosk setup as requested."
  fi
fi

log "1/13 Installing system dependencies"
sudo apt update
sudo apt install -y git python3-venv python3-pip curl openssl avahi-daemon

CHROMIUM_BIN=""
if is_headless; then
  log "HEADLESS=true — skipping Chromium/kiosk setup"
else
  CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
  if [[ -z "$CHROMIUM_BIN" ]]; then
    log "Installing Chromium"
    sudo apt install -y chromium-browser 2>/dev/null || sudo apt install -y chromium
    CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium)"
  fi
fi

log "2/13 Cloning/updating repository into $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  # A checkout from before data.json/config.py were gitignored may still
  # have them TRACKED with local (real, live) modifications — untrack
  # them first (keeps the on-disk file untouched) so the update below can
  # never delete them. fetch+reset instead of a plain `git pull`: pull
  # refuses outright on local changes to a path the merge touches (a loud
  # but safe failure), while fetch+reset here — now that the untrack
  # guard makes it safe — always succeeds, matching what
  # scripts/auto-update.sh already does for consistency.
  git -C "$INSTALL_DIR" rm --cached -q data.json config.py 2>/dev/null || true
  CURRENT_BRANCH="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)"
  git -C "$INSTALL_DIR" fetch origin "$CURRENT_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$CURRENT_BRANCH"
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
# Re-point FILES_DIR/lib.sh at the checkout we just ensured is current, in
# case this script started from a different location than $INSTALL_DIR
# (e.g. run copied-alone, before it had cloned anything) — the fallback
# log/warn/is_auto above cover everything up to this point, but
# render_template & friends (used from here on) need the real lib.sh.
FILES_DIR="$INSTALL_DIR/scripts/files"
# shellcheck disable=SC1091
source "$INSTALL_DIR/scripts/lib.sh"

log "3/13 Setting up local config (data.json, .env, net_config.json, auto-update.conf)"
# These files are gitignored and never committed as themselves — copied
# from their tracked templates only if missing, so a later `git reset --hard`
# (see scripts/auto-update.sh) can never touch live prices, the real admin
# password, or your chosen auto-update branch.
NEW_ENV=false
if [[ ! -f "$INSTALL_DIR/data.json" ]]; then
  cp "$INSTALL_DIR/data.default.json" "$INSTALL_DIR/data.json"
fi
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  NEW_ENV=true
fi
if [[ ! -f "$INSTALL_DIR/scripts/auto-update.conf" ]]; then
  cp "$INSTALL_DIR/scripts/auto-update.conf.example" "$INSTALL_DIR/scripts/auto-update.conf"
fi
# net_config.json is the Wi-Fi/hotspot desired state the admin panel writes
# and dashboard-net-apply polls. Without this copy a freshly provisioned
# board came up with NO known networks and NO hotspot fallback at all — it
# would sit there unreachable until someone plugged in Ethernet or a
# keyboard to reach /admin, which on a headless wall-mounted kiosk is the
# one situation the AP fallback exists to prevent. Seeding it from the
# tracked template makes a fresh board join a known network, or raise its
# own AP, with zero manual steps.
#
# 600, not the default 644: unlike data.json this file holds plaintext
# Wi-Fi/hotspot PSKs — same reasoning as .env above, and the same mode
# save_net_config() re-applies on every write in app.py.
if [[ ! -f "$INSTALL_DIR/net_config.json" ]]; then
  cp "$INSTALL_DIR/net_config.default.json" "$INSTALL_DIR/net_config.json"
  chmod 600 "$INSTALL_DIR/net_config.json"
fi
# Auto-update is a flag FILE (see app.py/auto-update.sh), not a data.json
# setting — the admin panel's "Enable automatic updates" checkbox
# creates/removes it directly. Defaults to present (enabled) ONLY on a
# genuinely fresh install (tied to NEW_ENV, same signal the password
# prompt above uses) — matching this project's previous always-on
# behavior for a first deploy, without ever re-enabling it behind an
# admin's back on a later redeploy after they've explicitly unchecked it.
if [[ "$NEW_ENV" == true ]]; then
  touch "$INSTALL_DIR/auto-update.enabled" 2>/dev/null || true
fi
if [[ "$NEW_ENV" == true ]]; then
  # -t 0 guards against a non-interactive run (automation, `ssh host cmd`
  # with no pty, piped input, or --auto_default) — deploy-dashboard.sh is
  # documented as safe to run unattended, and a bare `read` on
  # closed/non-tty stdin returns non-zero, which set -e would treat as
  # this whole script failing.
  SET_ADMIN_PW="n"
  if [[ -t 0 ]] && ! is_auto; then
    read -rp "Set a custom admin panel password now instead of the placeholder? [y/N]: " SET_ADMIN_PW || true
  fi
  if [[ "${SET_ADMIN_PW,,}" == "y" ]]; then
    while true; do
      read -rsp "New admin panel password: " ADMIN_PW1; echo
      read -rsp "Confirm: " ADMIN_PW2; echo
      if [[ -z "$ADMIN_PW1" ]]; then
        warn "Password can't be empty."
      elif [[ "$ADMIN_PW1" != "$ADMIN_PW2" ]]; then
        warn "Passwords didn't match — try again."
      else
        break
      fi
    done
    # Write the password into the project-local env file without exposing it
    # in the service unit or in a shell command argument.
    python3 - "$ADMIN_PW1" "$INSTALL_DIR/.env" <<'PYEOF'
import pathlib
import sys

pw, env_path = sys.argv[1], pathlib.Path(sys.argv[2])
lines = env_path.read_text(encoding="utf-8").splitlines()
out = [f"ADMIN_PASSWORD={pw}" if line.startswith("ADMIN_PASSWORD=") else line for line in lines]
env_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PYEOF
    chmod 600 "$INSTALL_DIR/.env"
    unset ADMIN_PW1 ADMIN_PW2
    log "Admin panel password set."
  else
    warn "No custom password set — put ADMIN_PASSWORD in $INSTALL_DIR/.env before relying on the admin panel."
  fi
fi

log "4/13 Creating virtualenv and installing Python deps"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

log "5/13 Generating/renewing the self-signed HTTPS certificate"
INSTALL_DIR="$INSTALL_DIR" bash "$INSTALL_DIR/scripts/generate-cert.sh" || \
  warn "Certificate generation failed — the admin panel will fall back to HTTP only until this is fixed."

log "6/13 Installing systemd service"
render_template "$FILES_DIR/systemd/currency-dashboard.service" \
  "/etc/systemd/system/${SERVICE_NAME}.service" \
  "INSTALL_DIR=$INSTALL_DIR" "APP_PORT=$APP_PORT" "HTTPS_PORT=$HTTPS_PORT" "RUN_USER=$USER"

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

log "7/13 Firewall: opening the HTTPS admin port"
# Deliberately NOT gated on "is ufw active right now" — that check raced
# harden-system.sh's own `ufw --force enable` a moment earlier on at
# least one real deploy (ufw reported inactive at this exact instant, so
# the rule was silently skipped and never added, even though ufw came up
# active moments later). `ufw allow` queues the rule into ufw's rule set
# regardless of whether ufw is currently enabled — it takes effect
# whenever ufw is (or becomes) active, so there's nothing to race here.
if command -v ufw >/dev/null 2>&1; then
  if [[ -n "$LAN_SUBNET" ]]; then
    sudo ufw allow from "$LAN_SUBNET" to any port "$HTTPS_PORT" proto tcp
  else
    sudo ufw allow "$HTTPS_PORT"/tcp
  fi
  # A LAN_SUBNET-scoped rule set locks out the emergency hotspot's OWN
  # clients: the AP hands out 192.168.50.0/24 addresses, which are not in
  # "$LAN_SUBNET", so with only the rule above plus harden-system.sh's
  # equally-scoped 22/$APP_PORT rules, a laptop joined to the fallback AP
  # can associate, get a lease, and still reach nothing at all — which
  # defeats the entire point of a fallback whose only job is to keep the
  # box reachable when the normal LAN is gone. So open the AP subnet to the
  # same three ports.
  #
  # Applied unconditionally, NOT only in the LAN_SUBNET branch above: this
  # script is explicitly re-runnable standalone (that's how the auto-updater
  # and manual redeploys both use it), and such a run can easily have an
  # empty LAN_SUBNET while harden-system.sh's 22/$APP_PORT rules from the
  # ORIGINAL provision are still subnet-scoped. Gating these on LAN_SUBNET
  # would silently skip them in exactly that case. Redundant (not harmful)
  # when everything is already open to Anywhere.
  #
  # NOT included here: the DHCP port itself. A DHCP DISCOVER is sent from
  # source 0.0.0.0, so a from-subnet rule can never match it — that one has
  # to be interface-scoped, and the daemon adds/removes it around each AP
  # session (ap_firewall_open/ap_firewall_close in
  # scripts/files/network/dashboard-net-apply.sh) since only the daemon
  # knows which interface the AP actually came up on. Keep AP_SUBNET below
  # in sync with AP_IFACE_CIDR there.
  AP_SUBNET="192.168.50.0/24"
  sudo ufw allow from "$AP_SUBNET" to any port "$HTTPS_PORT" proto tcp
  sudo ufw allow from "$AP_SUBNET" to any port "$APP_PORT" proto tcp
  sudo ufw allow from "$AP_SUBNET" to any port 22 proto tcp
  sudo ufw status 2>/dev/null | grep -q "Status: active" || \
    log "ufw is installed but not active yet — rule was queued and will apply once ufw is enabled."
else
  log "ufw not installed — skipping (nothing to open)"
fi

log "8/13 Installing the auto-updater (git pull + cert renewal every 6h)"
SYSTEMCTL_BIN="$(command -v systemctl)"
SUDOERS_FILE="/etc/sudoers.d/${SERVICE_NAME}-updater"
# Rendered to a LOCAL temp file first (not straight to /etc/sudoers.d)
# so it can be validated with visudo before it's ever live, and so it
# lands with the correct 440 root:root permissions via `install` — a
# plain `sudo tee` would leave it world-readable, which sudoers must
# never be.
SUDOERS_TMP="$(mktemp)"
render_template_user "$FILES_DIR/sudoers/currency-dashboard-updater" "$SUDOERS_TMP" \
  "RUN_USER=$USER" "SYSTEMCTL_BIN=$SYSTEMCTL_BIN" "SERVICE_NAME=$SERVICE_NAME"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
  warn "Generated sudoers rule failed validation — the auto-updater won't be able to restart the service, and the admin panel's 'check now' button won't be able to trigger a check, automatically."
  warn "Restart it by hand after an update: sudo systemctl restart ${SERVICE_NAME}"
fi
rm -f "$SUDOERS_TMP"

render_template "$FILES_DIR/systemd/currency-dashboard-updater.service" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.service" \
  "INSTALL_DIR=$INSTALL_DIR" "SERVICE_NAME=$SERVICE_NAME" "RUN_USER=$USER"
render_template "$FILES_DIR/systemd/currency-dashboard-updater.timer" \
  "/etc/systemd/system/${SERVICE_NAME}-updater.timer"

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}-updater.timer"

log "9/13 Securing the admin panel: fail2ban jail for repeated failed logins"
if command -v fail2ban-client >/dev/null 2>&1; then
  render_template "$FILES_DIR/fail2ban/currency-dashboard.filter" \
    "/etc/fail2ban/filter.d/${SERVICE_NAME}.conf"
  render_template "$FILES_DIR/fail2ban/currency-dashboard.jail" \
    "/etc/fail2ban/jail.d/${SERVICE_NAME}.local" \
    "SERVICE_NAME=$SERVICE_NAME" "APP_PORT=$APP_PORT" "HTTPS_PORT=$HTTPS_PORT"
  sudo systemctl restart fail2ban
else
  log "fail2ban not installed (run provision-pi.sh/harden-system.sh first for full hardening) — skipping the admin-login jail"
fi

log "10/13 Installing the network/reboot reconciler (Wi-Fi + hotspot fallback + reboot from the admin panel)"
# The Flask app itself never holds sudo/root for this feature — it only
# ever writes plain files into its own workspace (net_config.json,
# reboot.request). This root-run daemon (no User= in the unit, same as
# wifi-ap-fallback.service) polls those files every few seconds and does
# all the real nmcli/systemctl work to converge the system to match. See
# scripts/files/network/dashboard-net-apply.sh's header comment for the
# full design.
DAEMON_PATH="/usr/local/sbin/dashboard-net-apply"
render_template "$FILES_DIR/network/dashboard-net-apply.sh" "$DAEMON_PATH" \
  "INSTALL_DIR=$INSTALL_DIR" "RUN_USER=$USER"
sudo chmod 755 "$DAEMON_PATH"
render_template "$FILES_DIR/systemd/dashboard-net-apply.service" \
  "/etc/systemd/system/dashboard-net-apply.service" \
  "DAEMON_PATH=$DAEMON_PATH"
sudo systemctl daemon-reload
# Upgrade path: the emergency AP's networkd drop-in used to be named
# 90-dashboard-ap.network, which always lost to netplan's generated
# 10-netplan-<dev>.network (systemd-networkd applies only the FIRST
# matching file in lexical filename order across /etc, /run and /usr/lib —
# /etc only wins for an identical filename). It is 05-dashboard-ap.network
# now; remove any stale copy of the old one so an upgraded box is left in
# exactly the same state as a freshly provisioned one.
sudo rm -f /etc/systemd/network/90-dashboard-ap.network
sudo systemctl enable --now dashboard-net-apply
sudo systemctl restart dashboard-net-apply

# On any image WITHOUT NetworkManager (confirmed live on Armbian/Orange Pi,
# which uses netplan + systemd-networkd + wpa_supplicant instead), the
# daemon above falls back to a netplan-based Wi-Fi backend and drives
# hostapd directly for the emergency-AP fallback (DHCP is served by
# systemd-networkd's own built-in DHCP-server role, already running and
# proven on this box — no dnsmasq) — see that script's own header
# comment for the full design. hostapd (plus `iw`, used only to read the
# currently-associated SSID for the admin panel) is only needed on that
# fallback path; a NetworkManager image (Raspberry Pi OS Bookworm+) never
# touches it. Disabling its own persistent service immediately after
# install is deliberate: this daemon always runs it as its own transient
# `systemd-run` unit on demand, never the shared hostapd.service/its
# default config, so that must never be left enabled to auto-start at
# boot against an empty/absent config.
if ! command -v nmcli >/dev/null 2>&1; then
  log "No NetworkManager detected — installing netplan-backend Wi-Fi fallback dependencies (hostapd, iw)"
  sudo apt-get install -y hostapd iw || \
    warn "Failed to install hostapd/iw — the emergency Wi-Fi hotspot fallback won't work until this is resolved (Wi-Fi client networking is unaffected)."
  sudo systemctl disable --now hostapd >/dev/null 2>&1 || true
fi

log "Waiting for the dashboard to respond on port ${APP_PORT}"
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${APP_PORT}/" >/dev/null; then
    break
  fi
  sleep 1
done

log "11/13 Installing the post-boot health check (auto-rollback on a bad boot)"
# Runs once, ~2 minutes after every boot: if the service is active and
# /api/data returns valid JSON, it records the current commit as
# "last-known-good" (a git tag) and backs up the small gitignored runtime
# files. If not, it rolls back to that tag/backup once and restarts —
# see scripts/files/health/dashboard-health-check.sh's header comment for
# the full design. Guards against exactly the failure mode of a corrupted
# checkout (e.g. from a power loss mid-write) leaving a Pi stuck unbootable
# with no display attached to debug it from.
HEALTH_SCRIPT_PATH="/usr/local/sbin/dashboard-health-check"
render_template "$FILES_DIR/health/dashboard-health-check.sh" "$HEALTH_SCRIPT_PATH" \
  "INSTALL_DIR=$INSTALL_DIR" "RUN_USER=$USER" "SERVICE_NAME=$SERVICE_NAME" "APP_PORT=$APP_PORT"
sudo chmod 755 "$HEALTH_SCRIPT_PATH"
render_template "$FILES_DIR/systemd/dashboard-health-check.service" \
  "/etc/systemd/system/dashboard-health-check.service" \
  "SCRIPT_PATH=$HEALTH_SCRIPT_PATH" "SERVICE_NAME=$SERVICE_NAME"
render_template "$FILES_DIR/systemd/dashboard-health-check.timer" \
  "/etc/systemd/system/dashboard-health-check.timer"
sudo systemctl daemon-reload
sudo systemctl enable --now dashboard-health-check.timer

# config.txt/cmdline.txt are OS-owned firmware files that also carry a lot
# of Pi-model-specific content we must never touch — ensure_block_in_file
# (config.txt: comment-delimited managed block) and ensure_tokens_in_cmdline
# (cmdline.txt: a single line, no comment syntax at all, so tokens are
# appended directly rather than wrapped in a block) both only ever ADD to
# these files, never rewrite them wholesale.
configure_boot_files() {
  local boot_dir
  boot_dir="$(detect_boot_dir)"
  local config="$boot_dir/config.txt"
  local cmdline="$boot_dir/cmdline.txt"

  if is_armbian; then
    warn "Armbian/Orange Pi detected: Raspberry Pi /boot/config.txt and cmdline.txt are not assumed to be present or compatible."
    warn "This image commonly uses Armbian boot configuration instead, and those flags are board-specific."
    local armbian_env=""
    if [[ -f /boot/armbianEnv.txt ]]; then
      armbian_env="/boot/armbianEnv.txt"
    elif [[ -f /boot/firmware/armbianEnv.txt ]]; then
      armbian_env="/boot/firmware/armbianEnv.txt"
    fi
    if [[ -n "$armbian_env" ]]; then
      # Mainline sunxi/rockchip DRM only lights up an HDMI connector when it
      # sees a live hotplug-detect (HPD) signal from the display at boot —
      # if the TV/monitor is off (or still warming up) when the board
      # powers on, the connector can come up "disconnected" and X/Chromium
      # never get a mode to render into, even after the TV is switched on
      # later. `video=HDMI-A-1:<mode>e` (trailing "e" = force-enable) is
      # the mainline-DRM equivalent of Raspberry Pi's
      # hdmi_force_hotplug=1 — it forces that connector into the given
      # mode unconditionally, independent of the live HPD line.
      # "HDMI-A-1" is the generic DRM connector name for a board's first/
      # only HDMI output (confirmed against this exact Orange Pi Zero 3
      # via /sys/class/drm/card0-HDMI-A-1), not something board-specific
      # we're guessing at.
      ensure_key_tokens_in_file --sudo "$armbian_env" "extraargs" "$FILES_DIR/boot/armbian-extraargs-tokens.txt"
      log "Ensured forced HDMI output mode is present in $armbian_env (extraargs=) — takes effect after a reboot"

      # armbianEnv.txt's default `console=both` puts BOTH the serial UART
      # and tty1 in the kernel's `console=` list, so every kernel/systemd
      # boot message (and the "[ OK ] Started ..." status lines systemd
      # itself prints) gets written straight to the HDMI display — visible
      # scrolling boot log on a kiosk that's supposed to just show the
      # dashboard. Switching to `console=serial` drops tty1 out of the
      # kernel's console list entirely: tty1 stays blank/uninitialized
      # (nothing to silence, because nothing is ever printed to it) from
      # power-on until getty/X take it over, while the serial UART keeps
      # carrying full boot output for debugging. This doesn't touch
      # `bootlogo`/`splash=verbose` — those only matter to plymouth, which
      # isn't installed on this image, so they're already inert.
      ensure_key_value_in_file --sudo "$armbian_env" "console" "serial"
      log "Silenced kernel/systemd boot messages on the HDMI display in $armbian_env (console=serial; still visible over the serial UART) — takes effect after a reboot"
    else
      warn "No Armbian boot environment file was found at /boot/armbianEnv.txt or /boot/firmware/armbianEnv.txt — HDMI force-enable and silent-boot tweaks skipped."
    fi
    return 0
  fi

  if [[ -f "$config" ]]; then
    ensure_block_in_file --sudo "$config" "currency-dashboard-boot" "$FILES_DIR/boot/config-txt-append.conf"
    log "Ensured HDMI-always-on / silent-boot settings are present in $config"
  else
    warn "Could not find $config — skipping boot config"
  fi

  if [[ -f "$cmdline" ]]; then
    ensure_tokens_in_cmdline --sudo "$cmdline" "$FILES_DIR/boot/cmdline-txt-tokens.txt"
    log "Ensured silent-boot/no-console-blanking tokens are present in $cmdline"
  fi
}

reduce_network_wait_online_delay() {
  # The dashboard itself never needs network readiness at startup
  # (static local prices, no runtime API calls), but some
  # *-wait-online.service unit is enabled on most Debian/Armbian/Pi OS
  # images regardless, blocking network-online.target until the network
  # stack considers itself fully "online". Confirmed live on an Orange Pi
  # Zero 3 via `systemd-analyze critical-chain`: systemd-networkd-wait-
  # online.service alone was ~10.5s of a ~15.6s total userspace boot,
  # sitting directly in the chain that gates getty.target/
  # graphical.target — i.e. the delay between power-on and the
  # autologin/kiosk screen appearing.
  #
  # This only bounds how long systemd will wait for the unit via
  # TimeoutStartSec (systemd's own external kill-timeout for the start
  # job) — it does NOT disable, mask, or otherwise touch the unit's
  # enablement or dependency graph, and leaves whatever wait-online
  # implementation/args the OS image already ships completely alone.
  # That distinction matters, not just style: an earlier version of this
  # fix used `systemctl mask`, which is UNSAFE in practice — confirmed
  # live on this same board, masking systemd-networkd-wait-online.service
  # caused intermittent network flapping after reboot (brief connectivity
  # then drop, repeatedly). Root cause: this board's image manages Wi-Fi
  # via netplan + systemd-networkd (NetworkManager isn't even installed
  # on it, despite that being this project's usual assumption — nmcli is
  # not guaranteed present on every Armbian image), and
  # systemd-networkd-wait-online.service is `BindsTo=systemd-networkd.
  # service`, which reacted badly to being masked outright. A
  # TimeoutStartSec cap avoids that risk entirely: if the unit finishes
  # on its own (as it always does here, just slower than needed), nothing
  # changes; if it doesn't finish within the cap, systemd kills it and
  # network-online.target proceeds anyway (a `Wants=`, not `Requires=`,
  # relationship — one failed/killed dependency doesn't block the target).
  local unit
  for unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
      render_template "$FILES_DIR/systemd/wait-online-fast-timeout.conf" \
        "/etc/systemd/system/${unit}.d/currency-dashboard-fast-timeout.conf"
      log "Capped $unit's start timeout at 5s (was blocking boot far longer than the dashboard needs)"
    fi
  done
  sudo systemctl daemon-reload
}
reduce_network_wait_online_delay

if is_headless; then
  log "12/13 Skipping kiosk setup (headless)"
  echo "This board has no display configured — access the dashboard from"
  echo "another device's browser instead: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${APP_PORT}/"
else

log "12/13 Configuring kiosk autostart"
configure_boot_files
# Wrapped in `sh -c '...; exec chromium ...'` rather than the bare
# chromium invocation: Chromium leaves SingletonLock/SingletonSocket/
# SingletonCookie symlinks in its profile dir (~/.config/chromium) while
# running, and only cleans them up on a graceful exit. A reboot, power
# loss, or `disable-kiosk.sh` killing the process all skip that cleanup,
# so the NEXT launch finds a stale lock pointing at a PID that no longer
# exists and refuses to start — Chromium pops an "Unlock Profile and
# Relaunch" dialog instead of the dashboard, and kiosk mode is stuck
# until someone manually deletes those files. This was hit live on a
# real deploy. Since this kiosk only ever runs one Chromium instance per
# X session (fresh tty1 login -> single exec chain), any lock file found
# at launch time is by definition stale, not a real concurrent instance
# — safe to unconditionally clear before every launch. `exec` inside the
# wrapper keeps chromium as the final foreground process either way (see
# the .xinitrc note above about never backgrounding the last command).
KIOSK_CMD="sh -c 'rm -f \"\$HOME/.config/chromium/SingletonLock\" \"\$HOME/.config/chromium/SingletonSocket\" \"\$HOME/.config/chromium/SingletonCookie\" 2>/dev/null; exec $CHROMIUM_BIN --kiosk --incognito --noerrant --disable-infobars --disable-session-crashed-bubble --check-for-update-interval=31536000 http://localhost:${APP_PORT}'"

setup_labwc() {
  # labwc doesn't blank/DPMS the screen by default on Pi OS Bookworm, so no
  # xset-equivalent is needed here — configure_boot_files already covers
  # the console/firmware-level blanking that would otherwise apply.
  render_template_user "$FILES_DIR/kiosk/labwc-autostart" "$HOME/.config/labwc/autostart" "KIOSK_CMD=$KIOSK_CMD"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log "Configured labwc autostart (Raspberry Pi OS Bookworm / Wayland desktop)"
}

setup_wayfire() {
  ensure_block_in_file "$HOME/.config/wayfire.ini" "currency-dashboard-kiosk" \
    "$FILES_DIR/kiosk/wayfire-autostart.snippet" "KIOSK_CMD=$KIOSK_CMD"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log "Configured wayfire autostart"
}

setup_lxde() {
  render_template_user "$FILES_DIR/kiosk/lxde-autostart" "$HOME/.config/lxsession/LXDE-pi/autostart" "KIOSK_CMD=$KIOSK_CMD"
  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || true
  fi
  log "Configured LXDE autostart (older Raspberry Pi OS desktop)"
}

setup_console_x() {
  # $KIOSK_CMD must be the FOREGROUND last command in .xinitrc (via exec,
  # no trailing &) — xinit/startx tears the X session down the instant
  # .xinitrc reaches EOF with nothing left to wait on. Backgrounding it
  # made X start, launch Chromium, and immediately exit again a few
  # seconds later ("Server terminated successfully (0)" in Xorg.0.log)
  # every single time — this was a real bug, caught live on a deployed
  # Pi. See scripts/files/kiosk/xinitrc — the template already ends with
  # `exec {{KIOSK_CMD}}`, keep it that way if you touch it.
  #
  # matchbox-window-manager is required here, not optional: bare xinit
  # starts NO window manager at all, and without one nobody honors
  # Chromium's --kiosk fullscreen request — it just gets whatever default
  # size its toolkit picks. matchbox is the standard minimal WM for
  # exactly this Pi-OS-Lite-kiosk case; it auto-maximizes any window it
  # manages.
  #
  # The mouse pointer (visible on screen despite no mouse being attached)
  # is hidden at the Xorg SERVER level via `startx -- -nocursor` in the
  # bash_profile snippet below, not just matchbox's own -use_cursor no
  # (which only controls whether matchbox itself draws/manages a cursor
  # for the root window — the default X-server arrow cursor was still
  # rendering on top of that). -nocursor tells Xorg not to draw a cursor
  # sprite at all, ever.
  #
  # x11-xserver-utils (provides `xset`) is required, not optional, even
  # though nothing above mentions it: scripts/files/kiosk/xinitrc calls
  # `xset -dpms`, `xset s off`, `xset s noblank` to keep the screen from
  # ever blanking. Without this package `xset` doesn't exist, those three
  # calls fail with "command not found" and .xinitrc (no `set -e`) just
  # carries on to matchbox/Chromium anyway — so DPMS is never actually
  # disabled and the X server falls back to its default ~10-minute DPMS
  # standby timeout. This was a real, live bug: confirmed on a deployed
  # Orange Pi Zero 3 where the HDMI signal dropped to "no signal" after
  # almost exactly 10 minutes while the dashboard/Chromium were still
  # running fine underneath — and reproduced by finding `xset` genuinely
  # missing from that board's installed packages.
  sudo apt install -y xserver-xorg xinit matchbox-window-manager x11-xserver-utils
  render_template_user "$FILES_DIR/kiosk/xinitrc" "$HOME/.xinitrc" "APP_PORT=$APP_PORT" "KIOSK_CMD=$KIOSK_CMD"
  # render_template_user only writes content, never touches permissions —
  # relying on an inherited/pre-existing executable bit (e.g. from an
  # /etc/skel default) to make `startx`/`xinit` treat this as a direct
  # client program is fragile and was confirmed to actually fail this
  # way: overwriting .xinitrc through a path that recreates the inode
  # (rather than truncate-in-place) reset it to non-executable, and
  # xinit then silently launched Xorg with no client at all (bare black
  # screen forever, no matchbox, no Chromium, no error visible anywhere
  # on-screen since the console is now silent). chmod it explicitly so
  # this never depends on what the file happened to be before.
  chmod +x "$HOME/.xinitrc"

  # ensure_block_in_file (see scripts/lib.sh) always converges .bash_profile
  # on exactly the current scripts/files/kiosk/bash-profile.snippet content,
  # whatever was there on a previous run — this replaces the old bespoke
  # sed self-heal logic 
  # same shared, independently-tested mechanism disable-kiosk.sh's
  # --remove counterpart uses.
  ensure_block_in_file "$HOME/.bash_profile" "currency-dashboard-kiosk" "$FILES_DIR/kiosk/bash-profile.snippet"

  # tty1 autologin is what actually reaches .bash_profile/.xinitrc above on
  # boot — without it, boot stops at a manual login prompt (a real, live
  # bug: confirmed on an Orange Pi Zero 3 running Armbian, which has no
  # raspi-config at all, so the old raspi-config-only path below never
  # configured autologin there). This systemd getty override is
  # distro-agnostic — it's literally the same mechanism raspi-config's own
  # boot-behaviour option installs under the hood on Raspberry Pi OS — so
  # it's applied unconditionally here instead of only for is_raspi_os.
  render_template "$FILES_DIR/systemd/getty-autologin.conf" \
    "/etc/systemd/system/getty@tty1.service.d/autologin.conf" \
    "RUN_USER=$USER"
  sudo systemctl daemon-reload
  log "Configured tty1 autologin as $USER (takes effect on next boot, or: sudo systemctl restart getty@tty1)"

  # `.hushlogin` is the standard mechanism (checked by login/PAM's
  # pam_motd and the shell itself) to suppress the MOTD banner and "Last
  # login: ..." line on this user's console sessions — otherwise that
  # text prints to tty1 immediately after autologin, before
  # .bash_profile's `startx` line even runs, so it's visible on the
  # kiosk screen for a moment before X takes over.
  touch "$HOME/.hushlogin"

  if is_raspi_os && command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B2 || true
    log "Configured console autologin + startx kiosk (Raspberry Pi OS Lite)"
  else
    log "Configured generic X11 kiosk launch in ~/.bash_profile ~/.xinitrc (Armbian/Orange Pi)"
  fi
}

detect_desktop_environment() {
  if command -v labwc >/dev/null 2>&1 || [[ -d /usr/share/labwc ]]; then
    echo "labwc"
  elif command -v wayfire >/dev/null 2>&1; then
    echo "wayfire"
  elif [[ -d /etc/xdg/lxsession/LXDE-pi ]] || command -v lxsession >/dev/null 2>&1; then
    echo "lxde"
  elif command -v startx >/dev/null 2>&1; then
    echo "x11"
  else
    echo "unknown"
  fi
}

case "$(detect_desktop_environment)" in
  labwc)
    setup_labwc
    ;;
  wayfire)
    setup_wayfire
    ;;
  lxde)
    setup_lxde
    ;;
  x11|unknown)
    if is_armbian; then
      warn "Armbian detected: no stable desktop session manager was found; falling back to the generic X11 launcher path."
      warn "If your image does not auto-login to X or does not start X on tty1, configure that through the Armbian service manager or the board's native startup tooling."
    fi
    setup_console_x
    ;;
esac

fi  # is_headless

log "13/13 Done"
echo "Dashboard service:   sudo systemctl status ${SERVICE_NAME}"
echo "Dashboard URL:       http://localhost:${APP_PORT}/"
if [[ -f "$INSTALL_DIR/ssl/cert.pem" ]]; then
  echo "Admin panel (HTTPS): https://$(hostname):${HTTPS_PORT}/admin  (self-signed — your browser will warn once, accept the exception)"
else
  echo "Admin panel (HTTP, no cert yet): http://localhost:${APP_PORT}/admin"
fi
echo "Auto-updater:        sudo systemctl status ${SERVICE_NAME}-updater.timer  (runs every 6h if enabled in the admin panel; branch in scripts/auto-update.conf)"
echo "Network reconciler:  sudo systemctl status dashboard-net-apply  (applies Wi-Fi/hotspot/reboot requests from the admin panel every ~5s)"
echo "Health check:        sudo systemctl status dashboard-health-check.timer  (runs once ~2min after boot; rolls back to last-known-good on failure)"
echo
if is_headless; then
  echo "Headless mode — the service is already running, nothing more to do."
else
  warn "Reboot to launch the dashboard in kiosk mode: sudo reboot"
fi
