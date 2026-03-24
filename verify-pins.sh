#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/verify-pins.sh <name>}"

bash "$FORKER_DIR/replay.sh" --check "$NAME"
