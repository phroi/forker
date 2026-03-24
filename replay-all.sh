#!/usr/bin/env bash
set -euo pipefail

# Replay all managed entries from their pins.
# Usage: forks/forker/replay-all.sh

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

replayed=0
skipped=0
failed=0

while IFS= read -r name; do
  if [ -d "$(repo_dir "$name")/.git" ]; then
    # Keep existing safe clones in place, but surface dirty ones instead of
    # deleting them behind the caller's back.
    if bash "$FORKER_DIR/status.sh" "$name" >/dev/null 2>&1; then
      printf '%s\tskipped\tclone already present\n' "$name"
      skipped=$((skipped + 1))
    else
      printf '%s\tfailed\texisting clone is not safe to replace\n' "$name"
      failed=$((failed + 1))
    fi
    continue
  fi

  line=$(bash "$FORKER_DIR/replay.sh" "$name" 2>&1) || status=$?
  status=${status:-0}
  printf '%s\n' "$line"

  if [ "$status" -eq 0 ]; then
    replayed=$((replayed + 1))
  else
    failed=$((failed + 1))
  fi

  unset status
done < <(managed_entries)

printf 'summary\treplayed=%d\tskipped=%d\tfailed=%d\n' "$replayed" "$skipped" "$failed"

[ "$failed" -eq 0 ]
