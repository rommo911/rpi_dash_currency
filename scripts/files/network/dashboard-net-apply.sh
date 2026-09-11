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
# Not `set -e`: runs forever in a polling loop, and a single failed
# nmcli/systemctl call must be logged and retried next tick, not kill the
# daemon — same reasoning as wifi-ap-fallback-watchdog.sh.
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

CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

log() { logger -t dashboard-net-apply "$1"; echo "$1"; }

# reconcile_reboot — checked every tick, first, independent of nmcli even
# being installed: a reboot request has nothing to do with networking.
reconcile_reboot() {
  if [[ -f "$REBOOT_FLAG" ]]; then
    rm -f "$REBOOT_FLAG"
    log "Reboot requested via admin panel — rebooting now."
    systemctl reboot
  fi
}

# Emits NUL-separated "ssid\0password\0" pairs for up to 3 configured Wi-Fi
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
for slot in (cfg.get("wifi") or [])[:3]:
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

# reconcile_wifi — idempotent delete-then-recreate per slot (same shape as
# provision-pi.sh's connect_wifi()/connect_wifi_auto()), ranked by list
# order via connection.autoconnect-priority so NetworkManager prefers slot
# 1 and falls back to 2/3 as they come into range. Any profile this daemon
# previously applied but that's no longer in the current config is deleted
# — tracked in a tmpfs file so a reboot (which wipes tmpfs) always starts
# from "nothing applied yet" and simply re-applies the current config
# fresh on its first tick.
reconcile_wifi() {
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

# reconcile_ap_fallback — never reimplements wifi-ap-fallback.sh's nmcli
# logic; either invokes it as-is (dropping from root to RUN_USER, since
# that script refuses to run as root itself and does its own internal
# sudo for the parts that need it — no password needed, the caller here
# already has full privilege) or disables the service it installs.
reconcile_ap_fallback() {
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

write_status() {
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

  cat > "$STATUS_FILE.tmp" <<EOF
{
  "connected": $( [[ "$state" == "100" ]] && echo true || echo false ),
  "ssid": $(json_string "$conn"),
  "ip": $(json_string "$ip"),
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

  if command -v nmcli >/dev/null 2>&1; then
    WIFI_DEV="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    if [[ -n "$WIFI_DEV" ]]; then
      if [[ -f "$NET_CONFIG_FILE" ]]; then
        new_hash="$(sha256sum "$NET_CONFIG_FILE" 2>/dev/null | awk '{print $1}')"
        old_hash=""
        [[ -f "$APPLIED_HASH_FILE" ]] && old_hash="$(cat "$APPLIED_HASH_FILE")"
        if [[ -n "$new_hash" && "$new_hash" != "$old_hash" ]]; then
          log "net_config.json changed — reconciling"
          reconcile_wifi "$WIFI_DEV"
          reconcile_ap_fallback "$WIFI_DEV"
          echo "$new_hash" > "$APPLIED_HASH_FILE"
        fi
      fi
      write_status "$WIFI_DEV"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
