#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/update.sh <name>}"

MODE=$(entry_mode "$NAME")
UPSTREAM=$(upstream_url "$NAME")
REAL_REPO="$FORKS_DIR/$NAME"

report() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$1" "${2:--}" "${3:--}" "${4:-}"
}

if [ "$MODE" != "reference" ]; then
  report skipped - - "mode=$MODE use record.sh or replay.sh"
  exit 0
fi

DEFAULT_BRANCH=$(remote_default_branch "$UPSTREAM") || DEFAULT_BRANCH=""
if [ -z "$DEFAULT_BRANCH" ]; then
  report failed - - "cannot resolve remote HEAD"
  exit 1
fi

if [ ! -d "$REAL_REPO/.git" ]; then
  WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
  WORK_REPO="$WORK_DIR/clone"
  trap 'rm -rf "$WORK_DIR"' EXIT

  git clone --depth 1 --branch "$DEFAULT_BRANCH" "$UPSTREAM" "$WORK_REPO"
  NEW_SHA=$(git -C "$WORK_REPO" rev-parse HEAD)

  mv "$WORK_REPO" "$REAL_REPO"
  rm -rf "$WORK_DIR"
  trap - EXIT

  report cloned - "$NEW_SHA" "$DEFAULT_BRANCH"
  exit 0
fi

if ! reference_clone_is_clean "$REAL_REPO"; then
  CURRENT_SHA=$(repo_head "$REAL_REPO" 2>/dev/null || printf -- '-')
  report skipped "$CURRENT_SHA" "$CURRENT_SHA" "dirty clone"
  exit 0
fi

OLD_SHA=$(repo_head "$REAL_REPO")

# Refresh the remote tracking branch explicitly, then reset the local default
# branch to that tip so reference clones stay shallow and predictable.
git -C "$REAL_REPO" fetch --depth=1 origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH"
set_local_origin_head "$REAL_REPO" "$DEFAULT_BRANCH"
git -C "$REAL_REPO" checkout -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
git -C "$REAL_REPO" branch --set-upstream-to="origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH" >/dev/null 2>&1 || true

NEW_SHA=$(repo_head "$REAL_REPO")

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
  report unchanged "$OLD_SHA" "$NEW_SHA" "$DEFAULT_BRANCH"
else
  report updated "$OLD_SHA" "$NEW_SHA" "$DEFAULT_BRANCH"
fi
