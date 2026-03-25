#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
source "$FORKER_DIR/workflow-lib.sh"

main() {
  pins_to_missing_wips_workflow
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
