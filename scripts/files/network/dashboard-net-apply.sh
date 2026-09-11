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
#               client Wi-Fi slots and drives hostapd (own transient
#               `systemd-run` unit, never /etc/hostapd/hostapd.conf or
#               the shared hostapd.service) + systemd-networkd's own
#               built-in DHCP-server role for the AP fallback, since
#               netplan on this system has no working Wi-Fi-AP-mode
#               renderer (`netplan info` reports no such feature) —
#               nmcli's builtin AP-mode trick has no equivalent here, so
#               this reimplements the same emergency-AP behavior
#               wifi-ap-fallback.sh/its watchdog provide on the nmcli
#               side. No dnsmasq: systemd-networkd is already running
#               and proven on this box, one less daemon to misconfigure.
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
AP_STARTED_FILE="$STATUS_DIR/ap_started_at"

NETPLAN_FILE="/etc/netplan/90-dashboard-wifi.yaml"
AP_IFACE_IP="192.168.50.1"
AP_IFACE_CIDR="192.168.50.1/24"
AP_HOSTAPD_CONF="/run/dashboard-ap-hostapd.conf"
AP_HOSTAPD_UNIT="dashboard-ap-hostapd"
# MUST sort lexically BEFORE netplan's generated
# /run/systemd/network/10-netplan-<dev>.network: systemd-networkd applies
# only the FIRST matching .network file, sorted by FILENAME across all of
# /etc, /run and /usr/lib — /etc only wins over /run for an IDENTICAL
# filename, which this is not. The old 90- name therefore always lost to
# netplan's client config, so the AP interface silently kept DHCP=ipv4
# (client) and never got 192.168.50.1 or DHCPServer=yes — hostapd came up
# and clients associated fine, then hung forever waiting for a DHCP offer
# nobody was sending. Confirmed live. Don't renumber this above 10.
AP_NETWORKD_FILE="/etc/systemd/network/05-dashboard-ap.network"
# Pre-fix name, still removed on every stop so an upgraded box can't keep
# a stale copy around.
AP_NETWORKD_FILE_LEGACY="/etc/systemd/network/90-dashboard-ap.network"

# Minimum time to stay in AP mode before trying the primary Wi-Fi again.
# Without this, reconcile_ap_netplan (called every CHECK_INTERVAL tick)
# would tear the AP down to retry the primary connection on EVERY tick —
# confirmed live: the AP was only up for the ~5s between ticks and down
# for the ~25s WIFI_RECONNECT_TIMEOUT retry window on every cycle, so it
# never stayed up long enough for a phone/laptop to even finish a scan
# before it vanished again. Now a real dwell period, not a per-tick retry.
AP_MIN_DWELL_SECONDS="${AP_MIN_DWELL_SECONDS:-300}"

CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

# Debug logging is OFF by default (an SD card is not where you want a
# verbose daemon writing forever) — touch DEBUG_LOG_FLAG on the device to
# turn it on, remove it to turn it off again, no service restart needed
# since log() checks for it fresh on every call. `logger` (journald) still
# always gets every message regardless of this flag, but journald's own
# MaxLevelStore=err policy (see harden-system.sh) silently drops anything
# below error severity system-wide — which is everything this daemon logs
# — so in practice the journal alone never has this daemon's history. This
# file is the only reliable way to pull what the daemon actually did.
DEBUG_LOG_FLAG="/etc/dashboard-net-apply-debug"
DEBUG_LOG_FILE="/var/log/dashboard-net-apply-debug.log"
DEBUG_LOG_MAX_BYTES=5242880

log() {
  logger -t dashboard-net-apply "$1"
  echo "$1"
  if [[ -f "$DEBUG_LOG_FLAG" ]]; then
    if [[ -f "$DEBUG_LOG_FILE" ]]; then
      local sz
      sz="$(stat -c%s "$DEBUG_LOG_FILE" 2>/dev/null || echo 0)"
      (( sz > DEBUG_LOG_MAX_BYTES )) && : > "$DEBUG_LOG_FILE"
    fi
    printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$DEBUG_LOG_FILE" 2>/dev/null
  fi
}

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

  # Fed the NUL-separated fields via a process-substitution FILE ARGUMENT
  # (not stdin — `python3 -` already consumes stdin as its own script
  # source when combined with the heredoc below, so a `< <(...)` stdin
  # redirect here is silently clobbered by the heredoc's own stdin
  # redirect and the script would read EOF instead of any field data;
  # confirmed live, this was producing an always-empty access-points map).
  # Passing it as argv[3] instead avoids the fd0 collision entirely.
  python3 - "$wifi_dev" "$NETPLAN_FILE" <(read_wifi_slots) <<'PYEOF'
import sys
import yaml

wifi_dev, dest, fields_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fields_path, "rb") as f:
    raw = f.read()
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

# --- netplan-backend AP fallback: hostapd for the radio, systemd-networkd's
# OWN built-in DHCP server for leases (no dnsmasq — one less daemon, one
# less place to misconfigure, and it's infrastructure already running and
# proven on this box). hostapd runs as our own transient `systemd-run`
# unit (never the shared hostapd.service/its default config). Unlike the
# nmcli path above, this is called EVERY tick, unconditionally — there is
# no separate always-on watchdog service for this backend, so the
# continuous "is primary Wi-Fi down right now, and can it be recovered"
# check lives here instead, structured exactly like
# wifi-ap-fallback-watchdog.sh's own connected/try_reconnect/start_ap
# loop: a single bad reading must NOT trigger AP mode, and once in AP
# mode this MUST keep retrying the primary connection and revert the
# instant it's back — both of those were missing in an earlier version
# of this function and caused a real, live incident (falling back to AP
# on a transient dip, then never reverting since a radio held by hostapd
# can never show a route again on its own).

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

# ufw on a provisioned box is "default deny (incoming)" (harden-system.sh)
# and only opens 22/5000/5443. systemd-networkd's DHCP server receives on a
# normal UDP socket bound to port 67, so every client DISCOVER was hitting
# INPUT DROP before it ever reached the server — the AP associated fine and
# 192.168.50.1:5000 was reachable (that port IS allowed), but nobody ever
# got a lease. ufw's own built-in DHCP rule only covers the CLIENT direction
# (sport 67 -> dport 68), not inbound server traffic. Confirmed live.
# Scoped to the AP interface and torn down again on stop, so nothing stays
# open once the box is back in normal client mode.
ap_firewall_open() {
  local dev="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    if ufw allow in on "$dev" to any port 67 proto udp >/dev/null 2>&1; then
      log "Firewall: opened UDP/67 (DHCP) on $dev via ufw"
      return 0
    fi
    log "WARNING: ufw is active but refused the DHCP rule — falling back to iptables"
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1 \
      || iptables -I INPUT 1 -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1
    log "Firewall: opened UDP/67 (DHCP) on $dev via iptables"
  else
    log "WARNING: neither ufw nor iptables available — cannot open UDP/67; DHCP may be blocked"
  fi
}

ap_firewall_close() {
  local dev="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw delete allow in on "$dev" to any port 67 proto udp >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1 || break
    done
  fi
}

start_ap_netplan() {
  local wifi_dev="$1" ssid="$2" password="$3"
  ap_hostapd_active && return 0
  log "Wi-Fi unavailable after retrying — starting emergency AP ($ssid) on $wifi_dev (staying up at least ${AP_MIN_DWELL_SECONDS}s)"
  date +%s > "$AP_STARTED_FILE" 2>/dev/null || true

  systemctl stop "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  ip link set "$wifi_dev" down >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true

  # Hand this interface to systemd-networkd's own DHCP-server role instead
  # of netplan's (client) config. See AP_NETWORKD_FILE above for why the
  # 05- prefix is load-bearing. ConfigureWithoutCarrier=yes so the address
  # is assigned even in the window before hostapd brings the radio up and
  # gives the link carrier — without it networkd waits for carrier and the
  # reconfigure below can no-op. No IPForward= here: renamed to
  # IPv4Forwarding= in systemd 256+ and this box is 257, and an emergency
  # admin AP routes nothing anyway.
  cat > "$AP_NETWORKD_FILE" <<EOF
[Match]
Name=$wifi_dev

[Network]
Address=$AP_IFACE_CIDR
DHCPServer=yes
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no

[DHCPServer]
PoolOffset=10
PoolSize=90
EmitDNS=no
EOF
  rm -f "$AP_NETWORKD_FILE_LEGACY"
  networkctl reload >/dev/null 2>&1 || true
  ip link set "$wifi_dev" up >/dev/null 2>&1 || true
  ap_firewall_open "$wifi_dev"

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

  if ! systemd-run --unit="$AP_HOSTAPD_UNIT" --collect \
      -- /usr/sbin/hostapd "$AP_HOSTAPD_CONF" >/dev/null 2>&1; then
    log "ERROR: failed to start hostapd for emergency AP — is 'hostapd' installed?"
    return
  fi

  # Only NOW reconfigure the link: hostapd has just taken the radio into
  # AP mode, so networkd re-reads its .network file against an interface
  # that is actually up. Then verify the address really landed instead of
  # assuming it did — a missing address here is exactly the failure mode
  # (clients associate, then never get a DHCP lease) that the 05- rename
  # above fixes, and it is silent unless checked for.
  networkctl reconfigure "$wifi_dev" >/dev/null 2>&1 || true
  local i ap_ip_ok="false"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ip -4 addr show dev "$wifi_dev" 2>/dev/null | grep -q "inet ${AP_IFACE_IP}/"; then
      ap_ip_ok="true"
      break
    fi
    sleep 1
  done

  if [[ "$ap_ip_ok" == "true" ]]; then
    log "Emergency AP up: $ssid (${AP_IFACE_IP}, DHCP via systemd-networkd)"
  else
    # Last resort so the admin can still reach the box by static IP even
    # if networkd refused the file: assign the address by hand. This does
    # NOT give a DHCP server (only networkd can do that here), so it is
    # logged as an ERROR, not treated as success.
    ip addr add "$AP_IFACE_CIDR" dev "$wifi_dev" >/dev/null 2>&1 || true
    log "ERROR: ${AP_IFACE_IP} not assigned by systemd-networkd — no DHCP server on $wifi_dev; clients will associate but get no IP"
  fi
  log "AP link state: $(networkctl status "$wifi_dev" 2>/dev/null | tr -s ' \n' ' ' | grep -o 'Network File: [^ ]*' || echo 'unknown')"
  log "AP addresses: $(ip -4 -o addr show dev "$wifi_dev" 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | tr '\n' ' ')"
  if ss -lun 2>/dev/null | grep -q ":67[[:space:]]"; then
    log "AP DHCP server: listening on UDP/67"
  else
    log "ERROR: nothing listening on UDP/67 — systemd-networkd did not start its DHCP server"
  fi
}

# stop_ap_netplan — always safe to call even if the AP isn't active
# (e.g. after a successful reconnect attempt): removes the AP-mode
# networkd config (so it stops claiming DHCPServer duty on this link)
# and restores the normal netplan-managed client.
stop_ap_netplan() {
  local wifi_dev="$1"
  ap_hostapd_active && log "Stopping emergency AP to attempt reconnect to primary Wi-Fi"
  systemctl stop "$AP_HOSTAPD_UNIT" >/dev/null 2>&1 || true
  rm -f "$AP_NETWORKD_FILE" "$AP_NETWORKD_FILE_LEGACY" "$AP_STARTED_FILE"
  ap_firewall_close "$wifi_dev"
  networkctl reload >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true
  systemctl start "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  netplan apply >/dev/null 2>&1 || true
}

# try_reconnect_netplan — mirrors wifi-ap-fallback-watchdog.sh's
# try_reconnect() exactly: always attempt the primary connection first
# (whether or not the AP is currently up) and give it a real timeout
# window before giving up, rather than reacting to a single tick's
# reading. This is what makes falling back to AP a last resort instead
# of a hair-trigger, AND what lets the daemon find its way back out of
# AP mode once the primary network is actually reachable again.
try_reconnect_netplan() {
  local wifi_dev="$1" timeout="${WIFI_RECONNECT_TIMEOUT:-25}"
  log "Attempting to reconnect to primary Wi-Fi (timeout ${timeout}s)"
  stop_ap_netplan "$wifi_dev"
  local i
  for ((i = 0; i < timeout; i++)); do
    if wifi_connected_netplan "$wifi_dev"; then
      log "Primary Wi-Fi reconnect succeeded after ${i}s"
      return 0
    fi
    sleep 1
  done
  if wifi_connected_netplan "$wifi_dev"; then
    log "Primary Wi-Fi reconnect succeeded after ${timeout}s"
    return 0
  fi
  log "Primary Wi-Fi reconnect failed after ${timeout}s"
  return 1
}

# reconcile_ap_netplan — called every tick. Once the AP is actually up,
# AP_MIN_DWELL_SECONDS gates any further reconnect attempt: without this,
# this function tore the AP down to retry the primary connection on
# EVERY tick (CHECK_INTERVAL, ~5s), leaving it visible for only the ~5s
# between ticks and down for the whole ~25s retry window on every single
# cycle — confirmed live, a phone/laptop couldn't even finish a scan
# before it vanished again. Now it stays up for a real dwell window
# before trying the primary network again.
reconcile_ap_netplan() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_ap_config)
  local enabled="${fields[0]:-0}" ssid="${fields[1]:-}" password="${fields[2]:-}"

  if [[ "$enabled" != "1" || -z "$ssid" || -z "$password" ]]; then
    ap_hostapd_active && stop_ap_netplan "$wifi_dev"
    return
  fi
  if ! command -v hostapd >/dev/null 2>&1; then
    log "AP fallback enabled but hostapd not installed — skipping (see deploy-dashboard.sh)"
    return
  fi

  if wifi_connected_netplan "$wifi_dev" && ! ap_hostapd_active; then
    return  # already fine, nothing to do — the common case, checked cheaply first
  fi

  if ap_hostapd_active; then
    local started_at elapsed
    started_at="$(cat "$AP_STARTED_FILE" 2>/dev/null || echo 0)"
    elapsed=$(( $(date +%s) - started_at ))
    if (( elapsed < AP_MIN_DWELL_SECONDS )); then
      return  # still within the dwell window — stay in AP mode, don't retry yet
    fi
  fi

  if try_reconnect_netplan "$wifi_dev"; then
    log "Wi-Fi reconnected — staying in client mode"
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

  # installed = hostapd binary present (capability), enabled = net_config.json
  # says it should be on (persisted intent), active = hostapd actually running
  # right now — three independent facts, not one collapsed into "active".
  # Collapsing them (an earlier version of this function did) makes the admin
  # panel report "not installed" for a fully configured, working AP fallback
  # any time it's correctly NOT currently active, which is the common case.
  command -v hostapd >/dev/null 2>&1 && ap_installed="true"
  local -a ap_fields=()
  mapfile -d '' -t ap_fields < <(read_ap_config)
  [[ "${ap_fields[0]:-0}" == "1" ]] && ap_enabled="true"

  if ap_hostapd_active; then
    ap_active="true"
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
# Upgrade cleanup: a box provisioned before the 05- rename could still
# carry the old, always-losing 90- file if the daemon was killed while the AP
# was up. It never wins against netplan's 10-netplan-*.network anyway, but
# leaving it behind is confusing — drop it unconditionally at startup.
rm -f "$AP_NETWORKD_FILE_LEGACY"
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
