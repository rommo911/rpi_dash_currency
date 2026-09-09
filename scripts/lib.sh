#!/usr/bin/env bash
# Shared helpers for the provisioning/deploy scripts. Source this, don't
# execute it:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
#
# The point of this file: every installed config file (systemd units,
# fail2ban jails, sudoers rules, kiosk autostart, boot config, ...) lives
# as a real file under scripts/files/, not as heredoc text buried inside a
# script. render_template(_user)/ensure_block_in_file/ensure_tokens_in_cmdline
# are the ONLY mechanisms any script uses to get that content onto disk —
# render_template(_user) for files we fully own (just render and
# overwrite), the other two for files we only add a managed section/token
# set to (OS/user files that also hold unrelated content we must not
# touch). None of them use sed: everything here is plain bash string
# substitution and line-array rebuilding. If you need a new installed
# file, add it under scripts/files/ and call one of these — don't reach
# for `sudo tee ... <<EOF` or `sed -i` on an installed file anywhere else
# in this repo.

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }

# is_auto — true when the whole provisioning chain should run
# non-interactively with defaults (set by provision-pi.sh --auto_default
# and exported through every stage it hands off to).
is_auto() {
  [[ "${AUTO_DEFAULT:-false}" == "true" ]]
}

# ask <prompt> <default> <varname>
# Interactive prompt that becomes a silent default in auto mode, so every
# script's prompts can share one code path instead of each maintaining
# its own "if is_auto then skip" branch inline.
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

# render_template <template-file> <dest-path> [KEY=VALUE ...]
# Replaces every {{KEY}} token in the template with its VALUE (plain bash
# substring replacement — no sed, no external tools) and installs the
# result at dest-path via sudo. A template with no KEY=VALUE args is
# installed byte-for-byte (still goes through the same function, so there
# is exactly one code path for "put this repo file onto the system").
# Always overwrites: identical input always produces identical output, so
# there's nothing to check-before-writing.
render_template() {
  local template="$1" dest="$2"
  shift 2
  if [[ ! -f "$template" ]]; then
    warn "Template not found: $template — skipping $dest"
    return 1
  fi
  local content
  content="$(cat "$template")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    content="${content//\{\{$key\}\}/$val}"
  done
  local dest_dir
  dest_dir="$(dirname "$dest")"
  sudo mkdir -p "$dest_dir"
  printf '%s\n' "$content" | sudo tee "$dest" >/dev/null
}

# render_template_user — same as render_template but for a file owned by
# the invoking (non-root) user, e.g. ~/.xinitrc — no sudo needed/wanted.
render_template_user() {
  local template="$1" dest="$2"
  shift 2
  if [[ ! -f "$template" ]]; then
    warn "Template not found: $template — skipping $dest"
    return 1
  fi
  local content
  content="$(cat "$template")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    content="${content//\{\{$key\}\}/$val}"
  done
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
}

# ensure_block_in_file [--sudo] <file> <marker> <template> [KEY=VALUE ...]
# Manages a single delimited region inside a file we don't fully own:
#   # BEGIN <marker>
#   ...rendered template content...
#   # END <marker>
# Any existing region with that marker is removed first (wherever it is
# in the file), then the freshly rendered one is appended — so re-running
# always converges on exactly the current template content, never leaves
# a stale duplicate, and never has to pattern-match the PREVIOUS content
# to know what to replace (that pattern-matching is exactly what caused
# the startx self-heal bug this replaces — see CLAUDE.md). Backs the file
# up (once, timestamped) only if it's actually about to change. Creates
# the file (and its parent dir) if it doesn't exist yet.
# Pass --sudo for a root-owned file (e.g. /boot/firmware/config.txt) —
# reads still happen as the invoking user (these files are world-readable),
# only the backup and the final write go through sudo.
ensure_block_in_file() {
  local use_sudo=false
  if [[ "${1:-}" == "--sudo" ]]; then
    use_sudo=true
    shift
  fi
  local file="$1" marker="$2" template="$3"
  shift 3
  local begin="# BEGIN $marker" end="# END $marker"

  local rendered=""
  if [[ -f "$template" ]]; then
    rendered="$(cat "$template")"
    local kv key val
    for kv in "$@"; do
      key="${kv%%=*}"
      val="${kv#*=}"
      rendered="${rendered//\{\{$key\}\}/$val}"
    done
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

# ensure_tokens_in_cmdline [--sudo] <file> <tokens-file>
# cmdline.txt is a single line with no comment syntax at all — the
# bootloader doesn't understand extra lines in it, so ensure_block_in_file
# (which inserts # BEGIN/# END comment lines) would corrupt it. This
# instead reads the tokens to guarantee-present from a plain
# space/newline-separated repo file, appends whichever aren't already on
# the line, and rewrites it as a single line — still no sed, pure bash
# word-splitting. Backs the file up (once, timestamped) only if it
# actually changes.
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
