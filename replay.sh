#!/usr/bin/env bash
set -euo pipefail

# Deterministically rebuild a managed clone from its pins, or dry-run the same
# process with --check to verify that replay would still succeed.

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

NAME="${1:?Usage: $TOOL_REL/replay.sh [--check] <name>}"

MODE=$(entry_mode "$NAME")
REAL_REPO="$FORKS_DIR/$NAME"
PIN_DIR=$(pin_dir "$NAME")
UPSTREAM=$(upstream_url "$NAME")

if [ "$MODE" != "managed" ]; then
  echo "ERROR: $NAME is a reference entry. Use 'bash $TOOL_REL/update.sh $NAME'." >&2
  exit 1
fi

if [ "$CHECK_ONLY" -eq 0 ] && [ -d "$REAL_REPO" ]; then
  echo "ERROR: $NAME clone already exists. Use 'bash $TOOL_REL/clean.sh $NAME' before replaying." >&2
  exit 1
fi

MANIFEST=$(manifest_file "$PIN_DIR" 2>/dev/null) || {
  echo "ERROR: $NAME has no pins to replay. Run 'bash $TOOL_REL/record.sh $NAME' first." >&2
  exit 1
}

if has_legacy_local_patches "$PIN_DIR"; then
  echo "ERROR: $NAME still uses an unsupported legacy local patch layout. Delete and regenerate its pins first." >&2
  exit 1
fi

EXPECTED_LOCAL_BASE=$(local_base "$PIN_DIR") || {
  echo "ERROR: $NAME pins are missing LOCAL_BASE." >&2
  exit 1
}

WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
WORK_REPO="$WORK_DIR/clone"
export _FORKER_WORK_REPO="$WORK_REPO"
REPO_DIR="$WORK_REPO"

# Build in staging first so a failed replay leaves the live clone untouched.
trap 'rm -rf "$WORK_DIR"; echo "FAILED: previous state is intact" >&2' EXIT

BASE_SHA=$(head -1 "$MANIFEST" | cut -d$'\t' -f1)
git clone --filter=blob:none "$UPSTREAM" "$REPO_DIR"

# Match record.sh so replayed merges regenerate the same diff3 markers and
# abbreviated SHAs inside conflict hunks.
git -C "$REPO_DIR" config merge.conflictStyle diff3
git -C "$REPO_DIR" config core.abbrev 40

git -C "$REPO_DIR" checkout "$BASE_SHA"
git -C "$REPO_DIR" checkout -b wip

# Manifest line 1 is the pinned base commit. Every later line replays one merge
# that record.sh resolved and wrote into the pin set.
MERGE_IDX=0
while IFS=$'\t' read -r SHA REF_NAME; do
  MERGE_IDX=$((MERGE_IDX + 1))
  echo "Replaying merge $MERGE_IDX: $REF_NAME ($SHA)" >&2

  deterministic_env "$MERGE_IDX"
  # Fetch the named ref for reachability, but merge the recorded SHA so replay
  # stays pinned to the commit captured in manifest instead of the current ref tip.
  if [[ $REF_NAME =~ ^[0-9]+$ ]]; then
    git -C "$REPO_DIR" fetch origin "pull/$REF_NAME/head:pr-$REF_NAME"
  elif [[ $REF_NAME =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$REPO_DIR" fetch origin "$SHA"
  else
    git -C "$REPO_DIR" fetch origin "refs/heads/$REF_NAME:$REF_NAME"
  fi

  if ! git -C "$REPO_DIR" cat-file -e "$SHA^{commit}" 2>/dev/null; then
    # Some remotes allow fetching a reachable SHA directly even if the ref has
    # moved since recording. If that fails too, the only safe recovery is re-record.
    if [[ ! $REF_NAME =~ ^[0-9a-f]{7,40}$ ]]; then
      git -C "$REPO_DIR" fetch origin "$SHA" >/dev/null 2>&1 || true
    fi
  fi

  if ! git -C "$REPO_DIR" cat-file -e "$SHA^{commit}" 2>/dev/null; then
    echo "ERROR: Recorded commit $SHA for ref $REF_NAME is no longer available from upstream." >&2
    echo "Re-record with:  bash $TOOL_REL/record.sh $NAME" >&2
    exit 1
  fi

  MERGE_MSG="Merge $REF_NAME into wip"
  if ! git -C "$REPO_DIR" merge --no-ff -m "$MERGE_MSG" "$SHA"; then
    RES_FILE="$PIN_DIR/res-${MERGE_IDX}.resolution"
    if [ ! -f "$RES_FILE" ]; then
      echo "ERROR: Merge $MERGE_IDX ($REF_NAME) has conflicts but no resolution file." >&2
      echo "Re-record with:  bash $TOOL_REL/record.sh $NAME" >&2
      exit 1
    fi

    # Reconstruct the recorded resolution positionally from the sidecar instead
    # of applying a fuzzy patch against current file context.
    apply_resolution_file "$REPO_DIR" "$RES_FILE"

    git -C "$REPO_DIR" add -A
    echo "$MERGE_MSG" > "$REPO_DIR/.git/MERGE_MSG"
    GIT_EDITOR=true git -C "$REPO_DIR" merge --continue
  fi
done < <(tail -n +2 "$MANIFEST")

ACTUAL_LOCAL_BASE=$(git -C "$REPO_DIR" rev-parse HEAD)
if [ "$ACTUAL_LOCAL_BASE" != "$EXPECTED_LOCAL_BASE" ]; then
  echo "FAIL: replay local base ($ACTUAL_LOCAL_BASE) != pinned LOCAL_BASE ($EXPECTED_LOCAL_BASE)" >&2
  echo "Pins are stale or corrupted. Re-record with 'bash $TOOL_REL/record.sh $NAME'." >&2
  exit 1
fi

apply_saved_series "$REPO_DIR" "$PIN_DIR" || {
  echo "Re-record with:  bash $TOOL_REL/record.sh $NAME" >&2
  exit 1
}

ACTUAL=$(git -C "$REPO_DIR" rev-parse HEAD)
EXPECTED=$(pinned_head "$PIN_DIR")
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: replay HEAD ($ACTUAL) != pinned HEAD ($EXPECTED)" >&2
  echo "Pins are stale or corrupted. Re-record with 'bash $TOOL_REL/record.sh $NAME'." >&2
  exit 1
fi

FORK_REMOTE=$(fork_url "$NAME" 2>/dev/null) || true
if [ -n "${FORK_REMOTE:-}" ]; then
  git -C "$REPO_DIR" remote add fork "$FORK_REMOTE"
fi

unset _FORKER_WORK_REPO
trap - EXIT
if [ "$CHECK_ONLY" -eq 1 ]; then
  rm -rf "$WORK_DIR"
  echo "OK: replay HEAD matches pinned HEAD ($EXPECTED)"
  exit 0
fi

# Atomic swap: only replace the live clone after the full replay and HEAD check
# succeed in staging.
mv "$WORK_REPO" "$REAL_REPO"
rm -rf "$WORK_DIR"

echo "OK: replay HEAD matches pinned HEAD ($EXPECTED)"
