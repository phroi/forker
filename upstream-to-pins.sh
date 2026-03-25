#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local name="${1:?Usage: $TOOL_REL/upstream-to-pins.sh <name> [ref ...]}"
  shift

  upstream_to_pins_workflow "$name" 1 "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
