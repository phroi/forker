#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local name="${1:?Usage: $TOOL_REL/managed-to-reference.sh <name>}"
  managed_to_reference_workflow "$name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
