#!/usr/bin/env bash
set -euo pipefail

# Usage: forks/forker/push.sh <name> [target-branch]
#   Cherry-picks commits made after recording onto the PR branch.
#   target-branch: defaults to the last pr-* branch found.

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/push.sh <name> [target-branch]}"
shift

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")

# Verify prerequisites
if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: $NAME clone does not exist. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
fi

WIP_HEAD=$(pinned_head "$PIN_DIR" 2>/dev/null) || {
  echo "ERROR: No pins found. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
}

# Verify we're on the wip branch
CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
if [ "$CURRENT_BRANCH" != "wip" ]; then
  echo "ERROR: Expected to be on 'wip' branch, but on '$CURRENT_BRANCH'." >&2
  echo "Switch back with:  cd forks/$NAME && git checkout wip" >&2
  exit 1
fi

# Show commits to push
echo "Commits since recording:"
git -C "$REPO_DIR" log --oneline "$WIP_HEAD..HEAD"
echo ""

COMMIT_COUNT=$(git -C "$REPO_DIR" rev-list --count "$WIP_HEAD..HEAD")
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "No new commits to push."
  exit 0
fi

# Determine target branch
if [ $# -gt 0 ]; then
  TARGET="$1"
else
  TARGET=$(git -C "$REPO_DIR" branch --list 'pr-*' | sed 's/^[* ]*//' | tail -1)
  if [ -z "$TARGET" ]; then
    echo "ERROR: No target branch. Pass a branch name or record a PR first." >&2
    exit 1
  fi
fi

echo "Cherry-picking $COMMIT_COUNT commit(s) onto $TARGET..."
git -C "$REPO_DIR" checkout "$TARGET"
if ! git -C "$REPO_DIR" cherry-pick "$WIP_HEAD..wip"; then
  echo "" >&2
  echo "ERROR: Cherry-pick failed. To recover:" >&2
  echo "  cd forks/$NAME" >&2
  echo "  # Resolve conflicts, then: git cherry-pick --continue" >&2
  echo "  # Or abort with: git cherry-pick --abort && git checkout wip" >&2
  exit 1
fi

echo ""
echo "Done. You are now on $TARGET with your commits applied."
echo "Push with:  cd forks/$NAME && git push <remote> $TARGET:<branch>"
echo "Return to:  cd forks/$NAME && git checkout wip"
