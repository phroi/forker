#!/usr/bin/env bash
set -euo pipefail

# Check status of all configured entries.
# Exits non-zero if any entry has pending work.
# Usage: $TOOL_REL/status-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

EXIT=0
while IFS= read -r name; do
  bash "$FORKER_DIR/status.sh" "$name" || EXIT=1
done < <(all_entries)
exit $EXIT
