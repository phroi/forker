#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: $TOOL_REL/verify-pins.sh <name>}"

bash "$FORKER_DIR/replay.sh" --check "$NAME"
