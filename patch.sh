#!/usr/bin/env bash
set -euo pipefail

# Patch a cloned repo for use in the stack workspace.
# Usage: forks/forker/patch.sh <name> <merge-count>

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/patch.sh <name> <merge-count>}"
MERGE_COUNT="${2:?Missing merge-count argument}"
REPO_DIR=$(repo_dir "$NAME")

# Remove the repo's own lockfile so deps are recorded in the root pnpm-lock.yaml
rm -f "$REPO_DIR/pnpm-lock.yaml"

# Patch packages so the stack resolves directly to .ts source:
# - "type":"module" → NodeNext treats .ts files as ESM
# - "types" export condition → TypeScript resolves .ts source before .js dist
# - "import" rewritten to .ts source → Vite/esbuild can bundle without building
mapfile -t _includes < <(config_val "$NAME" '.workspace.include // [] | .[]')
for _pattern in "${_includes[@]}"; do
  [ -n "$_pattern" ] || continue
  for pkg_json in "$REPO_DIR"/$_pattern/package.json; do
    [ -f "$pkg_json" ] || continue
    jq '.type = "module" |
      if (.exports | type) == "object" then .exports |= with_entries(
        if .value | type == "object" and has("import")
        then .value |= (
          (.import | sub("/dist/";"/src/") | sub("\\.m?js$";".ts")) as $src |
          {types: $src, import: $src} + (. | del(.import, .types))
        )
        else . end
      ) else . end' "$pkg_json" > "$pkg_json.tmp" && mv "$pkg_json.tmp" "$pkg_json"
  done
done

# Commit patched files with deterministic identity so record and replay produce the same hash
deterministic_env "$((MERGE_COUNT + 1))"
git -C "$REPO_DIR" add -A
if ! git -C "$REPO_DIR" diff --cached --quiet; then
  git -C "$REPO_DIR" commit -m "patch: source-level type resolution"
fi
