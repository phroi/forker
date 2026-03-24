#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

errors=0
warns=0
oks=0

report() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

ok() {
  oks=$((oks + 1))
  report OK "$1" "$2" "${3:-}"
}

warn() {
  warns=$((warns + 1))
  report WARN "$1" "$2" "${3:-}"
}

error() {
  errors=$((errors + 1))
  report ERROR "$1" "$2" "${3:-}"
}

for tool in git jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok tool "$tool" available
  else
    error tool "$tool" missing
  fi
done

if command -v pnpm >/dev/null 2>&1; then
  ok tool pnpm available
else
  ok tool pnpm optional-for-conflicts-only
fi

if jq -e type "$FORKS_DIR/config.json" >/dev/null 2>&1; then
  ok config config-json readable
else
  error config config-json invalid
fi

while IFS= read -r name; do
  mode=$(entry_mode "$name" 2>/dev/null || printf -- '')
  pin_path="$FORKS_DIR/.pin/$name"
  repo_path="$FORKS_DIR/$name"
  has_manifest=0
  has_head=0
  has_local_base=0
  saved_series=0

  [ -f "$pin_path/manifest" ] && has_manifest=1
  [ -f "$pin_path/HEAD" ] && has_head=1
  [ -f "$pin_path/LOCAL_BASE" ] && has_local_base=1
  saved_series=$(saved_series_count "$pin_path")

  case "$mode" in
    managed|reference)
      ok entry "$name mode=$mode"
      ;;
    *)
      error entry "$name invalid-mode=$mode"
      continue
      ;;
  esac

  has_legacy_local_patches "$pin_path" && {
    error pin "$name unsupported-legacy-pin-layout"
    continue
  }

  if [ "$mode" = "reference" ]; then
    if [ "$has_manifest" -eq 1 ] || [ "$has_head" -eq 1 ] || [ "$has_local_base" -eq 1 ] || [ "$(saved_series_count "$pin_path")" -gt 0 ]; then
      error pin "$name reference-entry-has-pins"
    else
      ok pin "$name no-pins"
    fi
  else
    # Managed pins travel as a set: manifest defines the merge base, LOCAL_BASE
    # marks the post-merge replay tip, and HEAD marks the final tip after the
    # saved series. Missing one usually means the pin set is half-written.
    if [ "$saved_series" -gt 0 ] && [ "$has_manifest" -eq 0 ] && [ "$has_head" -eq 0 ] && [ "$has_local_base" -eq 0 ]; then
      error pin "$name series-without-base-metadata"
    elif [ "$has_manifest" -ne "$has_head" ] || [ "$has_manifest" -ne "$has_local_base" ]; then
      error pin "$name manifest-head-local-base-mismatch"
    elif [ "$has_manifest" -eq 1 ]; then
      ok pin "$name pinned"
    else
      warn pin "$name managed-without-pins"
    fi
  fi

  if [ -d "$repo_path/.git" ]; then
    if [ "$mode" = "managed" ] && [ "$has_local_base" -eq 1 ] && commit_range_has_merges "$repo_path" "$(local_base "$pin_path")" HEAD >/dev/null 2>&1; then
      warn clone "$name non-linear-local-series"
    elif bash "$FORKER_DIR/status.sh" "$name" >/dev/null 2>&1; then
      ok clone "$name safe"
    else
      warn clone "$name dirty-or-diverged"
    fi
  else
    warn clone "$name missing"
  fi
done < <(all_entries)

printf 'summary\tok=%d\twarn=%d\terror=%d\n' "$oks" "$warns" "$errors"

[ "$errors" -eq 0 ]
