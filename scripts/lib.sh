#!/usr/bin/env bash
# Shared helpers — source, don't execute. Installed files under
# scripts/files/ are byte-for-byte final content, no {{TOKEN}} substitution.

# Console helpers for interactive runs; wired below into logging helpers
# that also emit to journald and respect LOG_LEVEL.
log()  { log_info "$*"; }
warn() { log_warn "$*"; }

# Load LOG_LEVEL from the install .env if present, default to WARN.
_load_log_level() {
  local lvl="${LOG_LEVEL:-}"
  if [[ -z "$lvl" && -n "${INSTALL_DIR:-}" && -f "${INSTALL_DIR}/.env" ]]; then
    lvl=$(grep -E '^LOG_LEVEL=' "${INSTALL_DIR}/.env" | tail -n1 | cut -d= -f2- || true)
  fi
  if [[ -z "$lvl" ]]; then lvl="WARN"; fi
  LOG_LEVEL="${lvl^^}"
}

level_to_num() {
  case "${1,,}" in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn|warning) echo 2 ;;
    error|err) echo 3 ;;
    *) echo 2 ;;
  esac
}

_load_log_level

# Emits to stdout (colored) and syslog. Respects LOG_LEVEL, re-loaded
# each call so a later .env change takes effect immediately.
_log_emit() {
  local lvl="$1" shiftmsg
  shift
  shiftmsg="$*"
  # Refresh LOG_LEVEL from disk each invocation in case it changed.
  _load_log_level
  local LOG_LEVEL_NUM
  LOG_LEVEL_NUM=$(level_to_num "$LOG_LEVEL")
  local num
  num=$(level_to_num "$lvl")
  if (( num < LOG_LEVEL_NUM )); then
    return 0
  fi
  local tag="currency-dashboard"
  local colors=("\033[1;34m" "\033[1;36m" "\033[1;33m" "\033[1;31m")
  local idx=$num
  [[ $idx -gt 3 ]] && idx=3
  echo -e "\n${colors[$idx]}==> [$lvl] $shiftmsg\033[0m"
  case "${lvl,,}" in
    debug) logger -t "$tag" -p user.debug "$shiftmsg" ;;
    info)  logger -t "$tag" -p user.info "$shiftmsg" ;;
    warn|warning) logger -t "$tag" -p user.warning "$shiftmsg" ;;
    error|err) logger -t "$tag" -p user.err "$shiftmsg" ;;
    *) logger -t "$tag" -p user.notice "$shiftmsg" ;;
  esac
}

log_debug() { _log_emit debug "$@"; }
log_info()  { _log_emit info "$@"; }
log_warn()  { _log_emit warn "$@"; }
log_error() { _log_emit error "$@"; }

# is_auto — true when the whole chain runs non-interactively (set by
# provision-pi.sh --auto_default, exported through every stage).
is_auto() {
  [[ "${AUTO_DEFAULT:-false}" == "true" ]]
}

# ask <prompt> <default> <varname> — silent default in auto mode, so
# every script shares one prompt code path instead of its own is_auto branch.
ask() {
  local prompt="$1" default="$2" __varname="$3"
  if is_auto; then
    printf -v "$__varname" '%s' "$default"
    return
  fi
  local reply
  read -rp "$prompt" reply || true
  printf -v "$__varname" '%s' "${reply:-$default}"
}

# OS detection, centralized: Pi OS and Armbian share the Debian flow but
# some Pi-only commands (raspi-config etc.) aren't on Armbian.
detect_os_family() {
  if [[ -f /etc/armbian-release ]] || [[ -f /etc/os-release ]] && grep -qiE 'armbian|orangepi|pine64|bananapi|rockchip' /etc/os-release 2>/dev/null; then
    echo "armbian"
  elif [[ -f /etc/os-release ]] && grep -qi 'raspbian' /etc/os-release 2>/dev/null; then
    echo "raspbian"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  else
    echo "unknown"
  fi
}

is_armbian() {
  [[ "$(detect_os_family)" == "armbian" ]]
}

is_raspi_os() {
  [[ "$(detect_os_family)" == "raspbian" ]] || command -v raspi-config >/dev/null 2>&1
}

detect_boot_dir() {
  if [[ -d /boot/firmware ]]; then
    echo "/boot/firmware"
  else
    echo "/boot"
  fi
}

# install_file <source> <dest>
# Copy a repo file verbatim to the destination as root.
install_file() {
  local template="$1" dest="$2"
  if [[ ! -f "$template" ]]; then
    warn "Source file not found: $template — skipping $dest"
    return 1
  fi
  local dest_dir
  dest_dir="$(dirname "$dest")"
  sudo mkdir -p "$dest_dir"
  sudo install -m 644 "$template" "$dest"
}

## install_user_file <source> <dest>
## Install a file into a user's home, ensuring ownership is kiosk:kiosk.
install_user_file() {
  local template="$1" dest="$2"
  if [[ ! -f "$template" ]]; then
    warn "Source file not found: $template — skipping $dest"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  sudo install -o kiosk -g kiosk -m 644 "$template" "$dest"
}

# ensure_block_in_file [--sudo] <file> <marker> <template> — replaces a
# BEGIN/END region wholesale each run, never pattern-matches old content.
ensure_block_in_file() {
  local use_sudo=false
  if [[ "${1:-}" == "--sudo" ]]; then
    use_sudo=true
    shift
  fi
  local file="$1" marker="$2" template="$3"
  local begin="# BEGIN $marker" end="# END $marker"

  local rendered=""
  if [[ -f "$template" ]]; then
    rendered="$(cat "$template")"
  elif [[ "$template" != "--remove--" ]]; then
    warn "Template not found: $template — skipping block '$marker' in $file"
    return 1
  fi

  if "$use_sudo"; then
    sudo mkdir -p "$(dirname "$file")"
    sudo touch "$file"
  else
    mkdir -p "$(dirname "$file")"
    touch "$file"
  fi

  local -a existing=()
  local -a out=()
  local in_block=false line
  while IFS= read -r line || [[ -n "$line" ]]; do
    existing+=("$line")
    if [[ "$line" == "$begin" ]]; then
      in_block=true
      continue
    fi
    if [[ "$line" == "$end" ]]; then
      in_block=false
      continue
    fi
    "$in_block" || out+=("$line")
  done < "$file"

  # Drop a single trailing blank line so re-runs don't accumulate blanks.
  if [[ "${#out[@]}" -gt 0 && -z "${out[-1]}" ]]; then
    unset 'out[-1]'
  fi

  if [[ "$template" != "--remove--" ]]; then
    out+=("" "$begin")
    while IFS= read -r line; do
      out+=("$line")
    done <<<"$rendered"
    out+=("$end")
  fi

  local new_content old_content
  new_content="$(printf '%s\n' "${out[@]}")"
  old_content="$(printf '%s\n' "${existing[@]}")"

  if [[ "$new_content" != "$old_content" ]]; then
    if "$use_sudo"; then
      sudo cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
      printf '%s\n' "${out[@]}" | sudo tee "$file" >/dev/null
    else
      cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
      printf '%s\n' "${out[@]}" > "$file"
    fi
  fi
}

# ensure_tokens_in_cmdline [--sudo] <file> <tokens-file> — cmdline.txt is
# one line, no comment syntax, so appends missing tokens via bash word-splitting, not sed.
ensure_tokens_in_cmdline() {
  local use_sudo=false
  if [[ "${1:-}" == "--sudo" ]]; then
    use_sudo=true
    shift
  fi
  local file="$1" tokens_file="$2"
  [[ -f "$file" ]] || { warn "$file not found — skipping cmdline token check"; return 1; }
  [[ -f "$tokens_file" ]] || { warn "Tokens file not found: $tokens_file"; return 1; }

  local original
  original="$(cat "$file")"
  local line="$original"
  local tok
  for tok in $(cat "$tokens_file"); do
    [[ " $line " == *" $tok "* ]] || line="$line $tok"
  done

  if [[ "$line" != "$original" ]]; then
    if "$use_sudo"; then
      sudo cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
      printf '%s\n' "$line" | sudo tee "$file" >/dev/null
    else
      cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
      printf '%s\n' "$line" > "$file"
    fi
  fi
}

# ensure_key_tokens_in_file [--sudo] <file> <key> <tokens-file> — merges
# tokens into one key's value in a KEY=value file (armbianEnv.txt), leaving other keys untouched.
ensure_key_tokens_in_file() {
  local use_sudo=false
  if [[ "${1:-}" == "--sudo" ]]; then
    use_sudo=true
    shift
  fi
  local file="$1" key="$2" tokens_file="$3"
  [[ -f "$tokens_file" ]] || { warn "Tokens file not found: $tokens_file"; return 1; }

  local -a existing=()
  local line
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      existing+=("$line")
    done < "$file"
  fi

  local -a out=()
  local found=false tok
  for line in "${existing[@]}"; do
    if [[ "$line" == "$key="* ]]; then
      found=true
      local val="${line#"$key="}"
      for tok in $(cat "$tokens_file"); do
        if [[ -z "$val" ]]; then
          val="$tok"
        elif [[ " $val " != *" $tok "* ]]; then
          val="$val $tok"
        fi
      done
      out+=("$key=$val")
    else
      out+=("$line")
    fi
  done
  if ! "$found"; then
    local val=""
    for tok in $(cat "$tokens_file"); do
      if [[ -z "$val" ]]; then val="$tok"; else val="$val $tok"; fi
    done
    out+=("$key=$val")
  fi

  local new_content old_content
  new_content="$(printf '%s\n' "${out[@]}")"
  old_content="$(printf '%s\n' "${existing[@]}")"

  if [[ "$new_content" != "$old_content" ]]; then
    if "$use_sudo"; then
      sudo mkdir -p "$(dirname "$file")"
      [[ -f "$file" ]] && { sudo cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true; }
      printf '%s\n' "${out[@]}" | sudo tee "$file" >/dev/null
    else
      mkdir -p "$(dirname "$file")"
      [[ -f "$file" ]] && { cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true; }
      printf '%s\n' "${out[@]}" > "$file"
    fi
  fi
}

# ensure_key_value_in_file [--sudo] <file> <key> <value> — OVERWRITES one
# key's value entirely (unlike ensure_key_tokens_in_file, which only adds).
ensure_key_value_in_file() {
  local use_sudo=false
  if [[ "${1:-}" == "--sudo" ]]; then
    use_sudo=true
    shift
  fi
  local file="$1" key="$2" value="$3"

  local -a existing=()
  local line
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      existing+=("$line")
    done < "$file"
  fi

  local -a out=()
  local found=false
  for line in "${existing[@]}"; do
    if [[ "$line" == "$key="* ]]; then
      found=true
      out+=("$key=$value")
    else
      out+=("$line")
    fi
  done
  "$found" || out+=("$key=$value")

  local new_content old_content
  new_content="$(printf '%s\n' "${out[@]}")"
  old_content="$(printf '%s\n' "${existing[@]}")"

  if [[ "$new_content" != "$old_content" ]]; then
    if "$use_sudo"; then
      sudo mkdir -p "$(dirname "$file")"
      [[ -f "$file" ]] && { sudo cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true; }
      printf '%s\n' "${out[@]}" | sudo tee "$file" >/dev/null
    else
      mkdir -p "$(dirname "$file")"
      [[ -f "$file" ]] && { cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true; }
      printf '%s\n' "${out[@]}" > "$file"
    fi
  fi
}
