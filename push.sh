#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/push.sh <name> [target-branch]}"
shift

MODE=$(entry_mode "$NAME")
if [ "$MODE" != "managed" ]; then
  echo "ERROR: $NAME is a reference entry and cannot use push.sh." >&2
  exit 1
fi

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "ERROR: $NAME clone does not exist. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
fi

PINNED_HEAD=$(pinned_head "$PIN_DIR" 2>/dev/null) || {
  echo "ERROR: No pins found. Run 'bash forks/forker/record.sh $NAME' first." >&2
  exit 1
}

if has_legacy_local_patches "$PIN_DIR"; then
  echo "ERROR: $NAME still uses an unsupported legacy local patch layout. Delete and regenerate its pins first." >&2
  exit 1
fi

LOCAL_BASE=$(local_base "$PIN_DIR" 2>/dev/null) || {
  echo "ERROR: $NAME pins are missing LOCAL_BASE." >&2
  exit 1
}

CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
if [ "$CURRENT_BRANCH" != "wip" ]; then
  echo "ERROR: Expected to be on 'wip' branch, but on '$CURRENT_BRANCH'." >&2
  echo "Switch back with:  git -C forks/$NAME checkout wip" >&2
  exit 1
fi

CURRENT_HEAD=$(repo_head "$REPO_DIR")
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$LOCAL_BASE" "$CURRENT_HEAD" >/dev/null 2>&1; then
  echo "ERROR: wip is not based on the pinned LOCAL_BASE." >&2
  exit 1
fi

if commit_range_has_merges "$REPO_DIR" "$LOCAL_BASE" "$CURRENT_HEAD"; then
  echo "ERROR: push.sh requires a linear local series after LOCAL_BASE. Cherry-pick merges into plain commits first." >&2
  exit 1
fi

if repo_has_worktree_changes "$REPO_DIR"; then
  echo "ERROR: wip must be clean before running push.sh." >&2
  show_repo_worktree_changes "$REPO_DIR"
  exit 1
fi

if ! saved_series_matches_ref "$REPO_DIR" "$PIN_DIR" "$CURRENT_HEAD"; then
  echo "ERROR: live wip commit series does not match the saved pin series." >&2
  echo "Run 'bash forks/forker/save.sh $NAME' before pushing." >&2
  echo "  pinned HEAD: $PINNED_HEAD" >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  TARGET="$1"
else
  TARGET=$(git -C "$REPO_DIR" for-each-ref --sort=-committerdate --format='%(refname:short)' 'refs/heads/pr-*' | sed -n '1p')
  if [ -z "$TARGET" ]; then
    echo "ERROR: No target branch. Pass one explicitly, for example 'bash forks/forker/push.sh $NAME pr-123'." >&2
    exit 1
  fi
fi

if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$TARGET"; then
  TARGET_START="$TARGET"
elif git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$TARGET"; then
  TARGET_START="origin/$TARGET"
elif git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/fork/$TARGET"; then
  TARGET_START="fork/$TARGET"
else
  echo "ERROR: Target branch '$TARGET' does not exist locally or on origin/fork." >&2
  exit 1
fi

TARGET_WORK=$(mktemp -d)
trap 'rm -rf "$TARGET_WORK"' EXIT

SAVED_COUNT=$(saved_series_count "$PIN_DIR")
TARGET_COUNT=0
COMMON_PREFIX=0
if git -C "$REPO_DIR" merge-base --is-ancestor "$LOCAL_BASE" "$TARGET_START" >/dev/null 2>&1; then
  # Compare the target branch against the saved series so push.sh can skip any
  # prefix that was already pushed and only cherry-pick the missing suffix.
  export_commit_series "$REPO_DIR" "$LOCAL_BASE" "$TARGET_START" "$TARGET_WORK/target"
  TARGET_COUNT=$(count_glob "$TARGET_WORK/target"/*.patch)
  COMMON_PREFIX=$(series_prefix_length "$(series_dir "$PIN_DIR")" "$TARGET_WORK/target")

  if [ "$TARGET_COUNT" -ne "$COMMON_PREFIX" ]; then
    echo "ERROR: target branch '$TARGET' diverged from the saved pin series." >&2
    exit 1
  fi
fi

echo "Commits since recording:"
git -C "$REPO_DIR" log --oneline "$LOCAL_BASE..HEAD"
echo

if [ "$SAVED_COUNT" -eq "$COMMON_PREFIX" ]; then
  echo "No new commits to push."
  exit 0
fi

mapfile -t WIP_COMMITS < <(git -C "$REPO_DIR" rev-list --reverse "$LOCAL_BASE..wip")
COMMITS_TO_PUSH=("${WIP_COMMITS[@]:$COMMON_PREFIX}")
COMMIT_COUNT=${#COMMITS_TO_PUSH[@]}

echo "Cherry-picking $COMMIT_COUNT commit(s) onto $TARGET..."
git -C "$REPO_DIR" checkout -B "$TARGET" "$TARGET_START"
if ! git -C "$REPO_DIR" cherry-pick "${COMMITS_TO_PUSH[@]}"; then
  echo >&2
  echo "ERROR: Cherry-pick failed. Resolve conflicts on $TARGET, then continue or abort:" >&2
  echo "  git -C forks/$NAME cherry-pick --continue" >&2
  echo "  git -C forks/$NAME cherry-pick --abort" >&2
  echo "When done, return with:  git -C forks/$NAME checkout wip" >&2
  exit 1
fi

git -C "$REPO_DIR" checkout wip >/dev/null 2>&1
trap - EXIT
rm -rf "$TARGET_WORK"

FORK_REMOTE=$(fork_url "$NAME" 2>/dev/null) || true

echo
echo "Done. Next steps:"
if [ -n "${FORK_REMOTE:-}" ] && git -C "$REPO_DIR" remote get-url fork >/dev/null 2>&1; then
  echo "  Push the target branch:  git -C forks/$NAME push fork $TARGET:<remote-branch>"
elif [ -n "${FORK_REMOTE:-}" ]; then
  echo "  Fork remote is configured but missing locally. Re-run record/replay or add it before pushing."
else
  echo "  No fork remote is configured for $NAME. Push the target branch with your chosen remote."
fi
echo "  After pushing and updating refs, re-record:  bash forks/forker/record.sh $NAME"
