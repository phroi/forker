#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/status.sh <name>}"

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")
MODE=$(entry_mode "$NAME")

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "$NAME: clone is not present"
  exit 0
fi

if [ "$MODE" = "managed" ]; then
  if PINNED=$(pinned_head "$PIN_DIR" 2>/dev/null); then
    if has_legacy_local_patches "$PIN_DIR"; then
      echo "$NAME: pins use an unsupported legacy local patch layout"
      exit 1
    fi

    LOCAL_BASE=$(local_base "$PIN_DIR" 2>/dev/null) || {
      echo "$NAME: pins are missing LOCAL_BASE"
      exit 1
    }

    ACTUAL=$(repo_head "$REPO_DIR")

    # Managed cleanliness means three things at once: no worktree changes, a
    # linear LOCAL_BASE..HEAD range, and a saved commit series that still
    # matches the pin contents.
    if repo_has_worktree_changes "$REPO_DIR"; then
      echo "$NAME: clone has changes relative to pins:"
      show_repo_worktree_changes "$REPO_DIR"
      exit 1
    fi

    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$LOCAL_BASE" "$ACTUAL" >/dev/null 2>&1; then
      echo "$NAME: HEAD is not based on pinned LOCAL_BASE:"
      echo "  local_base  $LOCAL_BASE"
      echo "  actual      $ACTUAL"
      exit 1
    fi

    if commit_range_has_merges "$REPO_DIR" "$LOCAL_BASE" "$ACTUAL"; then
      echo "$NAME: local series contains merge commits after LOCAL_BASE"
      exit 1
    fi

    if saved_series_matches_ref "$REPO_DIR" "$PIN_DIR" "$ACTUAL"; then
      if [ "$ACTUAL" = "$PINNED" ]; then
        echo "$NAME: clone is clean (matches pins)"
      else
        echo "$NAME: clone is clean (saved series matches pins)"
      fi
      exit 0
    fi

    echo "$NAME: commit series diverged from pins:"
    echo "  local_base  $LOCAL_BASE"
    echo "  pinned      $PINNED"
    echo "  actual      $ACTUAL"
    git -C "$REPO_DIR" log --oneline "$LOCAL_BASE..$ACTUAL" 2>/dev/null || true
    exit 1
  fi
fi

BASELINE_REF=$(reference_baseline_ref "$REPO_DIR" 2>/dev/null) || {
  echo "$NAME: clone has no remote baseline"
  exit 1
}

BASELINE_SHA=$(local_origin_head_sha "$REPO_DIR")
ACTUAL=$(repo_head "$REPO_DIR")

if [ "$ACTUAL" != "$BASELINE_SHA" ]; then
  echo "$NAME: HEAD diverged from $BASELINE_REF:"
  echo "  baseline  $BASELINE_SHA"
  echo "  actual    $ACTUAL"
  git -C "$REPO_DIR" log --oneline "$BASELINE_SHA..$ACTUAL" 2>/dev/null || true
  exit 1
fi

if repo_has_worktree_changes "$REPO_DIR"; then
  echo "$NAME: clone has changes relative to $BASELINE_REF:"
  show_repo_worktree_changes "$REPO_DIR" "$BASELINE_REF"
  exit 1
fi

if [ "$MODE" = "managed" ]; then
  echo "$NAME: clone is clean (managed entry without pins yet)"
else
  echo "$NAME: clone is clean (matches $BASELINE_REF)"
fi
