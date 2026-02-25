#!/usr/bin/env bash
set -euo pipefail

# Check status of all managed fork entries.
# Exits non-zero if any fork has pending work.
# Usage: forks/forker/status-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

EXIT=0
while IFS= read -r name; do
  bash "$FORKER_DIR/status.sh" "$name" || EXIT=1
done < <(discover_forks)
exit $EXIT
