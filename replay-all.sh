#!/usr/bin/env bash
set -euo pipefail

# Replay all managed fork entries from their pins.
# Usage: forks/forker/replay-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

while IFS= read -r name; do
  bash "$FORKER_DIR/replay.sh" "$name"
done < <(discover_forks)
