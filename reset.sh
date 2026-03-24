#!/usr/bin/env bash
set -euo pipefail

# Remove a fork clone and its pins (full reset).
# Usage: $TOOL_REL/reset.sh <name>

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: $TOOL_REL/reset.sh <name>}"

MODE=$(entry_mode "$NAME")
if [ "$MODE" != "managed" ]; then
  echo "ERROR: $NAME is a reference entry. reset.sh only applies to managed entries." >&2
  exit 1
fi

bash "$FORKER_DIR/clean.sh" "$NAME"
rm -rf "$(pin_dir "$NAME")"
echo "Reset $NAME (clone + pins removed)"
