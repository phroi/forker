#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

main() {
  bash "$FORKER_DIR/sync-all-references.sh"
  bash "$FORKER_DIR/pins-to-missing-wips.sh"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
