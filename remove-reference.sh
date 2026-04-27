#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  local removed=0 failed=0 status
  local name line

  [ "$#" -gt 0 ] || {
    echo "Usage: $TOOL_REL/remove-reference.sh <name> [name ...]" >&2
    return 1
  }

  if [ "$#" -eq 1 ]; then
    remove_reference_workflow "$1"
    return 0
  fi

  for name in "$@"; do
    line=$(remove_reference_workflow "$name" 2>&1) || status=$?
    status=${status:-0}
    printf '%s\n' "$line"

    if [ "$status" -eq 0 ]; then
      removed=$((removed + 1))
    else
      failed=$((failed + 1))
    fi

    unset status
  done

  printf 'summary\tremoved=%d\tfailed=%d\n' "$removed" "$failed"
  [ "$failed" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
