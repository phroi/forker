#!/usr/bin/env bash
set -euo pipefail

# Clean all managed fork clones (status-check each before removing).
# Usage: forks/forker/clean-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

while IFS= read -r name; do
  bash "$FORKER_DIR/clean.sh" "$name" || true
done < <(discover_forks)
