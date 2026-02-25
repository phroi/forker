#!/usr/bin/env bash
set -euo pipefail

# Check whether a fork clone is safe to wipe.
#   Exit 0 → safe (not cloned, or matches pins exactly)
#   Exit 1 → has custom work (any changes vs pinned commit, diverged HEAD, or no pins to compare)
# Usage: forks/forker/status.sh <name>

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/status.sh <name>}"

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")

if [ ! -d "$REPO_DIR" ]; then
  echo "$NAME: clone is not present"
  exit 0
fi

PINNED=$(pinned_head "$PIN_DIR" 2>/dev/null) || {
  # No HEAD pin — distinguish reference-only vs bootstrapped entries.
  # Reference-only (empty refs, no local patches) are always safe to wipe.
  # Bootstrapped entries (empty refs but HAS local patches, e.g. forker) are not.
  mapfile -t _refs < <(repo_refs "$NAME" 2>/dev/null || true)
  if [ ${#_refs[@]} -eq 0 ] && [ "$(count_glob "$PIN_DIR"/local-*.patch)" -eq 0 ]; then
    echo "$NAME: reference clone (safe to wipe)"
    exit 0
  fi
  echo "$NAME: clone exists but no pins — custom clone"
  exit 1
}

ACTUAL=$(git -C "$REPO_DIR" rev-parse HEAD)

if [ "$ACTUAL" != "$PINNED" ]; then
  echo "$NAME: HEAD diverged from pinned HEAD:"
  echo "  pinned  $PINNED"
  echo "  actual  $ACTUAL"
  git -C "$REPO_DIR" log --oneline "$PINNED..$ACTUAL" 2>/dev/null || true
  exit 1
fi

# Compare pinned commit against working tree AND index.
# git diff <commit> catches unstaged changes; --cached catches staged-only changes
# (e.g. staged edits where the working tree was reverted).
if ! git -C "$REPO_DIR" diff "$PINNED" --quiet 2>/dev/null \
   || ! git -C "$REPO_DIR" diff --cached "$PINNED" --quiet 2>/dev/null \
   || [ -n "$(git -C "$REPO_DIR" ls-files --others --exclude-standard 2>/dev/null)" ]; then
  echo "$NAME: clone has changes relative to pins:"
  git -C "$REPO_DIR" diff "$PINNED" --stat 2>/dev/null || true
  git -C "$REPO_DIR" diff --cached "$PINNED" --stat 2>/dev/null || true
  git -C "$REPO_DIR" ls-files --others --exclude-standard 2>/dev/null || true
  exit 1
fi

# Check for stashed changes that would be lost on wipe
if [ -n "$(git -C "$REPO_DIR" stash list 2>/dev/null)" ]; then
  echo "$NAME: clone has stashed changes:"
  git -C "$REPO_DIR" stash list 2>/dev/null || true
  exit 1
fi

echo "$NAME: clone is clean (matches pins)"
