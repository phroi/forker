#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

updated=0
cloned=0
unchanged=0
skipped=0
failed=0

while IFS= read -r name; do
  line=$(bash "$FORKER_DIR/update.sh" "$name" 2>&1) || true
  printf '%s\n' "$line"

  # update.sh can emit git progress before the final tab-delimited report, so
  # summary accounting should only parse the last line.
  report=$(printf '%s\n' "$line" | sed -n '$p')
  IFS=$'\t' read -r _ status _ _ _ <<< "$report"
  case "$status" in
    updated) updated=$((updated + 1)) ;;
    cloned) cloned=$((cloned + 1)) ;;
    unchanged) unchanged=$((unchanged + 1)) ;;
    skipped) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)) ;;
  esac
done < <(all_entries)

printf 'summary\tupdated=%d\tcloned=%d\tunchanged=%d\tskipped=%d\tfailed=%d\n' \
  "$updated" "$cloned" "$unchanged" "$skipped" "$failed"

[ "$failed" -eq 0 ]
