#!/usr/bin/env bash
set -euo pipefail

TOOL_NAME="phroi_forker"
DEFAULT_FORKER_UPSTREAM="${FORKER_BOOTSTRAP_UPSTREAM:-https://github.com/phroi/forker.git}"
BOOTSTRAP_TEMP_DIR=""
BOOTSTRAP_TOOL_DIR=""
BOOTSTRAP_CONFIG_TMP=""

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup_bootstrap_temp() {
  if [ -n "$BOOTSTRAP_TEMP_DIR" ]; then
    rm -rf "$BOOTSTRAP_TEMP_DIR"
  fi

  if [ -n "$BOOTSTRAP_CONFIG_TMP" ]; then
    rm -f "$BOOTSTRAP_CONFIG_TMP"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || fail "bootstrap.sh must run inside a git repository"
}

ensure_forks_gitignore() {
  local path="$1/.gitignore"
  local line
  local last_byte

  mkdir -p "$1"
  touch "$path"

  last_byte=$(tail -c 1 "$path" 2>/dev/null | od -An -t x1 | tr -d ' \n')
  if [ -n "$last_byte" ] && [ "$last_byte" != "0a" ]; then
    printf '\n' >> "$path"
  fi

  for line in '*/repo/' '.stage/' '.lock/'; do
    grep -Fqx "$line" "$path" || printf '%s\n' "$line" >> "$path"
  done
}

write_minimal_config() {
  cat > "$1" <<EOF
{
  "$TOOL_NAME": {
    "upstream": "$DEFAULT_FORKER_UPSTREAM",
    "mode": "reference"
  }
}
EOF
}

validate_config() {
  jq -e 'type == "object"' "$1" >/dev/null 2>&1 || fail "$1 must be a JSON object"

  jq -e 'to_entries | all(.value | (.mode == "managed" or .mode == "reference"))' "$1" >/dev/null 2>&1 \
    || fail "all forks/config.json entries must declare mode=managed or mode=reference"

  jq -e 'has("forker") | not' "$1" >/dev/null 2>&1 \
    || fail "legacy 'forker' config entries are not supported; migrate to 'phroi_forker' first"
}

ensure_config() {
  local config_path="$1"
  local tmp

  if [ ! -f "$config_path" ]; then
    write_minimal_config "$config_path"
    return 0
  fi

  validate_config "$config_path"

  if jq -e --arg name "$TOOL_NAME" 'has($name)' "$config_path" >/dev/null 2>&1; then
    return 0
  fi

  tmp=$(mktemp "$config_path.tmp.XXXXXX")
  BOOTSTRAP_CONFIG_TMP="$tmp"
  jq --arg name "$TOOL_NAME" --arg upstream "$DEFAULT_FORKER_UPSTREAM" \
    '.[$name] = {"upstream": $upstream, "mode": "reference"}' "$config_path" > "$tmp"
  mv "$tmp" "$config_path"
  BOOTSTRAP_CONFIG_TMP=""
}

tool_upstream() {
  jq -r --arg name "$TOOL_NAME" '.[$name].upstream // empty' "$1"
}

fetch_bootstrap_tool() {
  local forks_dir="$1"
  local config_path="$2"
  local stage_tool="$forks_dir/.stage/bootstrap-$TOOL_NAME"
  local upstream

  upstream=$(tool_upstream "$config_path")
  [ -n "$upstream" ] || upstream="$DEFAULT_FORKER_UPSTREAM"

  BOOTSTRAP_TEMP_DIR="$stage_tool"
  rm -rf "$stage_tool"
  mkdir -p "$stage_tool"
  git clone --filter=blob:none --depth 1 "$upstream" "$stage_tool/repo" >/dev/null \
    || fail "could not clone phroi_forker from $upstream"
  BOOTSTRAP_TOOL_DIR="$stage_tool/repo"
}

main() {
  local root_dir forks_dir config_path

  require_tool git
  require_tool jq
  trap cleanup_bootstrap_temp EXIT

  root_dir=$(repo_root)
  forks_dir="$root_dir/forks"
  config_path="$forks_dir/config.json"

  ensure_forks_gitignore "$forks_dir"
  ensure_config "$config_path"

  fetch_bootstrap_tool "$forks_dir" "$config_path"

  bash "$BOOTSTRAP_TOOL_DIR/materialize-workspace.sh"
  cleanup_bootstrap_temp
  BOOTSTRAP_TEMP_DIR=""
  BOOTSTRAP_TOOL_DIR=""
  BOOTSTRAP_CONFIG_TMP=""
}

if [ "${BASH_SOURCE[0]-$0}" = "$0" ]; then
  main "$@"
fi
