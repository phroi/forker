#!/usr/bin/env bash

# Shared helper functions for the forker scripts. Keep this file focused on
# config access, pin/clone path resolution, and deterministic replay helpers.

FORKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_DIR="$(cd "$FORKER_DIR/.." && pwd)"
FORKS_DIR="$(cd "$ENTRY_DIR/.." && pwd)"
TOOL_REL="forks/$(basename "$ENTRY_DIR")/repo"
ROOT_DIR="$(cd "$FORKS_DIR/.." && pwd)"
PACKAGE_ROOT="${FORKER_PACKAGE_ROOT:-$ROOT_DIR}"

config_val() {
  # Read one config entry and evaluate a jq expression against it.
  jq -r ".[\"$1\"] | $2" "$FORKS_DIR/config.json"
}

entry_mode() {
  config_val "$1" '.mode'
}

live_repo_dir() {
  echo "$FORKS_DIR/$1/repo"
}

live_pin_dir() {
  echo "$FORKS_DIR/$1/pin"
}

entry_dir() {
  echo "$FORKS_DIR/$1"
}

stage_root_dir() {
  echo "$FORKS_DIR/.stage"
}

stage_entry_dir() {
  echo "$(stage_root_dir)/$1"
}

stage_repo_dir() {
  echo "$(stage_entry_dir "$1")/repo"
}

stage_pin_dir() {
  echo "$(stage_entry_dir "$1")/pin"
}

lock_root_dir() {
  echo "$FORKS_DIR/.lock"
}

entry_lock_dir() {
  echo "$(lock_root_dir)/$1.lock"
}

supports_mv_exchange() {
  case "$(mv --help 2>&1)" in
    *--exchange*) return 0 ;;
    *) return 1 ;;
  esac
}

acquire_entry_lock() {
  local name="$1"
  local lock_dir previous_return_trap

  mkdir -p "$(lock_root_dir)"
  lock_dir=$(entry_lock_dir "$name")
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "ERROR: $name is already being modified by another forker command." >&2
    return 1
  fi

  # `trap -p RETURN` returns a full trap command, so chain it verbatim.
  previous_return_trap=$(trap -p RETURN || true)
  trap "rm -rf '$lock_dir'; ${previous_return_trap:-trap - RETURN}" RETURN
}

reset_stage_entry() {
  local name="$1"
  local stage_entry

  stage_entry=$(stage_entry_dir "$name")
  rm -rf "$stage_entry"
  mkdir -p "$stage_entry"
}

cleanup_stage_entry() {
  rm -rf "$(stage_entry_dir "$1")"
}

publish_dir_swap() {
  local staged="$1"
  local live="$2"
  local live_parent

  # Swap staged and live in one step so readers see old or new, not half-published state.
  live_parent=$(dirname "$live")
  mkdir -p "$live_parent"

  if [ -e "$live" ]; then
    if ! supports_mv_exchange; then
      echo "ERROR: mv --exchange is required to swap existing directories safely." >&2
      return 1
    fi
    mv -T --exchange "$staged" "$live"
  else
    mv -T "$staged" "$live"
  fi
}

publish_repo_swap() {
  local name="$1"

  publish_dir_swap "$(stage_repo_dir "$name")" "$(live_repo_dir "$name")"
  cleanup_stage_entry "$name"
}

publish_pin_swap() {
  local name="$1"

  publish_dir_swap "$(stage_pin_dir "$name")" "$(live_pin_dir "$name")"
  cleanup_stage_entry "$name"
}

publish_entry_swap() {
  local name="$1"

  # Swap the whole entry root so repo and pin move together as one generation.
  publish_dir_swap "$(stage_entry_dir "$name")" "$(entry_dir "$name")"
  cleanup_stage_entry "$name"
}

upstream_url() {
  config_val "$1" '.upstream'
}

coworker_ask() {
  pnpm --dir "$PACKAGE_ROOT" --silent coworker:ask "$@"
}

fork_url() {
  local url
  url=$(config_val "$1" '.fork // empty')
  [ -n "$url" ] && echo "$url"
}

repo_refs() {
  config_val "$1" '(.refs // [])[]'
}

all_entries() {
  jq -r 'keys[]' "$FORKS_DIR/config.json"
}

entries_in_mode() {
  jq -r --arg mode "$1" 'to_entries[] | select(.value.mode == $mode) | .key' "$FORKS_DIR/config.json"
}

managed_entries() {
  entries_in_mode managed
}

reference_entries() {
  entries_in_mode reference
}

pinned_head() {
  local f="$1/HEAD"
  [ -f "$f" ] && cat "$f" || return 1
}

manifest_file() {
  local f="$1/manifest"
  [ -f "$f" ] && echo "$f" || return 1
}

deterministic_env() {
  # Replay and record use synthetic commit metadata so the same inputs produce
  # byte-identical commits and stable HEAD pins.
  export GIT_AUTHOR_NAME="ci" GIT_AUTHOR_EMAIL="ci@local"
  export GIT_COMMITTER_NAME="ci" GIT_COMMITTER_EMAIL="ci@local"
  export GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000"
}

count_glob() {
  local n=0
  local f
  for f in "$@"; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

file_line_count() {
  # `wc -l` undercounts files without a trailing newline.
  awk 'END { print NR }' "$1"
}

series_dir() {
  echo "$1/series"
}

local_base_file() {
  local f="$1/LOCAL_BASE"
  [ -f "$f" ] && echo "$f" || return 1
}

local_base() {
  local f
  f=$(local_base_file "$1") || return 1
  cat "$f"
}

write_local_base() {
  printf '%s\n' "$2" > "$1/LOCAL_BASE"
}

saved_series_count() {
  count_glob "$(series_dir "$1")"/*.patch
}

saved_series_files() {
  local dir
  local patch

  dir=$(series_dir "$1")
  for patch in "$dir"/*.patch; do
    [ -f "$patch" ] && echo "$patch"
  done
}

copy_saved_series() {
  local src="$1"
  local dst="$2"
  local patch

  mkdir -p "$(series_dir "$dst")"
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    cp "$patch" "$(series_dir "$dst")/"
  done < <(saved_series_files "$src")
}

remove_saved_series() {
  rm -rf "$(series_dir "$1")"
}

has_legacy_local_patches() {
  [ -f "$1/local.patch" ] || [ "$(count_glob "$1"/local-*.patch)" -gt 0 ]
}

export_commit_series() {
  local repo_dir="$1"
  local base_ref="$2"
  local end_ref="$3"
  local out_dir="$4"

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  if ! git -C "$repo_dir" merge-base --is-ancestor "$base_ref" "$end_ref" >/dev/null 2>&1; then
    echo "ERROR: $base_ref is not an ancestor of $end_ref in $repo_dir" >&2
    return 1
  fi

  if [ "$(git -C "$repo_dir" rev-list --count "$base_ref..$end_ref")" -eq 0 ]; then
    return 0
  fi

  git -C "$repo_dir" format-patch \
    --quiet \
    --no-signature \
    --binary \
    --full-index \
    -o "$out_dir" \
    "$base_ref..$end_ref" >/dev/null
}

commit_range_has_merges() {
  local repo_dir="$1"
  local base_ref="$2"
  local end_ref="$3"

  [ "$(git -C "$repo_dir" rev-list --merges --count "$base_ref..$end_ref")" -gt 0 ]
}

compare_series_dirs() {
  local left="$1"
  local right="$2"
  local left_list right_list idx left_file right_file

  mapfile -t left_list < <(printf '%s\n' "$left"/*.patch | sort)
  mapfile -t right_list < <(printf '%s\n' "$right"/*.patch | sort)

  if [ "${#left_list[@]}" -eq 1 ] && [ "${left_list[0]}" = "$left/*.patch" ]; then
    left_list=()
  fi
  if [ "${#right_list[@]}" -eq 1 ] && [ "${right_list[0]}" = "$right/*.patch" ]; then
    right_list=()
  fi

  [ "${#left_list[@]}" -eq "${#right_list[@]}" ] || return 1

  for idx in "${!left_list[@]}"; do
    left_file=${left_list[$idx]}
    right_file=${right_list[$idx]}
    cmp -s <(normalize_patch_stream "$left_file") <(normalize_patch_stream "$right_file") || return 1
  done
}

normalize_patch_stream() {
  # Drop the volatile first line and normalize the numbered Subject prefix so
  # equivalent patch series compare equal even when format-patch renumbers them.
  sed -e '1d' -e 's/^Subject: \[PATCH [0-9][0-9]*\/[0-9][0-9]*\]/Subject: [PATCH]/' "$1"
}

series_prefix_length() {
  local left="$1"
  local right="$2"
  local left_list right_list idx limit prefix=0

  mapfile -t left_list < <(printf '%s\n' "$left"/*.patch | sort)
  mapfile -t right_list < <(printf '%s\n' "$right"/*.patch | sort)

  if [ "${#left_list[@]}" -eq 1 ] && [ "${left_list[0]}" = "$left/*.patch" ]; then
    left_list=()
  fi
  if [ "${#right_list[@]}" -eq 1 ] && [ "${right_list[0]}" = "$right/*.patch" ]; then
    right_list=()
  fi

  limit=${#left_list[@]}
  if [ "${#right_list[@]}" -lt "$limit" ]; then
    limit=${#right_list[@]}
  fi

  # Count the longest common prefix, not just equality, so series-to-branch.sh can resume
  # from a partially pushed series without re-cherry-picking earlier commits.
  for ((idx = 0; idx < limit; idx++)); do
    if cmp -s <(normalize_patch_stream "${left_list[$idx]}") <(normalize_patch_stream "${right_list[$idx]}"); then
      prefix=$((prefix + 1))
    else
      break
    fi
  done

  echo "$prefix"
}

saved_series_matches_ref() {
  local repo_dir="$1"
  local pin_dir="$2"
  local end_ref="${3:-HEAD}"
  local base_ref tmp_dir saved_dir previous_return_trap

  base_ref=$(local_base "$pin_dir") || return 1
  tmp_dir=$(mktemp -d)
  previous_return_trap=$(trap -p RETURN || true)
  trap "rm -rf '$tmp_dir'; ${previous_return_trap:-trap - RETURN}" RETURN
  saved_dir=$(series_dir "$pin_dir")

  export_commit_series "$repo_dir" "$base_ref" "$end_ref" "$tmp_dir/live" || return 1

  if [ ! -d "$saved_dir" ]; then
    [ "$(count_glob "$tmp_dir/live"/*.patch)" -eq 0 ]
    return
  fi

  compare_series_dirs "$saved_dir" "$tmp_dir/live"
}

apply_saved_series() {
  local repo_dir="$1"
  local pin_dir="$2"
  local dir

  dir=$(series_dir "$pin_dir")
  [ -d "$dir" ] || return 0
  [ "$(count_glob "$dir"/*.patch)" -gt 0 ] || return 0

  echo "Applying saved series" >&2

  if ! GIT_COMMITTER_NAME="ci" GIT_COMMITTER_EMAIL="ci@local" \
    git -C "$repo_dir" am --3way --committer-date-is-author-date "$dir"/*.patch; then
    git -C "$repo_dir" am --abort >/dev/null 2>&1 || true
    echo "ERROR: Saved series failed to apply." >&2
    return 1
  fi
}

repo_head() {
  git -C "$1" rev-parse HEAD
}

repo_has_untracked() {
  [ -n "$(git -C "$1" ls-files --others --exclude-standard 2>/dev/null)" ]
}

repo_has_stash() {
  [ -n "$(git -C "$1" stash list 2>/dev/null)" ]
}

repo_has_worktree_changes() {
  # Stash counts as unsafe local state too. Rebuild/save workflows must not hide it.
  ! git -C "$1" diff --quiet 2>/dev/null \
    || ! git -C "$1" diff --cached --quiet 2>/dev/null \
    || repo_has_untracked "$1" \
    || repo_has_stash "$1"
}

local_origin_head_ref() {
  git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD
}

current_upstream_ref() {
  git -C "$1" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null
}

reference_baseline_ref() {
  local ref

  ref=$(local_origin_head_ref "$1" 2>/dev/null) || ref=""
  if [ -n "$ref" ]; then
    echo "$ref"
    return 0
  fi

  current_upstream_ref "$1"
}

ref_label() {
  case "$1" in
    refs/remotes/origin/*)
      echo "${1#refs/remotes/origin/}"
      ;;
    origin/*)
      echo "${1#origin/}"
      ;;
    refs/heads/*)
      echo "${1#refs/heads/}"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

local_origin_head_sha() {
  local ref
  ref=$(reference_baseline_ref "$1") || return 1
  git -C "$1" rev-parse "$ref"
}

remote_default_branch() {
  git ls-remote --symref "$1" HEAD | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
}

set_local_origin_head() {
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
}

show_repo_worktree_changes() {
  local repo_dir="$1"
  local base_ref="${2:-}"

  if [ -n "$base_ref" ]; then
    git -C "$repo_dir" diff "$base_ref" --stat 2>/dev/null || true
    git -C "$repo_dir" diff --cached "$base_ref" --stat 2>/dev/null || true
  else
    git -C "$repo_dir" diff --stat 2>/dev/null || true
    git -C "$repo_dir" diff --cached --stat 2>/dev/null || true
  fi

  git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null || true
  git -C "$repo_dir" stash list 2>/dev/null || true
}

reference_clone_is_clean() {
  local repo_dir="$1"
  local baseline

  baseline=$(local_origin_head_sha "$repo_dir") || return 1

  [ "$(repo_head "$repo_dir")" = "$baseline" ] || return 1
  repo_has_worktree_changes "$repo_dir" && return 1
  return 0
}

apply_counted_resolutions() {
  awk '
  FNR==NR {
    if (/^CONFLICT /) {
      n++
      for (i=2; i<=NF; i++) {
        split($i, kv, "=")
        c[n, kv[1]] = kv[2]+0
      }
      rn[n] = 0
      next
    }
    rn[n]++
    r[n, rn[n]] = $0
    next
  }
  {
    if (substr($0,1,7) == "<<<<<<<") {
      cn++
      if (cn > n) {
        printf "ERROR: more conflicts in file than in resolution data (%d > %d)\n", cn, n > "/dev/stderr"
        err = 1; exit 1
      }
      for (i = 0; i < c[cn,"ours"]; i++) getline
      getline  # |||||||
      for (i = 0; i < c[cn,"base"]; i++) getline
      getline  # =======
      for (i = 0; i < c[cn,"theirs"]; i++) getline
      getline  # >>>>>>>
      for (i = 1; i <= c[cn,"resolution"]; i++) print r[cn,i]
      next
    }
    print
  }
  END {
    if (!err && cn != n) {
      printf "ERROR: expected %d conflicts, found %d\n", n, cn > "/dev/stderr"
      exit 1
    }
  }
  ' "$1" "$2"
}

apply_resolution_file() {
  local repo_dir="$1" res_file="$2"
  local tmp_dir
  local i=0 path previous_return_trap

  tmp_dir=$(mktemp -d)
  previous_return_trap=$(trap -p RETURN || true)
  trap "rm -rf '$tmp_dir'; ${previous_return_trap:-trap - RETURN}" RETURN

  # Split a multi-file resolution sidecar into per-file chunks, then feed each
  # chunk back through apply_counted_resolutions for positional reconstruction.
  awk -v dir="$tmp_dir" '
  /^--- / {
    if (f) close(f)
    n++
    path = substr($0, 5)
    print path > (dir "/paths")
    f = dir "/chunk-" n
    next
  }
  f { print > f }
  END { if (f) close(f) }
  ' "$res_file"

  [ -f "$tmp_dir/paths" ] || return 0

  while IFS= read -r path; do
    i=$((i + 1))
    apply_counted_resolutions "$tmp_dir/chunk-$i" "$repo_dir/$path" > "$repo_dir/${path}.resolved.tmp"
    mv "$repo_dir/${path}.resolved.tmp" "$repo_dir/$path"
  done < "$tmp_dir/paths"
}
