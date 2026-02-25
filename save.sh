#!/usr/bin/env bash
set -euo pipefail

# Usage: forks/forker/save.sh <name> [description]
#   Captures local work in the fork clone as a patch file in .pin/<name>/.
#   description: short label for the patch (default: "local")

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/save.sh <name> [description]}"
shift

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")

DESCRIPTION="${1:-local}"
# Sanitize description for use in filename (fallback if nothing alphanumeric remains)
DESCRIPTION=$(printf '%s' "$DESCRIPTION" | tr -c '[:alnum:]-_' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
[ -z "$DESCRIPTION" ] && DESCRIPTION="local"

# Check prerequisites
if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: $NAME clone does not exist. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
fi

PINNED_HEAD=$(pinned_head "$PIN_DIR" 2>/dev/null) || {
  echo "ERROR: No pins found. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
}

CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
if [ "$CURRENT_BRANCH" != "wip" ]; then
  echo "ERROR: Expected to be on 'wip' branch, but on '$CURRENT_BRANCH'." >&2
  exit 1
fi

# Check for changes (committed + uncommitted + staged + untracked) relative to pinned HEAD
if git -C "$REPO_DIR" diff "$PINNED_HEAD" --quiet 2>/dev/null \
   && git -C "$REPO_DIR" diff --cached "$PINNED_HEAD" --quiet 2>/dev/null \
   && [ -z "$(git -C "$REPO_DIR" ls-files --others --exclude-standard 2>/dev/null)" ]; then
  echo "No changes to save (working tree matches pinned HEAD)."
  exit 0
fi

# Count existing local patches to find the pre-local-patches base state.
# Local patches are linear commits on top of post-patch.sh, so PINNED_HEAD~N
# gives us the base before any local patches were applied.
EXISTING=$(count_glob "$PIN_DIR"/local-*.patch)
if [ "$EXISTING" -gt 0 ]; then
  PATCH_BASE=$(git -C "$REPO_DIR" rev-parse "${PINNED_HEAD}~${EXISTING}" 2>/dev/null) || {
    echo "ERROR: Cannot compute base state. Pins may be corrupted." >&2
    echo "Re-record with:  bash forks/forker/record.sh $NAME" >&2
    exit 1
  }
else
  PATCH_BASE="$PINNED_HEAD"
fi

NEXT_NUM=$(printf '%03d' $((EXISTING + 1)))
PATCH_NAME="local-${NEXT_NUM}-${DESCRIPTION}"

# Stage everything so untracked files are included in the diff
git -C "$REPO_DIR" add -A
# Generate patch: incremental changes relative to pinned HEAD (not base)
git -C "$REPO_DIR" diff --cached "$PINNED_HEAD" > "$PIN_DIR/${PATCH_NAME}.patch"

# Verify patch is non-empty
if [ ! -s "$PIN_DIR/${PATCH_NAME}.patch" ]; then
  rm -f "$PIN_DIR/${PATCH_NAME}.patch"
  echo "No diff to save."
  exit 0
fi

# Rebuild deterministic state from base (before any local patches)
git -C "$REPO_DIR" reset --hard "$PATCH_BASE"

apply_local_patches "$REPO_DIR" "$PIN_DIR" || {
  # Remove the newly-written patch so a retry doesn't hit the same failure
  rm -f "$PIN_DIR/${PATCH_NAME}.patch"
  echo "Earlier patches may have changed the base. Edit or reorder patches." >&2
  exit 1
}

# Update HEAD
git -C "$REPO_DIR" rev-parse HEAD > "$PIN_DIR/HEAD"

echo "Saved ${PATCH_NAME}.patch. Commit .pin/$NAME/ to share."
