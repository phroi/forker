#!/usr/bin/env bash
set -euo pipefail

# Remove a fork clone after verifying it has no pending work.
# Usage: $TOOL_REL/clean.sh <name>

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: $TOOL_REL/clean.sh <name>}"

bash "$FORKER_DIR/status.sh" "$NAME"
rm -rf "$(repo_dir "$NAME")"
echo "Cleaned $NAME"
