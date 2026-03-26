#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local name="${1:?Usage: $TOOL_REL/wip-to-series.sh <name>}"
  wip_to_series_workflow "$name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
