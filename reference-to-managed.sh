#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local name="${1:?Usage: $TOOL_REL/reference-to-managed.sh <name>}"
  reference_to_managed_workflow "$name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
