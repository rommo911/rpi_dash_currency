#!/bin/bash
# Root-run daemon (no User=) that applies admin-panel Wi-Fi/reboot input;
# Flask only writes desired-state files. Backend: nmcli, else netplan (Armbian), else none.
set -u

INSTALL_DIR="/home/kiosk/currency-dashboard"
RUN_USER="kiosk"

NET_CONFIG_FILE="$INSTALL_DIR/net_config.json"
REBOOT_FLAG="$INSTALL_DIR/reboot.request"
AP_FALLBACK_SCRIPT="$INSTALL_DIR/scripts/wifi-ap-fallback.sh"

STATUS_DIR="/run/dashboard-net"
STATUS_FILE="$STATUS_DIR/status.json"
# Marker only now (mtime vs NET_CONFIG_FILE, see main loop); name kept as-is.
APPLIED_HASH_FILE="$STATUS_DIR/applied.sha256"
APPLIED_SSIDS_FILE="$STATUS_DIR/applied_ssids"
AP_STARTED_FILE="$STATUS_DIR/ap_started_at"
DISCONNECTED_SINCE_FILE="$STATUS_DIR/disconnected_since"
AP_CLIENT_FREE_SINCE_FILE="$STATUS_DIR/ap_client_free_since"

# Cached to avoid two python3 spawns per tick; refreshed only on config
# change (refresh_status_cache_netplan). Defaults until that first runs.
CACHED_KNOWN_SSIDS_JSON="[]"
CACHED_AP_ENABLED="false"

NETPLAN_FILE="/etc/netplan/90-dashboard-wifi.yaml"
AP_IFACE_IP="192.168.50.1"
AP_IFACE_CIDR="192.168.50.1/24"
AP_HOSTAPD_CONF="/run/dashboard-ap-hostapd.conf"
AP_HOSTAPD_UNIT="dashboard-ap-hostapd"
# Must sort lexically before netplan's 10-netplan-*.network (systemd-
# networkd applies only the first match) — confirmed live. Don't renumber above 10.
AP_NETWORKD_FILE="/etc/systemd/network/05-dashboard-ap.network"
# Pre-fix name, still removed on every stop so an upgraded box can't keep
# a stale copy around.
AP_NETWORKD_FILE_LEGACY="/etc/systemd/network/90-dashboard-ap.network"

# How long primary Wi-Fi must be down before the AP starts at all.
AP_FALLBACK_DELAY_SECONDS="${AP_FALLBACK_DELAY_SECONDS:-180}"

# How long the AP must be client-free before retrying primary Wi-Fi —
# timer resets to 0 whenever a client is connected (see reconcile_ap_active_netplan).
AP_MIN_DWELL_SECONDS="${AP_MIN_DWELL_SECONDS:-300}"

CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

# Off by default (SD wear) — touch DEBUG_LOG_FLAG to enable, no restart
# needed. journald drops below-error logs system-wide, so this file is the only history.
DEBUG_LOG_FLAG="/etc/dashboard-net-apply-debug"
DEBUG_LOG_FILE="/var/log/dashboard-net-apply-debug.log"
DEBUG_LOG_MAX_BYTES=5242880

if [[ -f "${INSTALL_DIR:-/home/kiosk/currency-dashboard}/scripts/lib.sh" ]]; then
  # shellcheck disable=SC1090
  source "${INSTALL_DIR:-/home/kiosk/currency-dashboard}/scripts/lib.sh"
  log() {
    local msg="$*"
    case "$msg" in
      ERROR:*) log_error "${msg#ERROR: }" ;;
      WARN:*|WARNING:*) log_warn "${msg#*:* }" ;;
      DEBUG:*) log_debug "${msg#DEBUG: }" ;;
      *) log_info "$msg" ;;
    esac
  }
else
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
fi

# detect_backend — nmcli preferred whenever present; netplan only when
# nmcli is genuinely absent and this looks netplan-managed.
detect_backend() {
  if command -v nmcli >/dev/null 2>&1; then
    echo "nmcli"
  elif command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
    echo "netplan"
  else
    echo "none"
  fi
}

# detect_wifi_dev — nmcli knows device roles directly; otherwise a
# wifi netdev is any with a "wireless" subdir under /sys/class/net.
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

# reconcile_reboot — checked first every tick, independent of any Wi-Fi
# backend.
reconcile_reboot() {
  if [[ -f "$REBOOT_FLAG" ]]; then
    rm -f "$REBOOT_FLAG"
    log_info "Reboot requested via admin panel — rebooting now."
    systemctl reboot
  fi
}

# NUL-separated "ssid\0password\0" pairs — not newline/pipe-delimited,
# so any byte in an SSID/password round-trips correctly.
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

# JSON-encodes SSID names (one per stdin line) so the admin panel can
# prefill already-configured networks instead of blank fields.
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

# reconcile_wifi_nmcli — idempotent delete-then-recreate per slot, ranked
# via connection.autoconnect-priority. Stale profiles tracked in a tmpfs file.
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
        log_info "Configured Wi-Fi profile: $ssid (priority $priority)"
      else
        log_error "Failed to configure Wi-Fi profile $ssid"
      fi
    else
      if nmcli connection add type wifi ifname "$wifi_dev" con-name "$ssid" ssid "$ssid" \
          connection.autoconnect yes connection.autoconnect-priority "$priority" >/dev/null 2>&1; then
        log_info "Configured open Wi-Fi profile: $ssid (priority $priority)"
      else
        log_error "Failed to configure Wi-Fi profile $ssid"
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
      log_info "Removed stale Wi-Fi profile: $old"
    fi
  done

  printf '%s\n' "${new_ssids[@]}" > "$APPLIED_SSIDS_FILE"
}

# reconcile_wifi_netplan — always render-and-overwrites $NETPLAN_FILE.
# First claims exclusive device ownership from any other netplan file (backed up, PyYAML rewrite).
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

  # Fields passed as argv[3] (file path), not stdin — the heredoc below
  # already owns stdin, so a `< <(...)` redirect here was silently clobbered (confirmed live).
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
    log_info "Applied netplan Wi-Fi config (${#new_ssids[@]} network(s))"
  else
    log_error "netplan apply failed"
  fi
  printf '%s\n' "${new_ssids[@]}" > "$APPLIED_SSIDS_FILE"
}

# reconcile_ap_fallback_nmcli — invokes wifi-ap-fallback.sh as RUN_USER
# (never reimplements it); the watchdog script owns the continuous AP toggle.
reconcile_ap_fallback_nmcli() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_ap_config)
  local enabled="${fields[0]:-0}" ssid="${fields[1]:-}" password="${fields[2]:-}"

  if [[ "$enabled" == "1" ]]; then
    if [[ -z "$ssid" || -z "$password" ]]; then
      log_warn "AP fallback enabled but SSID/password missing in net_config.json — skipping"
      return
    fi
    if [[ ! -x "$AP_FALLBACK_SCRIPT" && ! -f "$AP_FALLBACK_SCRIPT" ]]; then
      log_error "$AP_FALLBACK_SCRIPT not found — can't configure AP fallback"
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
      log_warn "AP fallback enabled but no primary Wi-Fi connection is known yet — skipping until a Wi-Fi profile is configured/connected"
      return
    fi
    log_info "Configuring/updating emergency AP fallback (primary=$primary_conn)"
    if sudo -u "$RUN_USER" env WIFI_CONNECTION="$primary_conn" AP_SSID="$ssid" AP_PASSWORD="$password" \
        bash "$AP_FALLBACK_SCRIPT" >/dev/null 2>&1; then
      log_info "AP fallback configured"
    else
      log_error "wifi-ap-fallback.sh failed"
    fi
  else
    if systemctl is-enabled wifi-ap-fallback.service >/dev/null 2>&1 || \
       systemctl is-active wifi-ap-fallback.service >/dev/null 2>&1; then
      log_info "Disabling emergency AP fallback"
      systemctl disable --now wifi-ap-fallback.service >/dev/null 2>&1 || true
      nmcli connection down Emergency-AP >/dev/null 2>&1 || true
    fi
  fi
}

# --- netplan-backend AP fallback: hostapd + networkd's own DHCP server.
# Called every tick — a single bad reading must not flip modes (real past incident).

ap_hostapd_active() {
  systemctl is-active --quiet "$AP_HOSTAPD_UNIT" 2>/dev/null
}

# ap_client_connected — true if a station is associated to the AP right
# now. Uses `iw` since AP_HOSTAPD_CONF sets no ctrl_interface for hostapd_cli.
ap_client_connected() {
  local dev="$1"
  command -v iw >/dev/null 2>&1 || return 1
  iw dev "$dev" station dump 2>/dev/null | grep -q '^Station '
}

# wifi_connected_netplan — a real default route is stronger signal than
# link state alone (matches nmcli's GENERAL.STATE==100 check).
wifi_connected_netplan() {
  local dev="$1"
  ip -4 route show dev "$dev" 2>/dev/null | grep -q '^default'
}

# ufw default-denies incoming, so DHCP DISCOVERs hit INPUT DROP before
# reaching the server — clients associated but never got a lease (confirmed live).
ap_firewall_open() {
  local dev="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    if ufw allow in on "$dev" to any port 67 proto udp >/dev/null 2>&1; then
      log_info "Firewall: opened UDP/67 (DHCP) on $dev via ufw"
      return 0
    fi
    log_warn "ufw refused the DHCP rule — falling back to iptables"
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1 \
      || iptables -I INPUT 1 -i "$dev" -p udp --dport 67 -j ACCEPT >/dev/null 2>&1
    log_info "Firewall: opened UDP/67 (DHCP) on $dev via iptables"
  else
    log_warn "Neither ufw nor iptables available — cannot open UDP/67; DHCP may be blocked"
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
  log_warn "Wi-Fi unavailable after retrying — starting emergency AP ($ssid) on $wifi_dev (stays up until client-free for ${AP_MIN_DWELL_SECONDS}s)"
  date +%s > "$AP_STARTED_FILE" 2>/dev/null || true
  rm -f "$DISCONNECTED_SINCE_FILE"

  systemctl stop "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  ip link set "$wifi_dev" down >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true

  # Hands the interface to networkd's DHCP-server role. ConfigureWithoutCarrier
  # avoids waiting for hostapd to bring up carrier first. No IPForward= — this AP routes nothing.
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
    log_error "Failed to start hostapd for emergency AP — is 'hostapd' installed?"
    return
  fi

  # Reconfigure only after hostapd brings the radio up, then verify the
  # address actually landed — a silent miss here means clients associate but never get a lease.
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
    log_info "Emergency AP up: $ssid (${AP_IFACE_IP}, DHCP via systemd-networkd)"
  else
    # Last resort: assign the static address by hand (no DHCP server this
    # way) so the admin can still reach it — logged as an error, not success.
    ip addr add "$AP_IFACE_CIDR" dev "$wifi_dev" >/dev/null 2>&1 || true
    log_error "${AP_IFACE_IP} not assigned by systemd-networkd — no DHCP server on $wifi_dev; clients will associate but get no IP"
  fi
  log_info "AP link state: $(networkctl status "$wifi_dev" 2>/dev/null | tr -s ' \n' ' ' | grep -o 'Network File: [^ ]*' || echo 'unknown')"
  log_info "AP addresses: $(ip -4 -o addr show dev "$wifi_dev" 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | tr '\n' ' ')"
  if ss -lun 2>/dev/null | grep -q ":67[[:space:]]"; then
    log_info "AP DHCP server: listening on UDP/67"
  else
    log_error "Nothing listening on UDP/67 — systemd-networkd did not start its DHCP server"
  fi
}

# stop_ap_netplan — safe to call even if the AP isn't active; removes
# the AP-mode networkd config and restores the normal client.
stop_ap_netplan() {
  local wifi_dev="$1"
  ap_hostapd_active && log_info "Stopping emergency AP to attempt reconnect to primary Wi-Fi"
  systemctl stop "$AP_HOSTAPD_UNIT" >/dev/null 2>&1 || true
  rm -f "$AP_NETWORKD_FILE" "$AP_NETWORKD_FILE_LEGACY" "$AP_STARTED_FILE" "$AP_CLIENT_FREE_SINCE_FILE"
  ap_firewall_close "$wifi_dev"
  networkctl reload >/dev/null 2>&1 || true
  ip addr flush dev "$wifi_dev" >/dev/null 2>&1 || true
  systemctl start "netplan-wpa-${wifi_dev}.service" >/dev/null 2>&1 || true
  netplan apply >/dev/null 2>&1 || true
}

# try_reconnect_netplan — always attempts primary first with a real
# timeout window, so AP fallback is a last resort, not a hair-trigger.
try_reconnect_netplan() {
  local wifi_dev="$1" timeout="${WIFI_RECONNECT_TIMEOUT:-25}"
  log_info "Attempting to reconnect to primary Wi-Fi (timeout ${timeout}s)"
  stop_ap_netplan "$wifi_dev"
  local i
  for ((i = 0; i < timeout; i++)); do
    if wifi_connected_netplan "$wifi_dev"; then
      log_info "Primary Wi-Fi reconnect succeeded after ${i}s"
      return 0
    fi
    sleep 1
  done
  if wifi_connected_netplan "$wifi_dev"; then
    log_info "Primary Wi-Fi reconnect succeeded after ${timeout}s"
    return 0
  fi
  log_warn "Primary Wi-Fi reconnect failed after ${timeout}s"
  return 1
}

# reconcile_ap_netplan — AP_FALLBACK_DELAY_SECONDS gates starting the AP,
# AP_MIN_DWELL_SECONDS gates leaving it — both guard against a one-tick blip.
reconcile_ap_netplan() {
  local wifi_dev="$1"
  local -a fields=()
  mapfile -d '' -t fields < <(read_ap_config)
  local enabled="${fields[0]:-0}" ssid="${fields[1]:-}" password="${fields[2]:-}"

  if [[ "$enabled" != "1" || -z "$ssid" || -z "$password" ]]; then
    ap_hostapd_active && stop_ap_netplan "$wifi_dev"
    rm -f "$DISCONNECTED_SINCE_FILE"
    return
  fi
  if ! command -v hostapd >/dev/null 2>&1; then
    log_warn "AP fallback enabled but hostapd not installed — skipping (see deploy-dashboard.sh)"
    return
  fi

  if ap_hostapd_active; then
    reconcile_ap_active_netplan "$wifi_dev" "$ssid" "$password"
    return
  fi

  if wifi_connected_netplan "$wifi_dev"; then
    rm -f "$DISCONNECTED_SINCE_FILE"
    return  # already fine, nothing to do — the common case, checked cheaply first
  fi

  # Not connected, AP not up yet. Wait out the grace window untouched —
  # retrying every tick would itself cause disconnect/reconnect churn.
  local now disconnected_since elapsed
  now="$(date +%s)"
  if [[ ! -f "$DISCONNECTED_SINCE_FILE" ]]; then
    echo "$now" > "$DISCONNECTED_SINCE_FILE"
    log_warn "Primary Wi-Fi lost — waiting up to ${AP_FALLBACK_DELAY_SECONDS}s before starting emergency AP"
    return
  fi
  disconnected_since="$(cat "$DISCONNECTED_SINCE_FILE" 2>/dev/null || echo "$now")"
  elapsed=$(( now - disconnected_since ))
  if (( elapsed < AP_FALLBACK_DELAY_SECONDS )); then
    return  # still within the grace window
  fi

  if try_reconnect_netplan "$wifi_dev"; then
    log_info "Wi-Fi reconnected — staying in client mode"
    rm -f "$DISCONNECTED_SINCE_FILE"
  else
    start_ap_netplan "$wifi_dev" "$ssid" "$password"
  fi
}

# reconcile_ap_active_netplan — called every tick while the AP is up.
# Dwell only counts down with no client connected; resets to 0 if one joins.
reconcile_ap_active_netplan() {
  local wifi_dev="$1" ssid="$2" password="$3"
  if ap_client_connected "$wifi_dev"; then
    rm -f "$AP_CLIENT_FREE_SINCE_FILE"
    return
  fi

  local now client_free_since elapsed
  now="$(date +%s)"
  if [[ ! -f "$AP_CLIENT_FREE_SINCE_FILE" ]]; then
    echo "$now" > "$AP_CLIENT_FREE_SINCE_FILE"
    return
  fi
  client_free_since="$(cat "$AP_CLIENT_FREE_SINCE_FILE" 2>/dev/null || echo "$now")"
  elapsed=$(( now - client_free_since ))
  if (( elapsed < AP_MIN_DWELL_SECONDS )); then
    return  # no client, but not for long enough yet — stay in AP mode
  fi

  if try_reconnect_netplan "$wifi_dev"; then
    log_info "Wi-Fi reconnected — staying in client mode"
    rm -f "$DISCONNECTED_SINCE_FILE"
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

  # All saved client profiles except Emergency-AP itself — lets the admin
  # panel prefill networks configured before net_config.json ever existed.
  local known_ssids_json
  known_ssids_json="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: '$2=="802-11-wireless" && $1!="Emergency-AP"{print $1}' \
    | json_string_array)"

  _write_status_json "$( [[ "$state" == "100" ]] && echo true || echo false )" \
    "$conn" "$ip" "$known_ssids_json" "$ap_installed" "$ap_enabled" "$ap_active"
}

# refresh_status_cache_netplan — recomputes known_ssids/ap_enabled (each a
# python3 spawn). Only called from the main loop's "config changed" branch.
refresh_status_cache_netplan() {
  local wifi_dev="$1"
  local -a ap_fields=()
  mapfile -d '' -t ap_fields < <(read_ap_config)
  CACHED_AP_ENABLED="false"
  [[ "${ap_fields[0]:-0}" == "1" ]] && CACHED_AP_ENABLED="true"

  CACHED_KNOWN_SSIDS_JSON="$(python3 - "$NETPLAN_FILE" "$wifi_dev" <<'PYEOF'
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
}

# write_status_netplan — SSID/IP/AP-active stay live every tick;
# known_ssids/ap_enabled come from the CACHED_* globals instead.
write_status_netplan() {
  local wifi_dev="$1"
  mkdir -p "$STATUS_DIR"
  local connected="false" conn="" ip="" ap_installed="false" ap_active="false"

  # installed/enabled/active are three independent facts — collapsing them
  # (an earlier version did) wrongly reports "not installed" whenever just inactive.
  command -v hostapd >/dev/null 2>&1 && ap_installed="true"

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

  _write_status_json "$connected" "$conn" "$ip" "$CACHED_KNOWN_SSIDS_JSON" "$ap_installed" "$CACHED_AP_ENABLED" "$ap_active"
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

log_info "dashboard-net-apply daemon started (config=$NET_CONFIG_FILE)"
mkdir -p "$STATUS_DIR"
# Upgrade cleanup: drops a stale pre-05-rename file that never wins
# against netplan's 10-netplan-*.network anyway, but is confusing to leave.
rm -f "$AP_NETWORKD_FILE_LEGACY"
nmcli radio wifi on >/dev/null 2>&1 || true

while true; do
  reconcile_reboot

  BACKEND="$(detect_backend)"
  if [[ "$BACKEND" != "none" ]]; then
    WIFI_DEV="$(detect_wifi_dev "$BACKEND")"
    if [[ -n "$WIFI_DEV" ]]; then
      if [[ -f "$NET_CONFIG_FILE" ]]; then
        # mtime check (bash builtin) instead of sha256sum+awk+cat every tick.
        if [[ ! -f "$APPLIED_HASH_FILE" || "$NET_CONFIG_FILE" -nt "$APPLIED_HASH_FILE" ]]; then
          log_info "net_config.json changed — reconciling ($BACKEND backend)"
          reconcile_wifi "$BACKEND" "$WIFI_DEV"
          if [[ "$BACKEND" == "nmcli" ]]; then
            reconcile_ap_fallback_nmcli "$WIFI_DEV"
          fi
          if [[ "$BACKEND" == "netplan" ]]; then
            refresh_status_cache_netplan "$WIFI_DEV"
          fi
          touch "$APPLIED_HASH_FILE"
        fi
      fi
      # netplan has no separate AP watchdog service (nmcli's is
      # wifi-ap-fallback.sh) — re-evaluated every tick here instead.
      if [[ "$BACKEND" == "netplan" ]]; then
        reconcile_ap_netplan "$WIFI_DEV"
      fi
      write_status "$BACKEND" "$WIFI_DEV"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
