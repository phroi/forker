#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local check_only=0
  if [ "${1:-}" = "--check" ]; then
    check_only=1
    shift
  fi

  local name="${1:?Usage: $TOOL_REL/pins-to-wip.sh [--check] <name>}"
  pins_to_wip_workflow "$name" "$check_only" 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
