#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local removed=0 failed=0
  local name

  [ "$#" -gt 0 ] || {
    echo "Usage: $TOOL_REL/remove-reference.sh <name> [name ...]" >&2
    return 1
  }

  if [ "$#" -eq 1 ]; then
    remove_reference_workflow "$1"
    return $?
  fi

  for name in "$@"; do
    if remove_reference_workflow "$name"; then
      removed=$((removed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  printf 'summary\tremoved=%d\tfailed=%d\n' "$removed" "$failed"
  [ "$failed" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
