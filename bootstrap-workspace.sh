#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

main() {
  # Rebuild the tool first so the rest use pinned forker state.
  bash "$FORKER_DIR/rebuild-wip.sh" phroi_forker
  bash "$FORKER_DIR/sync-all-references.sh"
  bash "$FORKER_DIR/pins-to-missing-wips.sh"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
