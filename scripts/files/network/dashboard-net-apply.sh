#!/bin/bash
# Installed at /usr/local/sbin/dashboard-net-apply by deploy-dashboard.sh.
# Root-run polling daemon (systemd unit has no User= line, same as
# wifi-ap-fallback.service) that is the ONLY thing on this box with
# privilege to change Wi-Fi/reboot as a result of admin-panel input. The
# Flask app itself never runs anything as root and never holds a sudo
# grant for this feature — it only ever writes plain files into its own
# workspace ({{INSTALL_DIR}}/net_config.json, {{INSTALL_DIR}}/reboot.request)
# describing DESIRED state; this daemon polls those files and reconciles
# real system state to match, then publishes OBSERVED state (never
# secrets) to /run/dashboard-net/status.json for the app to read back.
#
# Two Wi-Fi backends, auto-detected every tick (never assumed):
#   - "nmcli"   Raspberry Pi OS Bookworm+ and any image with NetworkManager
#               installed. Same nmcli calls this daemon has always used.
#   - "netplan" Armbian/Orange Pi images (and any Debian-family image)
#               that have no NetworkManager but DO use netplan +
#               systemd-networkd + wpa_supplicant — confirmed live on a
#               real Orange Pi Zero 3 (Armbian trixie) where `nmcli` isn't
#               installed at all but `netplan`/`wpa_supplicant` are. This
#               backend writes a dedicated netplan YAML file for the
#               client Wi-Fi slots and drives hostapd+dnsmasq directly
#               for the AP fallback, since netplan on this system has no
#               working Wi-Fi-AP-mode renderer (`netplan info` reports no
#               such feature) — nmcli's builtin AP-mode trick has no
#               equivalent here, so this reimplements the same emergency-
#               AP behavior wifi-ap-fallback.sh/its watchdog provide on
#               the nmcli side, using hostapd/dnsmasq as its own isolated
#               `systemd-run` units instead of persistent system services
#               (never touches /etc/hostapd/hostapd.conf or the default
#               dnsmasq.service — avoids clobbering anything else that
#               might use those on the box).
#   - "none"    Neither present — every network action is skipped (reboot
#               handling still works, it has nothing to do with Wi-Fi).
#
# Not `set -e`: runs forever in a polling loop, and a single failed
# nmcli/netplan/systemctl call must be logged and retried next tick, not
# kill the daemon — same reasoning as wifi-ap-fallback-watchdog.sh.
set -u

INSTALL_DIR="{{INSTALL_DIR}}"
RUN_USER="{{RUN_USER}}"

NET_CONFIG_FILE="$INSTALL_DIR/net_config.json"
REBOOT_FLAG="$INSTALL_DIR/reboot.request"
AP_FALLBACK_SCRIPT="$INSTALL_DIR/scripts/wifi-ap-fallback.sh"

STATUS_DIR="/run/dashboard-net"
STATUS_FILE="$STATUS_DIR/status.json"
APPLIED_HASH_FILE="$STATUS_DIR/applied.sha256"
APPLIED_SSIDS_FILE="$STATUS_DIR/applied_ssids"

NETPLAN_FILE="/etc/netplan/90-dashboard-wifi.yaml"
AP_IFACE_IP="192.168.50.1"
AP_IFACE_CIDR="192.168.50.1/24"
AP_DHCP_RANGE_START="192.168.50.10"
AP_DHCP_RANGE_END="192.168.50.100"
AP_HOSTAPD_CONF="/run/dashboard-ap-hostapd.conf"
AP_DNSMASQ_CONF="/run/dashboard-ap-dnsmasq.conf"
AP_HOSTAPD_UNIT="dashboard-ap-hostapd"
AP_DNSMASQ_UNIT="dashboard-ap-dnsmasq"

CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

log() { logger -t dashboard-net-apply "$1"; echo "$1"; }

# detect_backend — nmcli preferred whenever present (matches every
# existing script in this repo, which all assume NetworkManager on
# Raspberry Pi OS); netplan only considered when nmcli is genuinely
# absent AND this looks like a real netplan-managed system.
detect_backend() {
  if command -v nmcli >/dev/null 2>&1; then
    echo "nmcli"
  elif command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
    echo "netplan"
  else
    echo "none"
  fi
}

# detect_wifi_dev — backend-specific: nmcli already knows device roles;
# without it, a wireless device is identified the portable, tool-free way
# (every wifi netdev has a "wireless" subdir under /sys/class/net/<dev>).
detect_wifi_dev() {
  local backend="$1"
  if [[ "$backend" == "nmcli" ]]; then
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
  else
    local d
    for d in /sys/class/net/*/wireless; do
      [[ -d "$d" ]] || continue
      basename "$(dirname "$d")"
      return
    done
  fi
}

# reconcile_reboot — checked every tick, first, independent of any Wi-Fi
# backend even being present: a reboot request has nothing to do with
# networking.
reconcile_reboot() {
  if [[ -f "$REBOOT_FLAG" ]]; then
    rm -f "$REBOOT_FLAG"
    log "Reboot requested via admin panel — rebooting now."
    systemctl reboot
  fi
}

# Emits NUL-separated "ssid\0password\0" pairs for up to 2 configured Wi-Fi
# slots. NUL-separated (not newline/pipe-delimited) so an SSID or password
# containing any other byte still round-trips correctly into bash.
read_wifi_slots() {
  python3 - "$NET_CONFIG_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
for slot in (cfg.get("wifi") or [])[:2]:
    ssid = (slot.get("ssid") or "").strip()
    if not ssid:
        continue
    sys.stdout.write(ssid + "\0" + (slot.get("password") or "") + "\0")
PYEOF
}

# Emits NUL-separated "enabled\0ssid\0password\0" for the AP-fallback config.
read_ap_config() {
  python3 - "$NET_CONFIG_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
ap = cfg.get("ap_fallback") or {}
enabled = "1" if ap.get("enabled") else "0"
sys.stdout.write(enabled + "\0" + (ap.get("ssid") or "") + "\0" + (ap.get("password") or "") + "\0")
PYEOF
}

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# JSON-encodes one SSID name per line of stdin into a JSON array — used to
# report currently-configured Wi-Fi networks to the admin panel (see
# known_ssids in write_status_*()) so it can show/prefill what's ALREADY
# configured on this box (e.g. provision-pi.sh's initial setup, or an
# Armbian image's own board-bring-up netplan file) instead of blank
# fields the first time net_config.json doesn't exist yet.
json_string_array() {
  python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))'
}

reconcile_wifi() {
  local backend="$1" wifi_dev="$2"
  if [[ "$backend" == "nmcli" ]]; then
    reconcile_wifi_nmcli "$wifi_dev"
  else
    reconcile_wifi_netplan "$wifi_dev"
  fi
}

# reconcile_wifi_nmcli — idempotent delete-then-recreate per slot (same
# shape as provision-pi.sh's connect_wifi()/connect_wifi_auto()), ranked
# by list order via connection.autoconnect-priority so NetworkManager
# prefers slot 1 and falls back to slot 2 as it comes into range. Any
# profile this daemon previously applied but that's no longer in the
# current config is deleted — tracked in a tmpfs file so a reboot (which
# wipes tmpfs) always starts from "nothing applied yet" and simply
# re-applies the current config fresh on its first tick.
reconcile_wifi_nmcli() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_wifi_slots)

  local -a new_ssids=()
  local idx=0 i ssid password priority
  for ((i = 0; i < ${#fields[@]}; i += 2)); do
    ssid="${fields[i]}"
    password="${fields[i + 1]}"
    priority=$((100 - idx * 10))
    new_ssids+=("$ssid")
    nmcli connection delete "$ssid" >/dev/null 2>&1 || true
    if [[ -n "$password" ]]; then
      if nmcli connection add type wifi ifname "$wifi_dev" con-name "$ssid" ssid "$ssid" \
          wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" \
          connection.autoconnect yes connection.autoconnect-priority "$priority" >/dev/null 2>&1; then
        log "Configured Wi-Fi profile: $ssid (priority $priority)"
      else
        log "ERROR: failed to configure Wi-Fi profile $ssid"
      fi
    else
      if nmcli connection add type wifi ifname "$wifi_dev" con-name "$ssid" ssid "$ssid" \
          connection.autoconnect yes connection.autoconnect-priority "$priority" >/dev/null 2>&1; then
        log "Configured open Wi-Fi profile: $ssid (priority $priority)"
      else
        log "ERROR: failed to configure Wi-Fi profile $ssid"
      fi
    fi
    idx=$((idx + 1))
  done

  local -a old_ssids=()
  [[ -f "$APPLIED_SSIDS_FILE" ]] && mapfile -t old_ssids < "$APPLIED_SSIDS_FILE"
  local old cur keep
  for old in "${old_ssids[@]}"; do
    [[ -z "$old" ]] && continue
    keep=false
    for cur in "${new_ssids[@]}"; do
      [[ "$old" == "$cur" ]] && { keep=true; break; }
    done
    if ! "$keep"; then
      nmcli connection delete "$old" >/dev/null 2>&1 || true
      log "Removed stale Wi-Fi profile: $old"
    fi
  done

  printf '%s\n' "${new_ssids[@]}" > "$APPLIED_SSIDS_FILE"
}

# reconcile_wifi_netplan — writes ONE dedicated file
# ($NETPLAN_FILE) this daemon fully owns (always render-and-overwrite,
# same "no partial patch" idiom as lib.sh's render_template — nothing to
# check-before-writing). Up to 2 access-points, no per-AP priority key in
# netplan's schema, so ranking a preferred network isn't possible here
# the way nmcli's autoconnect-priority does it — wpa_supplicant itself
# still prefers whichever configured network has the strongest/only
# signal present, which is an acceptable behavior gap for a 2-slot
# fallback list, not a bug to chase further.
#
# Before first use, claims exclusive ownership of this Wi-Fi device: any
# OTHER /etc/netplan/*.yaml file that also configures this device (e.g.
# an Armbian board-bring-up file with the SSID set at image-build time)
# would otherwise silently deep-merge with ours and leave stale/foreign
# networks active. That device key is removed from the foreign file
# (backed up once, `.dashboard-orig.bak`, before ever being touched) via
# a real YAML parse/rewrite (PyYAML — already a transitive dependency of
# python3-netplan, confirmed present) rather than text-editing YAML by
# hand, since indentation-sensitive formats are exactly where a
# sed/regex edit silently produces a subtly-broken file.
reconcile_wifi_netplan() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_wifi_slots)

  python3 - "$wifi_dev" "$NETPLAN_FILE" <<'PYEOF'
import glob, os, shutil, sys
import yaml

wifi_dev, our_file = sys.argv[1], sys.argv[2]
for path in glob.glob("/etc/netplan/*.yaml"):
    if os.path.realpath(path) == os.path.realpath(our_file):
        continue
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except Exception:
        continue
    net = doc.get("network") or {}
    wifis = net.get("wifis") or {}
    if wifi_dev not in wifis:
        continue
    backup = path + ".dashboard-orig.bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
    del wifis[wifi_dev]
    if wifis:
        net["wifis"] = wifis
    else:
        net.pop("wifis", None)
    doc["network"] = net
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
    print(f"Claimed {wifi_dev} from {path} (backed up to {backup})")
PYEOF

  local -a new_ssids=()
  local i
  for ((i = 0; i < ${#fields[@]}; i += 2)); do
    new_ssids+=("${fields[i]}")
  done

  # Fed the NUL-separated fields directly via stdin (rather than
  # re-parsing net_config.json from Python again) so SSID/password bytes
  # round-trip exactly as read_wifi_slots already extracted them.
  python3 - "$wifi_dev" "$NETPLAN_FILE" < <(read_wifi_slots) <<'PYEOF'
import sys
import yaml

wifi_dev, dest = sys.argv[1], sys.argv[2]
raw = sys.stdin.buffer.read()
parts = raw.split(b"\0")[:-1] if raw.endswith(b"\0") else raw.split(b"\0")
aps = {}
for i in range(0, len(parts) - 1, 2):
    ssid = parts[i].decode("utf-8", "replace")
    password = parts[i + 1].decode("utf-8", "replace")
    aps[ssid] = ({"password": password} if password else {})

doc = {
    "network": {
        "version": 2,
        "renderer": "networkd",
        "wifis": {
            wifi_dev: {
                "dhcp4": True,
                "access-points": aps,
            }
        },
    }
}
with open(dest, "w", encoding="utf-8") as f:
    f.write("# Managed by dashboard-net-apply — do not edit by hand, it is\n")
    f.write("# regenerated from net_config.json on every change.\n")
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
  chmod 600 "$NETPLAN_FILE" 2>/dev/null || true

  if netplan apply >/dev/null 2>&1; then
    log "Applied netplan Wi-Fi config (${#new_ssids[@]} network(s))"
  else
    log "ERROR: netplan apply failed"
  fi
  printf '%s\n' "${new_ssids[@]}" > "$APPLIED_SSIDS_FILE"
}

# reconcile_ap_fallback_nmcli — never reimplements wifi-ap-fallback.sh's
# nmcli logic; either invokes it as-is (dropping from root to RUN_USER,
# since that script refuses to run as root itself and does its own
# internal sudo for the parts that need it — no password needed, the
# caller here already has full privilege) or disables the service it
# installs. Hash-gated (called only when net_config.json changes) because
# the CONTINUOUS "is primary Wi-Fi actually down right now" toggling is
# already handled by wifi-ap-fallback-watchdog.sh's own independent
# 15s-interval loop — this function only ever installs/updates/disables
# that whole subsystem, never toggles the AP itself.
reconcile_ap_fallback_nmcli() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_ap_config)
  local enabled="${fields[0]:-0}" ssid="${fields[1]:-}" password="${fields[2]:-}"

  if [[ "$enabled" == "1" ]]; then
    if [[ -z "$ssid" || -z "$password" ]]; then
      log "AP fallback enabled but SSID/password missing in net_config.json — skipping"
      return
    fi
    if [[ ! -x "$AP_FALLBACK_SCRIPT" && ! -f "$AP_FALLBACK_SCRIPT" ]]; then
      log "ERROR: $AP_FALLBACK_SCRIPT not found — can't configure AP fallback"
      return
    fi
    local primary_conn
    if [[ -f /etc/wifi-ap-fallback/config ]]; then
      primary_conn="$(source /etc/wifi-ap-fallback/config 2>/dev/null; echo "${PRIMARY_CONN:-}")"
    fi
    if [[ -z "${primary_conn:-}" ]]; then
      primary_conn="$(nmcli -t -f GENERAL.CONNECTION device show "$wifi_dev" 2>/dev/null | cut -d: -f2)"
    fi
    if [[ -z "${primary_conn:-}" || "$primary_conn" == "--" ]]; then
      log "AP fallback enabled but no primary Wi-Fi connection is known yet — skipping until a Wi-Fi profile is configured/connected"
      return
    fi
    log "Configuring/updating emergency AP fallback (primary=$primary_conn)"
    if sudo -u "$RUN_USER" env WIFI_CONNECTION="$primary_conn" AP_SSID="$ssid" AP_PASSWORD="$password" \
        bash "$AP_FALLBACK_SCRIPT" >/dev/null 2>&1; then
      log "AP fallback configured"
    else
      log "ERROR: wifi-ap-fallback.sh failed"
    fi
  else
    if systemctl is-enabled wifi-ap-fallback.service >/dev/null 2>&1 || \
       systemctl is-active wifi-ap-fallback.service >/dev/null 2>&1; then
      log "Disabling emergency AP fallback"
      systemctl disable --now wifi-ap-fallback.service >/dev/null 2>&1 || true
      nmcli connection down Emergency-AP >/dev/null 2>&1 || true
    fi
  fi
}

# --- netplan-backend AP fallback: hostapd + dnsmasq, run as our own
# transient systemd-run units (never the shared hostapd.service/
# dnsmasq.service or their default configs, so this never conflicts with
# anything else that might use those on the box). Unlike the nmcli path
# above, this is called EVERY tick, unconditionally — there is no
# separate always-on watchdog service for this backend, so the
# continuous "is primary Wi-Fi down right now" check lives here instead.

ap_hostapd_active() {
  systemctl is-active --quiet "$AP_HOSTAPD_UNIT" 2>/dev/null
}

# wifi_connected_netplan — a real default route through the device is a
# stronger signal than link state alone (matches the nmcli path's use of
# GENERAL.STATE==100, "fully activated," not just "link up").
wifi_connected_netplan() {
  local dev="$1"
  ip -4 route show dev "$dev" 2>/dev/null | grep -q '^default'
}

start_ap_netplan() {
  local wifi_dev="$1" ssid="$2" password="$3"
  ap_hostapd_active && return 0
  log "Wi-Fi unavailable — starting emergency AP ($ssid) via hostapd/dnsmasq on $wifi_dev"

  systemctl stop "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  ip link set "$wifi_dev" down >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true
  ip link set "$wifi_dev" up >/dev/null 2>&1 || true
  ip addr add "$AP_IFACE_CIDR" dev "$wifi_dev" >/dev/null 2>&1 || true

  cat > "$AP_HOSTAPD_CONF" <<EOF
interface=$wifi_dev
driver=nl80211
ssid=$ssid
hw_mode=g
channel=6
ieee80211n=1
wpa=2
wpa_passphrase=$password
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  chmod 600 "$AP_HOSTAPD_CONF"

  cat > "$AP_DNSMASQ_CONF" <<EOF
interface=$wifi_dev
bind-interfaces
except-interface=lo
dhcp-range=$AP_DHCP_RANGE_START,$AP_DHCP_RANGE_END,255.255.255.0,12h
EOF

  if systemd-run --unit="$AP_HOSTAPD_UNIT" --collect \
      -- /usr/sbin/hostapd "$AP_HOSTAPD_CONF" >/dev/null 2>&1 && \
     systemd-run --unit="$AP_DNSMASQ_UNIT" --collect \
      -- /usr/sbin/dnsmasq --keep-in-foreground --conf-file="$AP_DNSMASQ_CONF" >/dev/null 2>&1; then
    log "Emergency AP up: $ssid (${AP_IFACE_IP})"
  else
    log "ERROR: failed to start hostapd/dnsmasq for emergency AP — is 'hostapd dnsmasq' installed?"
  fi
}

stop_ap_netplan() {
  local wifi_dev="$1"
  ap_hostapd_active || return 0
  log "Normal Wi-Fi is back (or fallback disabled) — stopping emergency AP, restoring client mode on $wifi_dev"
  systemctl stop "$AP_HOSTAPD_UNIT" "$AP_DNSMASQ_UNIT" >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true
  systemctl start "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  netplan apply >/dev/null 2>&1 || true
}

reconcile_ap_netplan() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_ap_config)
  local enabled="${fields[0]:-0}" ssid="${fields[1]:-}" password="${fields[2]:-}"

  if [[ "$enabled" != "1" || -z "$ssid" || -z "$password" ]]; then
    stop_ap_netplan "$wifi_dev"
    return
  fi
  if ! command -v hostapd >/dev/null 2>&1 || ! command -v dnsmasq >/dev/null 2>&1; then
    log "AP fallback enabled but hostapd/dnsmasq not installed — skipping (see deploy-dashboard.sh)"
    return
  fi
  if wifi_connected_netplan "$wifi_dev"; then
    stop_ap_netplan "$wifi_dev"
  else
    start_ap_netplan "$wifi_dev" "$ssid" "$password"
  fi
}

write_status() {
  local backend="$1" wifi_dev="$2"
  if [[ "$backend" == "nmcli" ]]; then
    write_status_nmcli "$wifi_dev"
  else
    write_status_netplan "$wifi_dev"
  fi
}

write_status_nmcli() {
  local wifi_dev="$1"
  mkdir -p "$STATUS_DIR"
  local state conn ip ap_installed ap_enabled ap_active
  state="$(nmcli -t -f GENERAL.STATE device show "$wifi_dev" 2>/dev/null | cut -d: -f1)"
  conn="$(nmcli -t -f GENERAL.CONNECTION device show "$wifi_dev" 2>/dev/null | cut -d: -f1)"
  ip="$(nmcli -g IP4.ADDRESS device show "$wifi_dev" 2>/dev/null | head -n1 | cut -d/ -f1)"
  [[ "$conn" == "--" ]] && conn=""
  [[ "$ip" == "--" ]] && ip=""

  ap_installed="false"; ap_enabled="false"; ap_active="false"
  [[ -f /etc/systemd/system/wifi-ap-fallback.service ]] && ap_installed="true"
  systemctl is-enabled wifi-ap-fallback.service >/dev/null 2>&1 && ap_enabled="true"
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "Emergency-AP" && ap_active="true"

  # All saved Wi-Fi client profiles (not just the active one), excluding
  # the Emergency-AP itself — reported so the admin panel can show/prefill
  # networks that are already configured on this box even before
  # net_config.json has ever been saved through it (e.g. provision-pi.sh's
  # initial "dashboard" SSID, or one set up by hand with nmcli/raspi-config).
  local known_ssids_json
  known_ssids_json="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: '$2=="802-11-wireless" && $1!="Emergency-AP"{print $1}' \
    | json_string_array)"

  _write_status_json "$( [[ "$state" == "100" ]] && echo true || echo false )" \
    "$conn" "$ip" "$known_ssids_json" "$ap_installed" "$ap_enabled" "$ap_active"
}

# write_status_netplan — SSID/IP/known-networks discovered without any
# extra WiFi-specific CLI tool: `ip` (already required) plus a plain YAML
# read of our own managed file for "known" networks (the AP-fallback
# case's own SSID is intentionally excluded, same as the nmcli path
# excludes Emergency-AP) and, on first run before we've ever written
# $NETPLAN_FILE, whatever `netplan status` reports as currently active —
# this is exactly the discovery path that lets the admin panel prefill a
# network that was already configured at image-build time (e.g. an
# Armbian board's own bring-up netplan file) before this daemon ever
# takes it over.
write_status_netplan() {
  local wifi_dev="$1"
  mkdir -p "$STATUS_DIR"
  local connected="false" conn="" ip="" ap_installed="false" ap_enabled="false" ap_active="false"

  if ap_hostapd_active; then
    ap_installed="true"; ap_enabled="true"; ap_active="true"
    conn=""; ip="$AP_IFACE_IP"
  else
    if wifi_connected_netplan "$wifi_dev"; then
      connected="true"
    fi
    # `iw` gives a stable, well-documented "SSID: <name>" line — far less
    # risky to depend on than guessing netplan's JSON status schema.
    if command -v iw >/dev/null 2>&1; then
      conn="$(iw dev "$wifi_dev" link 2>/dev/null | awk -F': ' '/^[[:space:]]*SSID:/{print $2; exit}')"
    fi
    ip="$(ip -4 -o addr show dev "$wifi_dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  fi

  local known_ssids_json
  known_ssids_json="$(python3 - "$NETPLAN_FILE" "$wifi_dev" <<'PYEOF'
import sys
try:
    import yaml
except Exception:
    print("[]")
    raise SystemExit
import glob, json, os

our_file, wifi_dev = sys.argv[1], sys.argv[2]
names = []
for path in glob.glob("/etc/netplan/*.yaml"):
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except Exception:
        continue
    aps = (((doc.get("network") or {}).get("wifis") or {}).get(wifi_dev) or {}).get("access-points") or {}
    for ssid in aps:
        if ssid not in names:
            names.append(ssid)
print(json.dumps(names))
PYEOF
)"

  _write_status_json "$connected" "$conn" "$ip" "$known_ssids_json" "$ap_installed" "$ap_enabled" "$ap_active"
}

_write_status_json() {
  local connected="$1" conn="$2" ip="$3" known_ssids_json="$4" ap_installed="$5" ap_enabled="$6" ap_active="$7"
  cat > "$STATUS_FILE.tmp" <<EOF
{
  "connected": $connected,
  "ssid": $(json_string "$conn"),
  "ip": $(json_string "$ip"),
  "known_ssids": $known_ssids_json,
  "ap_installed": $ap_installed,
  "ap_enabled": $ap_enabled,
  "ap_active": $ap_active,
  "last_applied": $(date +%s)
}
EOF
  mv "$STATUS_FILE.tmp" "$STATUS_FILE"
  chmod 644 "$STATUS_FILE"
}

log "dashboard-net-apply daemon started (config=$NET_CONFIG_FILE)"
mkdir -p "$STATUS_DIR"
nmcli radio wifi on >/dev/null 2>&1 || true

while true; do
  reconcile_reboot

  BACKEND="$(detect_backend)"
  if [[ "$BACKEND" != "none" ]]; then
    WIFI_DEV="$(detect_wifi_dev "$BACKEND")"
    if [[ -n "$WIFI_DEV" ]]; then
      if [[ -f "$NET_CONFIG_FILE" ]]; then
        new_hash="$(sha256sum "$NET_CONFIG_FILE" 2>/dev/null | awk '{print $1}')"
        old_hash=""
        [[ -f "$APPLIED_HASH_FILE" ]] && old_hash="$(cat "$APPLIED_HASH_FILE")"
        if [[ -n "$new_hash" && "$new_hash" != "$old_hash" ]]; then
          log "net_config.json changed — reconciling ($BACKEND backend)"
          reconcile_wifi "$BACKEND" "$WIFI_DEV"
          if [[ "$BACKEND" == "nmcli" ]]; then
            reconcile_ap_fallback_nmcli "$WIFI_DEV"
          fi
          echo "$new_hash" > "$APPLIED_HASH_FILE"
        fi
      fi
      # The netplan backend has no separate always-on AP watchdog service
      # (the nmcli backend's is wifi-ap-fallback.sh's own), so its AP
      # toggle is re-evaluated every tick here instead of only on config
      # change.
      if [[ "$BACKEND" == "netplan" ]]; then
        reconcile_ap_netplan "$WIFI_DEV"
      fi
      write_status "$BACKEND" "$WIFI_DEV"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
