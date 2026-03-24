#!/usr/bin/env bash
set -euo pipefail

# Save the committed local work above LOCAL_BASE as a full format-patch series.
# This intentionally ignores unstaged history and rewrites the full saved series.

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: $TOOL_REL/save.sh <name>}"

MODE=$(entry_mode "$NAME")
if [ "$MODE" != "managed" ]; then
  echo "ERROR: $NAME is a reference entry. Managed pins are required to save a commit series." >&2
  exit 1
fi

REPO_DIR=$(repo_dir "$NAME")
PIN_DIR=$(pin_dir "$NAME")
BOOTSTRAP=0
BOOTSTRAP_REPO=""
BOOTSTRAP_PIN=""

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "ERROR: $NAME clone does not exist. Run 'bash $TOOL_REL/record.sh $NAME' first." >&2
  exit 1
fi

if repo_has_worktree_changes "$REPO_DIR"; then
  echo "ERROR: save.sh now records committed history only. Commit or stash local changes first." >&2
  show_repo_worktree_changes "$REPO_DIR"
  exit 1
fi

CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)

WORK_DIR=$(mktemp -d)
TMP_REPO="$WORK_DIR/repo"
TMP_PIN="$WORK_DIR/pin"
TMP_SERIES="$WORK_DIR/series"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$TMP_PIN"

if PINNED_HEAD=$(pinned_head "$PIN_DIR" 2>/dev/null); then
  if [ "$CURRENT_BRANCH" != "wip" ]; then
    echo "ERROR: Expected to be on 'wip' branch, but on '$CURRENT_BRANCH'." >&2
    exit 1
  fi

  if has_legacy_local_patches "$PIN_DIR"; then
    echo "ERROR: $NAME still uses an unsupported legacy local patch layout. Delete and regenerate its pins first." >&2
    exit 1
  fi

  BASE_COMMIT=$(local_base "$PIN_DIR") || {
    echo "ERROR: $NAME pins are missing LOCAL_BASE." >&2
    exit 1
  }

  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$BASE_COMMIT" HEAD >/dev/null 2>&1; then
    echo "ERROR: wip is not based on the pinned LOCAL_BASE." >&2
    echo "Use 'bash $TOOL_REL/clean.sh $NAME' and then 'bash $TOOL_REL/replay.sh $NAME' before saving again." >&2
    exit 1
  fi

  if commit_range_has_merges "$REPO_DIR" "$BASE_COMMIT" HEAD; then
    echo "ERROR: save.sh requires a linear local series after LOCAL_BASE. Cherry-pick merges into plain commits first." >&2
    exit 1
  fi

  if saved_series_matches_ref "$REPO_DIR" "$PIN_DIR" HEAD; then
    echo "No changes to save (commit series already matches pins)."
    exit 0
  fi

  cp -a "$PIN_DIR"/. "$TMP_PIN/"
else
  BOOTSTRAP=1
  BOOTSTRAP_ROOT="$WORK_DIR/bootstrap"
  BOOTSTRAP_FORKS="$BOOTSTRAP_ROOT/forks"
  BOOTSTRAP_TOOL="$BOOTSTRAP_FORKS/.forker-tool"
  BOOTSTRAP_LOG="$WORK_DIR/bootstrap-record.log"

  # Bootstrap save derives the managed base in isolation first, then checks
  # that the live clone history is already built on top of that same base.
  mkdir -p "$BOOTSTRAP_TOOL"
  cp -a "$FORKER_DIR"/. "$BOOTSTRAP_TOOL/"
  rm -rf "$BOOTSTRAP_TOOL/.git"
  cp "$FORKS_DIR/config.json" "$BOOTSTRAP_FORKS/config.json"

  if ! env -u _FORKER_WORK_REPO -u _FORKER_WORK_PIN FORKER_PACKAGE_ROOT="$ROOT_DIR" bash "$BOOTSTRAP_TOOL/record.sh" "$NAME" >"$BOOTSTRAP_LOG" 2>&1; then
    cat "$BOOTSTRAP_LOG" >&2
    echo "ERROR: bootstrap save could not derive the managed base." >&2
    exit 1
  fi

  BOOTSTRAP_REPO="$BOOTSTRAP_FORKS/$NAME"
  BOOTSTRAP_PIN="$BOOTSTRAP_FORKS/.pin/$NAME"
  BASE_COMMIT=$(local_base "$BOOTSTRAP_PIN") || {
    echo "ERROR: bootstrap record did not produce LOCAL_BASE." >&2
    exit 1
  }

  if ! git -C "$REPO_DIR" fetch --quiet "$BOOTSTRAP_REPO" "$BASE_COMMIT"; then
    echo "ERROR: could not compare the live clone against the derived managed base." >&2
    exit 1
  fi

  if ! git -C "$REPO_DIR" merge-base --is-ancestor FETCH_HEAD HEAD >/dev/null 2>&1; then
    echo "ERROR: live clone is not based on the config-derived managed base." >&2
    echo "Run 'bash $TOOL_REL/record.sh $NAME' first, then make commits on wip before saving." >&2
    exit 1
  fi

  if commit_range_has_merges "$REPO_DIR" "$BASE_COMMIT" HEAD; then
    echo "ERROR: save.sh requires a linear local series after the derived managed base. Cherry-pick merges into plain commits first." >&2
    exit 1
  fi

  cp -a "$BOOTSTRAP_PIN"/. "$TMP_PIN/"
fi

remove_saved_series "$TMP_PIN"
# Save always rewrites the whole LOCAL_BASE..HEAD series so pins describe the
# exact current local branch history instead of an append-only delta stack.
export_commit_series "$REPO_DIR" "$BASE_COMMIT" HEAD "$TMP_SERIES"

SERIES_COUNT=$(count_glob "$TMP_SERIES"/*.patch)

if [ "$BOOTSTRAP" -eq 0 ]; then
  git clone --quiet "$REPO_DIR" "$TMP_REPO"
  git -C "$TMP_REPO" checkout "$BASE_COMMIT" >/dev/null 2>&1
  git -C "$TMP_REPO" checkout -B wip >/dev/null 2>&1
else
  TMP_REPO="$BOOTSTRAP_REPO"
fi

write_local_base "$TMP_PIN" "$BASE_COMMIT"
if [ "$SERIES_COUNT" -gt 0 ]; then
  mkdir -p "$(series_dir "$TMP_PIN")"
  cp "$TMP_SERIES"/*.patch "$(series_dir "$TMP_PIN")/"
fi

apply_saved_series "$TMP_REPO" "$TMP_PIN"

NEW_HEAD=$(git -C "$TMP_REPO" rev-parse HEAD)

rm -rf "$PIN_DIR"
mkdir -p "$PIN_DIR"
cp -a "$TMP_PIN"/. "$PIN_DIR/"
printf '%s\n' "$NEW_HEAD" > "$PIN_DIR/HEAD"

if [ "$BOOTSTRAP" -eq 1 ] && [ "$SERIES_COUNT" -eq 0 ]; then
  echo "Bootstrapped pins (no local commits to save). Commit .pin/$NAME/ to share."
elif [ "$BOOTSTRAP" -eq 1 ]; then
  echo "Bootstrapped pins and saved $SERIES_COUNT commit(s) in .pin/$NAME/series/. Commit .pin/$NAME/ to share."
elif [ "$SERIES_COUNT" -eq 0 ]; then
  echo "Saved an empty local series. Commit .pin/$NAME/ to share."
else
  echo "Saved $SERIES_COUNT commit(s) in .pin/$NAME/series/. Commit .pin/$NAME/ to share."
fi
