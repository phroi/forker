#!/usr/bin/env bash
set -euo pipefail

# Remove a fork clone and its pins (full reset).
# Usage: forks/forker/reset.sh <name>

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/reset.sh <name>}"

bash "$FORKER_DIR/clean.sh" "$NAME"
rm -rf "$(pin_dir "$NAME")"
