#!/usr/bin/env bash
set -euo pipefail

# Clean all non-tool clones that status.sh says are safe to remove.
# Usage: $TOOL_REL/clean-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

while IFS= read -r name; do
  bash "$FORKER_DIR/clean.sh" "$name" || true
done < <(batch_entries)
