#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

verified=0
failed=0

while IFS= read -r name; do
  line=$(bash "$FORKER_DIR/verify-pins.sh" "$name" 2>&1) || status=$?
  status=${status:-0}
  printf '%s\n' "$line"

  if [ "$status" -eq 0 ]; then
    verified=$((verified + 1))
  else
    failed=$((failed + 1))
  fi

  unset status
done < <(managed_entries)

printf 'summary\tverified=%d\tfailed=%d\n' "$verified" "$failed"

[ "$failed" -eq 0 ]
