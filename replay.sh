#!/usr/bin/env bash
set -euo pipefail

# Usage: forks/forker/replay.sh <name>
#   Deterministic replay from manifest + counted resolutions + local patches.
#   For entries with no pins and empty refs, does a shallow clone instead.

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/replay.sh <name>}"

REAL_REPO="$FORKS_DIR/$NAME"
PIN_DIR=$(pin_dir "$NAME")   # pins are read-only input, no override needed
UPSTREAM=$(upstream_url "$NAME")

# Skip if already cloned
if [ -d "$REAL_REPO" ]; then
  echo "$NAME: clone already exists, skipping (remove it to redo setup)" >&2
  exit 0
fi

# If no pins exist, check if this is a reference-only entry (no refs)
MANIFEST=$(manifest_file "$PIN_DIR" 2>/dev/null) || {
  # No manifest — check for empty refs (reference-only clone)
  mapfile -t REFS < <(repo_refs "$NAME" 2>/dev/null || true)
  if [ ${#REFS[@]} -eq 0 ]; then
    echo "$NAME: no pins, shallow-cloning as reference..." >&2
    WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
    WORK_REPO="$WORK_DIR/clone"
    trap 'rm -rf "$WORK_DIR"; echo "FAILED — previous state is intact" >&2' EXIT
    git clone --depth 1 "$UPSTREAM" "$WORK_REPO"
    mv "$WORK_REPO" "$REAL_REPO"
    rm -rf "$WORK_DIR"
    trap - EXIT
    echo "$NAME: reference clone ready"
    exit 0
  fi
  echo "$NAME: no pins to replay, skipping" >&2
  exit 0
}

# Build clone in staging area (same filesystem → atomic mv)
WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
WORK_REPO="$WORK_DIR/clone"
export _FORKER_WORK_REPO="$WORK_REPO"
REPO_DIR="$WORK_REPO"

trap 'rm -rf "$WORK_DIR"; echo "FAILED — previous state is intact" >&2' EXIT

# Read base SHA from first line of manifest
BASE_SHA=$(head -1 "$MANIFEST" | cut -d$'\t' -f1)
git clone --filter=blob:none "$UPSTREAM" "$REPO_DIR"

# Match record.sh's conflict marker style and SHA abbreviation for identical markers
git -C "$REPO_DIR" config merge.conflictStyle diff3
git -C "$REPO_DIR" config core.abbrev 40

git -C "$REPO_DIR" checkout "$BASE_SHA"
git -C "$REPO_DIR" checkout -b wip

# Replay merges from manifest (skip line 1 = base)
MERGE_IDX=0
while IFS=$'\t' read -r SHA REF_NAME; do
  MERGE_IDX=$((MERGE_IDX + 1))
  echo "Replaying merge $MERGE_IDX: $REF_NAME ($SHA)" >&2

  deterministic_env "$MERGE_IDX"

  git -C "$REPO_DIR" fetch origin "$SHA"

  # Use explicit merge message matching record.sh for deterministic commits
  MERGE_MSG="Merge $REF_NAME into wip"

  # Merge by SHA (matching record.sh) so conflict markers are identical
  if ! git -C "$REPO_DIR" merge --no-ff -m "$MERGE_MSG" "$SHA"; then
    RES_FILE="$PIN_DIR/res-${MERGE_IDX}.resolution"
    if [ ! -f "$RES_FILE" ]; then
      if [ -f "$PIN_DIR/res-${MERGE_IDX}.diff" ]; then
        echo "ERROR: Legacy diff format detected (res-${MERGE_IDX}.diff)." >&2
        echo "Re-record with:  bash forks/forker/record.sh $NAME" >&2
        exit 1
      fi
      echo "ERROR: Merge $MERGE_IDX ($REF_NAME) has conflicts but no resolution file." >&2
      echo "Re-record with:  bash forks/forker/record.sh $NAME" >&2
      exit 1
    fi

    # Apply counted resolutions (positional — no sed stripping or patch needed)
    apply_resolution_file "$REPO_DIR" "$RES_FILE"

    # Stage resolved files and complete the merge
    git -C "$REPO_DIR" add -A
    echo "$MERGE_MSG" > "$REPO_DIR/.git/MERGE_MSG"
    GIT_EDITOR=true git -C "$REPO_DIR" merge --continue
  fi
done < <(tail -n +2 "$MANIFEST")

bash "$FORKER_DIR/patch.sh" "$NAME" "$(merge_count "$PIN_DIR")"

apply_local_patches "$REPO_DIR" "$PIN_DIR" || {
  echo "Re-record with:  bash forks/forker/record.sh $NAME" >&2
  exit 1
}

# Verify HEAD SHA matches .pin/<name>/HEAD
ACTUAL=$(git -C "$REPO_DIR" rev-parse HEAD)
EXPECTED=$(pinned_head "$PIN_DIR")
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: replay HEAD ($ACTUAL) != pinned HEAD ($EXPECTED)" >&2
  echo "Pins are stale or corrupted. Re-record with 'bash forks/forker/record.sh $NAME'." >&2
  exit 1
fi

# Add fork remote for pushing (SSH for auth), if configured
FORK_REMOTE=$(fork_url "$NAME" 2>/dev/null) || true
if [ -n "${FORK_REMOTE:-}" ]; then
  git -C "$REPO_DIR" remote add fork "$FORK_REMOTE"
fi

# --- Atomic swap: move staging clone to final location ---
unset _FORKER_WORK_REPO
trap - EXIT
mv "$WORK_REPO" "$REAL_REPO"
rm -rf "$WORK_DIR"

echo "OK — replay HEAD matches pinned HEAD ($EXPECTED)"
