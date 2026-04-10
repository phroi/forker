#!/usr/bin/env bash

# High-level workflow helpers shared by the public forker commands.
# Public scripts source this file so destructive workflows stay in memory even
# while they replace the live phroi_forker clone underneath themselves.

require_managed_entry() {
  local name="$1"
  local mode

  mode=$(entry_mode "$name")
  if [ "$mode" != "managed" ]; then
    echo "ERROR: $name is a reference entry. Use 'bash $TOOL_REL/sync-reference.sh $name'." >&2
    return 1
  fi
}

require_reference_entry() {
  local name="$1"
  local mode

  mode=$(entry_mode "$name")
  if [ "$mode" != "reference" ]; then
    echo "ERROR: $name is a managed entry. Use 'bash $TOOL_REL/managed-to-reference.sh $name'." >&2
    return 1
  fi
}

build_reference_repo_unlocked() {
  local repo_dir="$1" upstream="$2" remote_head_branch="$3"

  rm -rf "$repo_dir"
  git init --quiet "$repo_dir" || return 1
  git -C "$repo_dir" remote add origin "$upstream" || return 1
  git -C "$repo_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" || return 1
  git -C "$repo_dir" fetch --prune --depth=1 --quiet origin "+refs/heads/*:refs/remotes/origin/*" || return 1

  if [ -n "$remote_head_branch" ]; then
    set_local_origin_head "$repo_dir" "$remote_head_branch" || return 1
  fi

  _FORKER_REFERENCE_PRIMARY_BRANCH=$(reference_primary_branch "$repo_dir" "$remote_head_branch") || return 1
  git -C "$repo_dir" checkout --quiet -B "$_FORKER_REFERENCE_PRIMARY_BRANCH" "origin/$_FORKER_REFERENCE_PRIMARY_BRANCH" || return 1
  git -C "$repo_dir" branch --set-upstream-to="origin/$_FORKER_REFERENCE_PRIMARY_BRANCH" "$_FORKER_REFERENCE_PRIMARY_BRANCH" >/dev/null 2>&1 || true

  _FORKER_REFERENCE_HEAD_SHA=$(repo_head "$repo_dir") || return 1
  _FORKER_REFERENCE_REMOTE_HEAD_BRANCH="$remote_head_branch"
}

rebuild_reference_clone_unlocked() {
  local name="$1" upstream="$2" remote_head_branch="$3"
  local work_repo

  reset_stage_entry "$name"
  work_repo=$(stage_repo_dir "$name")
  build_reference_repo_unlocked "$work_repo" "$upstream" "$remote_head_branch" || return 1
  publish_dir_swap "$work_repo" "$(live_repo_dir "$name")" || return 1
  reference_repo_make_readonly "$(live_repo_dir "$name")" || return 1
  cleanup_stage_entry "$name"
}

sync_reference_repo_unlocked() {
  local repo_dir="$1" upstream="$2" remote_head_branch="$3"

  git -C "$repo_dir" remote set-url origin "$upstream" >/dev/null 2>&1 || return 1
  git -C "$repo_dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" || return 1
  git -C "$repo_dir" reset --hard --quiet || return 1
  git -C "$repo_dir" clean -fdx >/dev/null 2>&1 || return 1
  git -C "$repo_dir" fetch --prune --depth=1 --quiet origin "+refs/heads/*:refs/remotes/origin/*" || return 1

  if [ -n "$remote_head_branch" ]; then
    set_local_origin_head "$repo_dir" "$remote_head_branch" || return 1
  fi

  _FORKER_REFERENCE_PRIMARY_BRANCH=$(reference_primary_branch "$repo_dir" "$remote_head_branch") || return 1
  git -C "$repo_dir" checkout --quiet -B "$_FORKER_REFERENCE_PRIMARY_BRANCH" "origin/$_FORKER_REFERENCE_PRIMARY_BRANCH" || return 1
  git -C "$repo_dir" reset --hard --quiet "origin/$_FORKER_REFERENCE_PRIMARY_BRANCH" || return 1
  git -C "$repo_dir" clean -fdx >/dev/null 2>&1 || return 1
  git -C "$repo_dir" branch --set-upstream-to="origin/$_FORKER_REFERENCE_PRIMARY_BRANCH" "$_FORKER_REFERENCE_PRIMARY_BRANCH" >/dev/null 2>&1 || true

  _FORKER_REFERENCE_HEAD_SHA=$(repo_head "$repo_dir") || return 1
  _FORKER_REFERENCE_REMOTE_HEAD_BRANCH="$remote_head_branch"
  reference_repo_make_readonly "$repo_dir" || return 1
}

load_entry_state() {
  local name="$1"

  _FORKER_ENTRY_NAME="$name"
  _FORKER_ENTRY_MODE=$(entry_mode "$name")
  _FORKER_ENTRY_REPO=$(live_repo_dir "$name")
  _FORKER_ENTRY_PIN=$(live_pin_dir "$name")
  _FORKER_ENTRY_STATUS=""
  _FORKER_ENTRY_PINNED_HEAD=""
  _FORKER_ENTRY_LOCAL_BASE=""
  _FORKER_ENTRY_ACTUAL_HEAD=""
  _FORKER_ENTRY_BASELINE_REF=""
  _FORKER_ENTRY_BASELINE_SHA=""
  _FORKER_ENTRY_REMOTE_HEAD_REF=""
  _FORKER_ENTRY_READONLY=""

  if [ ! -d "$_FORKER_ENTRY_REPO/.git" ]; then
    _FORKER_ENTRY_STATUS="missing"
    return 0
  fi

  if [ "$_FORKER_ENTRY_MODE" = "managed" ]; then
    if _FORKER_ENTRY_PINNED_HEAD=$(pinned_head "$_FORKER_ENTRY_PIN" 2>/dev/null); then
      if has_legacy_local_patches "$_FORKER_ENTRY_PIN"; then
        _FORKER_ENTRY_STATUS="pins-legacy"
        return 0
      fi

      _FORKER_ENTRY_LOCAL_BASE=$(local_base "$_FORKER_ENTRY_PIN" 2>/dev/null) || {
        _FORKER_ENTRY_STATUS="pins-missing-local-base"
        return 0
      }

      _FORKER_ENTRY_ACTUAL_HEAD=$(repo_head "$_FORKER_ENTRY_REPO")

      if repo_has_worktree_changes "$_FORKER_ENTRY_REPO"; then
        _FORKER_ENTRY_STATUS="worktree-dirty-pins"
        return 0
      fi

      if git -C "$_FORKER_ENTRY_REPO" merge-base --is-ancestor "$_FORKER_ENTRY_LOCAL_BASE" "$_FORKER_ENTRY_ACTUAL_HEAD" >/dev/null 2>&1 \
        && ! commit_range_has_merges "$_FORKER_ENTRY_REPO" "$_FORKER_ENTRY_LOCAL_BASE" "$_FORKER_ENTRY_ACTUAL_HEAD" \
        && saved_series_matches_ref "$_FORKER_ENTRY_REPO" "$_FORKER_ENTRY_PIN" "$_FORKER_ENTRY_ACTUAL_HEAD"; then
        if [ "$_FORKER_ENTRY_ACTUAL_HEAD" = "$_FORKER_ENTRY_PINNED_HEAD" ]; then
          _FORKER_ENTRY_STATUS="matches-pins"
        else
          _FORKER_ENTRY_STATUS="matches-saved-series"
        fi
        return 0
      fi

      if managed_clone_is_clean "$name" "$_FORKER_ENTRY_REPO"; then
        _FORKER_ENTRY_BASELINE_REF=$(managed_baseline_ref "$name" "$_FORKER_ENTRY_REPO")
        _FORKER_ENTRY_STATUS="clean-upstream-tip"
        return 0
      fi

      if ! git -C "$_FORKER_ENTRY_REPO" merge-base --is-ancestor "$_FORKER_ENTRY_LOCAL_BASE" "$_FORKER_ENTRY_ACTUAL_HEAD" >/dev/null 2>&1; then
        _FORKER_ENTRY_STATUS="head-not-based-on-local-base"
        return 0
      fi

      if commit_range_has_merges "$_FORKER_ENTRY_REPO" "$_FORKER_ENTRY_LOCAL_BASE" "$_FORKER_ENTRY_ACTUAL_HEAD"; then
        _FORKER_ENTRY_STATUS="local-series-has-merges"
        return 0
      fi

      _FORKER_ENTRY_STATUS="series-diverged"
      return 0
    fi

    _FORKER_ENTRY_BASELINE_REF=$(managed_baseline_ref "$name" "$_FORKER_ENTRY_REPO" 2>/dev/null) || {
      _FORKER_ENTRY_STATUS="no-remote-baseline"
      return 0
    }
    _FORKER_ENTRY_BASELINE_SHA=$(managed_baseline_sha "$name" "$_FORKER_ENTRY_REPO")
    _FORKER_ENTRY_ACTUAL_HEAD=$(repo_head "$_FORKER_ENTRY_REPO")

    if [ "$_FORKER_ENTRY_ACTUAL_HEAD" != "$_FORKER_ENTRY_BASELINE_SHA" ]; then
      _FORKER_ENTRY_STATUS="head-diverged"
      return 0
    fi

    if repo_has_worktree_changes "$_FORKER_ENTRY_REPO"; then
      _FORKER_ENTRY_STATUS="worktree-dirty-baseline"
      return 0
    fi

    _FORKER_ENTRY_STATUS="managed-no-pins-clean"
    return 0
  fi

  _FORKER_ENTRY_REMOTE_HEAD_REF=$(local_origin_head_ref "$_FORKER_ENTRY_REPO" 2>/dev/null || true)
  _FORKER_ENTRY_BASELINE_REF=$(reference_primary_ref "$_FORKER_ENTRY_REPO" 2>/dev/null) || {
    _FORKER_ENTRY_STATUS="no-remote-baseline"
    return 0
  }
  _FORKER_ENTRY_BASELINE_SHA=$(reference_primary_sha "$_FORKER_ENTRY_REPO")
  _FORKER_ENTRY_ACTUAL_HEAD=$(repo_head "$_FORKER_ENTRY_REPO")

  if reference_repo_is_readonly "$_FORKER_ENTRY_REPO"; then
    _FORKER_ENTRY_READONLY="yes"
  else
    _FORKER_ENTRY_READONLY="no"
  fi

  if [ "$_FORKER_ENTRY_ACTUAL_HEAD" != "$_FORKER_ENTRY_BASELINE_SHA" ]; then
    _FORKER_ENTRY_STATUS="head-diverged"
    return 0
  fi

  if reference_repo_has_worktree_changes "$_FORKER_ENTRY_REPO"; then
    _FORKER_ENTRY_STATUS="worktree-dirty-baseline"
    return 0
  fi

  if [ "$_FORKER_ENTRY_READONLY" != "yes" ]; then
    _FORKER_ENTRY_STATUS="reference-writable"
    return 0
  fi

  _FORKER_ENTRY_STATUS="reference-clean"
}

managed_clone_is_replaceable() {
  local name="$1"

  load_entry_state "$name"
  case "$_FORKER_ENTRY_STATUS" in
    missing|matches-pins|matches-saved-series|clean-upstream-tip|managed-no-pins-clean) return 0 ;;
    *) return 1 ;;
  esac
}

entry_state_is_safe() {
  local name="$1"

  load_entry_state "$name"
  case "$_FORKER_ENTRY_STATUS" in
    missing|matches-pins|matches-saved-series|clean-upstream-tip|managed-no-pins-clean|reference-clean) return 0 ;;
    *) return 1 ;;
  esac
}

render_conflict_input() {
  local work="$1"
  shift
  local idx

  for idx in "$@"; do
    printf '=== CONFLICT %s ===\n' "$idx"
    printf '%s\n' '--- ours ---'
    cat "$work/c${idx}_ours"
    printf '%s\n' '--- base ---'
    cat "$work/c${idx}_base" 2>/dev/null || printf '%s\n' '(unavailable)'
    printf '%s\n' '--- theirs ---'
    cat "$work/c${idx}_theirs"
    printf '\n'
  done
}

finish_conflict_resolution() {
  local file="$1" work="$2" count="$3"
  local -n sha_ref="$4"
  local idx ours_n base_n theirs_n res_n res_data

  for idx in $(seq 1 "$count"); do
    [ -f "$work/r$idx" ] || { echo "ERROR: missing resolution for conflict $idx in $file" >&2; return 1; }
  done

  res_data="$work/res_data"
  : > "$res_data"
  for idx in $(seq 1 "$count"); do
    ours_n=$(file_line_count "$work/c${idx}_ours")
    base_n=0
    [ -f "$work/c${idx}_base" ] && base_n=$(file_line_count "$work/c${idx}_base")
    theirs_n=$(file_line_count "$work/c${idx}_theirs")
    res_n=$(file_line_count "$work/r$idx")
    printf 'CONFLICT ours=%d base=%d theirs=%d resolution=%d sha=%s\n' \
      "$ours_n" "$base_n" "$theirs_n" "$res_n" "${sha_ref[$idx]}" >> "$res_data"
    cat "$work/r$idx" >> "$res_data"
  done

  apply_counted_resolutions "$res_data" "$file"
  cp "$res_data" "$file.resolution"
}

reuse_saved_conflict_resolutions() {
  local work="$1"
  local -n sha_ref="$2"
  local -n need_ref="$3"
  local -a still_need=()
  local idx old_sha curr_on curr_bn curr_tn

  for idx in "${need_ref[@]}"; do
    if [ -f "$work/old_r$idx" ]; then
      if [ -f "$work/old_sha$idx" ]; then
        old_sha=$(cat "$work/old_sha$idx")
        if [ "$old_sha" = "${sha_ref[$idx]}" ]; then
          cp "$work/old_r$idx" "$work/r$idx"
          echo "  conflict $idx: reused (fingerprint match)" >&2
          continue
        fi
      elif [ -f "$work/old_ours_n$idx" ]; then
        curr_on=$(file_line_count "$work/c${idx}_ours")
        curr_bn=0
        [ -f "$work/c${idx}_base" ] && curr_bn=$(file_line_count "$work/c${idx}_base")
        curr_tn=$(file_line_count "$work/c${idx}_theirs")
        if [ "$curr_on" = "$(cat "$work/old_ours_n$idx")" ] \
          && [ "$curr_bn" = "$(cat "$work/old_base_n$idx")" ] \
          && [ "$curr_tn" = "$(cat "$work/old_theirs_n$idx")" ]; then
          cp "$work/old_r$idx" "$work/r$idx"
          echo "  conflict $idx: reused (count match)" >&2
          continue
        fi
      fi
    fi
    still_need+=("$idx")
  done

  need_ref=("${still_need[@]}")
}

classify_and_generate_conflicts() {
  local work="$1"
  local -n need_ref="$2"
  local strategies num strategy rest
  local -a need_generate=()

  # Ask coworker for the cheapest valid strategy first, then generate only for
  # conflicts that still need a custom merge.
  strategies=$(render_conflict_input "$work" "${need_ref[@]}" | coworker_ask \
    "For each conflict, respond with ONLY the conflict number and one strategy per line:
N OURS       - keep ours (theirs is outdated or superseded)
N THEIRS     - keep theirs (ours is outdated or superseded)
N BOTH_OT    - concatenate ours then theirs
N BOTH_TO    - concatenate theirs then ours
N GENERATE   - needs custom merge
No explanations.")

  while IFS=' ' read -r num strategy rest; do
    [[ "${num:-}" =~ ^[0-9]+$ ]] || continue
    case "$strategy" in
      OURS)
        cp "$work/c${num}_ours" "$work/r$num"
        echo "  conflict $num: classified as OURS" >&2
        ;;
      THEIRS)
        cp "$work/c${num}_theirs" "$work/r$num"
        echo "  conflict $num: classified as THEIRS" >&2
        ;;
      BOTH_OT)
        cat "$work/c${num}_ours" "$work/c${num}_theirs" > "$work/r$num"
        echo "  conflict $num: classified as BOTH_OT" >&2
        ;;
      BOTH_TO)
        cat "$work/c${num}_theirs" "$work/c${num}_ours" > "$work/r$num"
        echo "  conflict $num: classified as BOTH_TO" >&2
        ;;
      GENERATE)
        need_generate+=("$num")
        echo "  conflict $num: classified as GENERATE" >&2
        ;;
      *)
        need_generate+=("$num")
        echo "  conflict $num: unrecognized strategy '$strategy', using GENERATE" >&2
        ;;
    esac
  done <<< "$strategies"

  [ ${#need_generate[@]} -eq 0 ] && return 0

  render_conflict_input "$work" "${need_generate[@]}" | coworker_ask \
    "Merge each conflict meaningfully. Output '=== RESOLUTION N ===' header followed by ONLY the merged code. No explanations, no code fences." | awk -v dir="$work" '
  # Buffer blank lines so generated resolutions keep their exact trailing shape.
  /^=== RESOLUTION [0-9]+ ===$/ {
    if (f) {
      if (buf != "") {
        printf "%s", buf > f
        buf = ""
      }
      close(f)
    }
    f = dir "/r" $3
    buf = ""
    next
  }
  f && /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
  f { if (buf != "") { printf "%s", buf > f; buf = "" }; print > f }
  END {
    if (f) {
      if (buf != "") {
        printf "%s", buf > f
      }
      close(f)
    }
  }
  '
}

load_managed_clone_context() {
  local name="$1"
  local repo_name="$2"
  local pin_name="$3"
  local -n repo_ref="$repo_name"
  local -n pin_ref="$pin_name"

  repo_ref=$(live_repo_dir "$name")
  pin_ref=$(live_pin_dir "$name")
  if [ ! -d "$repo_ref/.git" ]; then
    echo "ERROR: $name clone does not exist. Run 'bash $TOOL_REL/upstream-to-pins.sh $name' first." >&2
    return 1
  fi
}

load_pinned_wip_context() {
  local name="$1"
  local repo_name="$2"
  local pin_name="$3"
  local pinned_name="$4"
  local local_base_name="$5"
  local branch_name="$6"
  local head_name="$7"
  local -n repo_ref="$repo_name"
  local -n pin_ref="$pin_name"
  local -n pinned_ref="$pinned_name"
  local -n local_base_ref="$local_base_name"
  local -n branch_ref="$branch_name"
  local -n head_ref="$head_name"

  load_managed_clone_context "$name" "$repo_name" "$pin_name" || return 1
  pinned_ref=$(pinned_head "$pin_ref" 2>/dev/null) || {
    echo "ERROR: No pins found. Run 'bash $TOOL_REL/upstream-to-pins.sh $name' first." >&2
    return 1
  }
  if has_legacy_local_patches "$pin_ref"; then
    echo "ERROR: $name still uses an unsupported legacy local patch layout. Rebuild pins first." >&2
    return 1
  fi
  local_base_ref=$(local_base "$pin_ref" 2>/dev/null) || {
    echo "ERROR: $name pins are missing LOCAL_BASE." >&2
    return 1
  }
  branch_ref=$(git -C "$repo_ref" branch --show-current)
  head_ref=$(repo_head "$repo_ref")
}

head_is_based_on_ref() {
  git -C "$1" merge-base --is-ancestor "$2" "$3" >/dev/null 2>&1
}

derive_bootstrap_save_base() {
  local name="$1"
  local repo_path="$2"
  local bootstrap_repo="$3"
  local bootstrap_pin="$4"
  local bootstrap_log="$5"
  local -n base_ref="$6"
  local upstream base_branch

  upstream=$(upstream_url "$name")
  base_branch=$(managed_requested_base_branch "$name" "$upstream" 2>/dev/null || true)

  if [ -z "$base_branch" ]; then
    echo "ERROR: bootstrap save could not resolve a managed base branch." >&2
    return 1
  fi

  if ! build_upstream_to_pins_staging "$name" "$base_branch" 0 "$bootstrap_repo" "$bootstrap_pin" >"$bootstrap_log" 2>&1; then
    cat "$bootstrap_log" >&2
    echo "ERROR: bootstrap save could not derive the managed base." >&2
    return 1
  fi

  base_ref=$(local_base "$bootstrap_pin") || {
    echo "ERROR: bootstrap pin derivation did not produce LOCAL_BASE." >&2
    return 1
  }

  if ! git -C "$repo_path" fetch --quiet "$bootstrap_repo" "$base_ref"; then
    echo "ERROR: could not compare the live clone against the derived managed base." >&2
    return 1
  fi

  if ! head_is_based_on_ref "$repo_path" FETCH_HEAD HEAD; then
    echo "ERROR: live clone is not based on the config-derived managed base." >&2
    echo "Run 'bash $TOOL_REL/upstream-to-pins.sh $name' first, then make commits on wip before saving." >&2
    return 1
  fi

  if commit_range_has_merges "$repo_path" "$base_ref" HEAD; then
    echo "ERROR: wip-to-series.sh requires a linear local series after the derived managed base. Cherry-pick merges into plain commits first." >&2
    return 1
  fi
}

resolve_conflict() {
  local file="$1" rel_path="$2" old_res="${3:-}"
  local count work i ours base theirs
  local -a sha=() need_coworker=()

  count=$(awk 'substr($0,1,7)=="<<<<<<<"{n++} END{print n+0}' "$file")
  [ "$count" -gt 0 ] || { echo "ERROR: no conflict markers in $file" >&2; return 1; }

  work=$(mktemp -d)
  register_exit_cleanup_dir "$work"

  awk -v dir="$work" '
  substr($0,1,7) == "<<<<<<<" { n++; section = "ours"; next }
  substr($0,1,7) == "|||||||" { section = "base";  next }
  substr($0,1,7) == "=======" { section = "theirs"; next }
  substr($0,1,7) == ">>>>>>>" { section = ""; next }
  section { print > (dir "/c" n "_" section) }
  ' "$file"

  for i in $(seq 1 "$count"); do
    touch "$work/c${i}_ours" "$work/c${i}_base" "$work/c${i}_theirs"
    sha[$i]=$({
      cat "$work/c${i}_ours"
      printf '%s\n' '---BOUNDARY---'
      cat "$work/c${i}_base" 2>/dev/null
      printf '%s\n' '---BOUNDARY---'
      cat "$work/c${i}_theirs"
    } | sha256sum | cut -d' ' -f1)

    ours="$work/c${i}_ours"
    base="$work/c${i}_base"
    theirs="$work/c${i}_theirs"
    if diff -q "$ours" "$base" >/dev/null 2>&1; then
      cp "$theirs" "$work/r$i"
      echo "  conflict $i: deterministic (take theirs)" >&2
    elif diff -q "$theirs" "$base" >/dev/null 2>&1; then
      cp "$ours" "$work/r$i"
      echo "  conflict $i: deterministic (take ours)" >&2
    elif diff -q "$ours" "$theirs" >/dev/null 2>&1; then
      cp "$ours" "$work/r$i"
      echo "  conflict $i: deterministic (sides identical)" >&2
    else
      need_coworker+=("$i")
    fi
  done

  if [ -n "$old_res" ] && [ -f "$old_res" ]; then
    awk -v target="$rel_path" -v dir="$work" '
    /^--- / { active = (substr($0, 5) == target); n = 0; f = ""; next }
    !active { next }
    /^CONFLICT / {
      if (f != "") close(f)
      n++
      for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "sha") {
          sf = dir "/old_sha" n; print kv[2] > sf; close(sf)
        }
        if (kv[1] == "ours" || kv[1] == "base" || kv[1] == "theirs") {
          sf = dir "/old_" kv[1] "_n" n; print kv[2]+0 > sf; close(sf)
        }
      }
      f = dir "/old_r" n
      next
    }
    f != "" { print > f }
    END { if (f != "") close(f) }
    ' "$old_res"
  fi

  [ ${#need_coworker[@]} -eq 0 ] && { finish_conflict_resolution "$file" "$work" "$count" sha; return; }
  reuse_saved_conflict_resolutions "$work" sha need_coworker
  [ ${#need_coworker[@]} -eq 0 ] && { finish_conflict_resolution "$file" "$work" "$count" sha; return; }
  classify_and_generate_conflicts "$work" need_coworker
  finish_conflict_resolution "$file" "$work" "$count" sha
}

build_upstream_to_pins_staging() {
  local name="$1" base_branch="$2" preserve_saved_series="$3" output_repo="$4" output_pin="$5"
  shift 5

  local upstream real_pin base_sha
  local merge_idx merge_ref merge_sha merge_msg old_merge_res=""
  local local_base_sha head_sha fork_remote resolution_count local_series_count
  local -a refs=() conflicted=() pids=()

  # Build in staging first; swap only after success.
  real_pin=$(live_pin_dir "$name")
  upstream=$(upstream_url "$name")

  if [ $# -gt 0 ]; then
    refs=("$@")
  else
    mapfile -t refs < <(repo_refs "$name")
  fi

  if [ "$preserve_saved_series" -eq 1 ] && has_legacy_local_patches "$real_pin"; then
    echo "ERROR: $name still uses an unsupported legacy local patch layout. Delete and regenerate its pins first." >&2
    return 1
  fi

  rm -rf "$output_repo" "$output_pin"
  mkdir -p "$output_pin"

  git clone --filter=blob:none "$upstream" "$output_repo"

  git -C "$output_repo" config merge.conflictStyle diff3
  git -C "$output_repo" config core.abbrev 40

  if ! git -C "$output_repo" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    echo "ERROR: base branch '$base_branch' is not available from upstream." >&2
    return 1
  fi

  git -C "$output_repo" checkout -B "$base_branch" "origin/$base_branch"
  base_sha=$(git -C "$output_repo" rev-parse HEAD)
  git -C "$output_repo" checkout -b wip

  printf '%s\t%s\n' "$base_sha" "$base_branch" > "$output_pin/manifest"

  merge_idx=0
  for ref in "${refs[@]}"; do
    merge_idx=$((merge_idx + 1))
    deterministic_env "$merge_idx"

    if [[ $ref =~ ^[0-9a-f]{7,40}$ ]]; then
      git -C "$output_repo" fetch --depth=1 origin "$ref"
      merge_ref="FETCH_HEAD"
    elif [[ $ref =~ ^[0-9]+$ ]]; then
      git -C "$output_repo" fetch origin "pull/$ref/head:pr-$ref"
      merge_ref="pr-$ref"
    else
      git -C "$output_repo" fetch origin "refs/heads/$ref:$ref"
      merge_ref="$ref"
    fi

    merge_sha=$(git -C "$output_repo" rev-parse "$merge_ref")
    printf '%s\t%s\n' "$merge_sha" "$ref" >> "$output_pin/manifest"

    merge_msg="Merge $ref into wip"
    if ! git -C "$output_repo" merge --no-ff -m "$merge_msg" "$merge_sha"; then
      mapfile -t conflicted < <(git -C "$output_repo" diff --name-only --diff-filter=U)

      old_merge_res=""
      if [ "$preserve_saved_series" -eq 1 ] && [ -f "$real_pin/res-${merge_idx}.resolution" ]; then
        old_merge_res="$real_pin/res-${merge_idx}.resolution"
      fi

      pids=()
      for file in "${conflicted[@]}"; do
        resolve_conflict "$output_repo/$file" "$file" "$old_merge_res" > "$output_repo/${file}.resolved" &
        pids+=($!)
      done

      for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
          echo "ERROR: coworker failed for ${conflicted[$i]}" >&2
          return 1
        fi
      done

      for file in "${conflicted[@]}"; do
        if [ ! -s "$output_repo/${file}.resolved" ]; then
          echo "ERROR: coworker returned empty resolution for $file" >&2
          return 1
        fi
        if grep -q '<<<<<<<' "$output_repo/${file}.resolved"; then
          echo "ERROR: conflict markers remain in $file after resolution" >&2
          return 1
        fi

        mv "$output_repo/${file}.resolved" "$output_repo/$file"
        git -C "$output_repo" add "$file"

        printf -- '--- %s\n' "$file" >> "$output_pin/res-${merge_idx}.resolution"
        cat "$output_repo/${file}.resolution" >> "$output_pin/res-${merge_idx}.resolution"
        rm "$output_repo/${file}.resolution"
      done

      echo "$merge_msg" > "$output_repo/.git/MERGE_MSG"
      GIT_EDITOR=true git -C "$output_repo" merge --continue
    fi
  done

  local_base_sha=$(git -C "$output_repo" rev-parse HEAD)
  write_local_base "$output_pin" "$local_base_sha"

  if [ "$preserve_saved_series" -eq 1 ] && [ "$(saved_series_count "$real_pin")" -gt 0 ]; then
    copy_saved_series "$real_pin" "$output_pin"
    apply_saved_series "$output_repo" "$output_pin" || {
      echo "Upstream changes may have invalidated the saved series. Rebuild wip or resave it before refreshing pins." >&2
      return 1
    }
  fi

  head_sha=$(git -C "$output_repo" rev-parse HEAD)
  printf '%s\n' "$head_sha" > "$output_pin/HEAD"

  fork_remote=$(fork_url "$name" 2>/dev/null) || true
  if [ -n "${fork_remote:-}" ] && ! git -C "$output_repo" remote get-url fork >/dev/null 2>&1; then
    git -C "$output_repo" remote add fork "$fork_remote"
  fi

  resolution_count=$(count_glob "$output_pin"/res-*.resolution)
  local_series_count=$(saved_series_count "$output_pin")

  _FORKER_BUILD_BASE_SHA="$base_sha"
  _FORKER_BUILD_DEFAULT_BRANCH="$base_branch"
  _FORKER_BUILD_MERGE_COUNT="$merge_idx"
  _FORKER_BUILD_LOCAL_BASE_SHA="$local_base_sha"
  _FORKER_BUILD_HEAD_SHA="$head_sha"
  _FORKER_BUILD_RESOLUTION_COUNT="$resolution_count"
  _FORKER_BUILD_LOCAL_SERIES_COUNT="$local_series_count"
}

build_pins_to_wip_staging() {
  local name="$1" output_repo="$2"
  local real_pin upstream manifest expected_local_base
  local base_sha merge_idx sha ref_name merge_msg res_file actual expected
  local fork_remote
  real_pin=$(live_pin_dir "$name")
  upstream=$(upstream_url "$name")

  manifest=$(manifest_file "$real_pin" 2>/dev/null) || {
    echo "ERROR: $name has no pins to materialize. Run 'bash $TOOL_REL/upstream-to-pins.sh $name' first." >&2
    return 1
  }

  if has_legacy_local_patches "$real_pin"; then
    echo "ERROR: $name still uses an unsupported legacy local patch layout. Rebuild pins first." >&2
    return 1
  fi

  expected_local_base=$(local_base "$real_pin") || {
    echo "ERROR: $name pins are missing LOCAL_BASE." >&2
    return 1
  }

  rm -rf "$output_repo"

  base_sha=$(head -1 "$manifest" | cut -d$'\t' -f1)
  git clone --filter=blob:none "$upstream" "$output_repo"

  git -C "$output_repo" config merge.conflictStyle diff3
  git -C "$output_repo" config core.abbrev 40

  git -C "$output_repo" checkout "$base_sha"
  git -C "$output_repo" checkout -b wip

  merge_idx=0
  while IFS=$'\t' read -r sha ref_name; do
    merge_idx=$((merge_idx + 1))
    echo "Replaying merge $merge_idx: $ref_name ($sha)" >&2

    deterministic_env "$merge_idx"
    if [[ $ref_name =~ ^[0-9]+$ ]]; then
      git -C "$output_repo" fetch origin "pull/$ref_name/head:pr-$ref_name"
    elif [[ $ref_name =~ ^[0-9a-f]{7,40}$ ]]; then
      git -C "$output_repo" fetch origin "$sha"
    else
      git -C "$output_repo" fetch origin "refs/heads/$ref_name:$ref_name"
    fi

    if ! git -C "$output_repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
      if [[ ! $ref_name =~ ^[0-9a-f]{7,40}$ ]]; then
        git -C "$output_repo" fetch origin "$sha" >/dev/null 2>&1 || true
      fi
    fi

    if ! git -C "$output_repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "ERROR: Recorded commit $sha for ref $ref_name is no longer available from upstream." >&2
      echo "Rebuild pins with:  bash $TOOL_REL/rebuild-pins.sh $name" >&2
      return 1
    fi

    merge_msg="Merge $ref_name into wip"
    if ! git -C "$output_repo" merge --no-ff -m "$merge_msg" "$sha"; then
      res_file="$real_pin/res-${merge_idx}.resolution"
      if [ ! -f "$res_file" ]; then
        echo "ERROR: Merge $merge_idx ($ref_name) has conflicts but no resolution file." >&2
        echo "Rebuild pins with:  bash $TOOL_REL/rebuild-pins.sh $name" >&2
        return 1
      fi

      apply_resolution_file "$output_repo" "$res_file"

      git -C "$output_repo" add -A
      echo "$merge_msg" > "$output_repo/.git/MERGE_MSG"
      GIT_EDITOR=true git -C "$output_repo" merge --continue
    fi
  done < <(tail -n +2 "$manifest")

  actual=$(git -C "$output_repo" rev-parse HEAD)
  if [ "$actual" != "$expected_local_base" ]; then
    echo "FAIL: replay local base ($actual) != pinned LOCAL_BASE ($expected_local_base)" >&2
    echo "Pins are stale or corrupted. Rebuild pins with 'bash $TOOL_REL/rebuild-pins.sh $name'." >&2
    return 1
  fi

  apply_saved_series "$output_repo" "$real_pin" || {
    echo "Rebuild pins with:  bash $TOOL_REL/rebuild-pins.sh $name" >&2
    return 1
  }

  actual=$(git -C "$output_repo" rev-parse HEAD)
  expected=$(pinned_head "$real_pin")
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: replay HEAD ($actual) != pinned HEAD ($expected)" >&2
    echo "Pins are stale or corrupted. Rebuild pins with 'bash $TOOL_REL/rebuild-pins.sh $name'." >&2
    return 1
  fi

  fork_remote=$(fork_url "$name" 2>/dev/null) || true
  if [ -n "${fork_remote:-}" ] && ! git -C "$output_repo" remote get-url fork >/dev/null 2>&1; then
    git -C "$output_repo" remote add fork "$fork_remote"
  fi

  _FORKER_BUILD_HEAD_SHA="$expected"
  _FORKER_BUILD_LOCAL_BASE_SHA="$expected_local_base"
}

upstream_to_pins_workflow() {
  local name="$1" preserve_saved_series="$2"
  shift 2

  local real_repo real_pin work_repo work_pin upstream base_branch

  require_managed_entry "$name" || return 1
  acquire_entry_lock "$name" || return 1
  upstream=$(upstream_url "$name")
  base_branch=$(managed_requested_base_branch "$name" "$upstream" 2>/dev/null || true)

  if [ -z "$base_branch" ]; then
    echo "ERROR: cannot resolve base branch for $name." >&2
    release_entry_lock "$name"
    return 1
  fi

  if ! managed_clone_is_replaceable "$name"; then
    state_workflow "$name" >&2 || true
    echo >&2
    echo "ERROR: $name has pending work that would be lost." >&2
    echo "Run 'bash $TOOL_REL/wip-to-series.sh $name', 'bash $TOOL_REL/series-to-branch.sh $name', or 'bash $TOOL_REL/rebuild-pins.sh $name' to discard local state." >&2
    release_entry_lock "$name"
    return 1
  fi

  reset_stage_entry "$name"
  real_repo=$(live_repo_dir "$name")
  real_pin=$(live_pin_dir "$name")
  work_repo=$(stage_repo_dir "$name")
  work_pin=$(stage_pin_dir "$name")

  if ! build_upstream_to_pins_staging "$name" "$base_branch" "$preserve_saved_series" "$work_repo" "$work_pin" "$@"; then
    cleanup_stage_entry "$name"
    echo "FAILED: previous state is intact" >&2
    release_entry_lock "$name"
    return 1
  fi

  publish_entry_swap "$name"
  release_entry_lock "$name"

  echo "Pins rebuilt in $name/pin/"
  echo "  BASE=$_FORKER_BUILD_BASE_SHA ($_FORKER_BUILD_DEFAULT_BRANCH)"
  echo "  Merges: $_FORKER_BUILD_MERGE_COUNT ref(s)"
  echo "  Local base: $_FORKER_BUILD_LOCAL_BASE_SHA"
  if [ "$_FORKER_BUILD_RESOLUTION_COUNT" -gt 0 ]; then
    echo "  Resolutions: $_FORKER_BUILD_RESOLUTION_COUNT merge step(s) with conflicts"
  else
    echo "  Resolutions: none (no conflicts)"
  fi
  if [ "$_FORKER_BUILD_LOCAL_SERIES_COUNT" -gt 0 ]; then
    echo "  Saved series: $_FORKER_BUILD_LOCAL_SERIES_COUNT commit(s)"
  fi
  echo "  HEAD=$_FORKER_BUILD_HEAD_SHA"
}

pins_to_wip_workflow() {
  local name="$1" check_only="$2" allow_existing="$3"
  local real_repo work_repo

  require_managed_entry "$name" || return 1
  acquire_entry_lock "$name" || return 1

  real_repo=$(live_repo_dir "$name")
  # verify-pins.sh uses check_only=1 so it can dry-run replay regardless of the
  # live clone, while pins-to-wip.sh and rebuild-wip.sh still enforce the usual
  # replaceability rules for real writes.
  if [ "$check_only" -eq 0 ] && [ -d "$real_repo/.git" ]; then
    if [ "$allow_existing" -eq 0 ]; then
      echo "ERROR: $name clone already exists. Use 'bash $TOOL_REL/rebuild-wip.sh $name' instead." >&2
      release_entry_lock "$name"
      return 1
    fi

    if ! managed_clone_is_replaceable "$name"; then
      state_workflow "$name" >&2 || true
      echo >&2
      echo "ERROR: $name has pending work that would be lost." >&2
      echo "Run 'bash $TOOL_REL/wip-to-series.sh $name', 'bash $TOOL_REL/series-to-branch.sh $name', or clean up the clone manually." >&2
      release_entry_lock "$name"
      return 1
    fi
  fi

  reset_stage_entry "$name"
  work_repo=$(stage_repo_dir "$name")

  if ! build_pins_to_wip_staging "$name" "$work_repo"; then
    cleanup_stage_entry "$name"
    echo "FAILED: previous state is intact" >&2
    release_entry_lock "$name"
    return 1
  fi

  if [ "$check_only" -eq 1 ]; then
    cleanup_stage_entry "$name"
    echo "OK: wip HEAD matches pinned HEAD ($_FORKER_BUILD_HEAD_SHA)"
    release_entry_lock "$name"
    return 0
  fi

  publish_repo_swap "$name"
  release_entry_lock "$name"

  echo "OK: wip HEAD matches pinned HEAD ($_FORKER_BUILD_HEAD_SHA)"
}

rebuild_wip_workflow() {
  local name="$1"

  pins_to_wip_workflow "$name" 0 1
}

rebuild_pins_workflow() {
  local name="$1"
  shift

  upstream_to_pins_workflow "$name" 0 "$@"
}

sync_reference_workflow() {
  local name="$1"
  local mode upstream real_repo remote_head_branch old_sha new_sha current_sha detail old_primary old_readonly

  mode=$(entry_mode "$name")
  upstream=$(upstream_url "$name")
  real_repo=$(live_repo_dir "$name")

  if [ "$mode" != "reference" ]; then
    _FORKER_SYNC_STATUS="skipped"
    detail="mode=$mode use upstream-to-pins.sh or pins-to-wip.sh"
    printf '%s\t%s\t-\t-\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "$detail"
    return 0
  fi

  remote_head_branch=$(remote_default_branch "$upstream" 2>/dev/null || true)

  acquire_entry_lock "$name" || return 1

  if [ ! -d "$real_repo/.git" ]; then
    if ! rebuild_reference_clone_unlocked "$name" "$upstream" "$remote_head_branch"; then
      cleanup_stage_entry "$name"
      release_entry_lock "$name"
      _FORKER_SYNC_STATUS="failed"
      printf '%s\t%s\t-\t-\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "could not materialize reference clone"
      return 1
    fi

    new_sha="$_FORKER_REFERENCE_HEAD_SHA"
    release_entry_lock "$name"

    _FORKER_SYNC_STATUS="cloned"
    printf '%s\t%s\t-\t%s\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "$new_sha" "$_FORKER_REFERENCE_PRIMARY_BRANCH"
    return 0
  fi

  old_sha=$(repo_head "$real_repo")
  old_primary=$(reference_primary_branch "$real_repo" "$(reference_remote_head_branch "$real_repo" 2>/dev/null || true)" 2>/dev/null || true)
  if reference_repo_is_readonly "$real_repo"; then
    old_readonly=yes
  else
    old_readonly=no
  fi

  reference_repo_make_writable "$real_repo" || {
    release_entry_lock "$name"
    _FORKER_SYNC_STATUS="failed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "$old_sha" "$old_sha" "could not unlock reference clone"
    return 1
  }

  if ! sync_reference_repo_unlocked "$real_repo" "$upstream" "$remote_head_branch"; then
    reference_repo_make_readonly "$real_repo" >/dev/null 2>&1 || true
    current_sha=$(repo_head "$real_repo" 2>/dev/null || printf -- '-')
    release_entry_lock "$name"
    _FORKER_SYNC_STATUS="failed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "$old_sha" "$current_sha" "sync failed"
    return 1
  fi

  new_sha="$_FORKER_REFERENCE_HEAD_SHA"

  if [ "$old_sha" = "$new_sha" ] && [ "$old_primary" = "$_FORKER_REFERENCE_PRIMARY_BRANCH" ] && [ "$old_readonly" = yes ]; then
    _FORKER_SYNC_STATUS="unchanged"
  else
    _FORKER_SYNC_STATUS="updated"
  fi

  release_entry_lock "$name"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$_FORKER_SYNC_STATUS" "$old_sha" "$new_sha" "$_FORKER_REFERENCE_PRIMARY_BRANCH"
}

managed_to_reference_workflow() {
  local name="$1"
  local upstream remote_head_branch head_sha

  require_managed_entry "$name" || return 1
  upstream=$(upstream_url "$name")

  remote_head_branch=$(remote_default_branch "$upstream" 2>/dev/null || true)

  acquire_entry_lock "$name" || return 1

  if ! managed_clone_is_replaceable "$name"; then
    state_workflow "$name" >&2 || true
    echo >&2
    echo "ERROR: $name has pending work that would be lost." >&2
    echo "Run 'bash $TOOL_REL/wip-to-series.sh $name', 'bash $TOOL_REL/series-to-branch.sh $name', or clean up the clone manually before converting it to a reference entry." >&2
    release_entry_lock "$name"
    return 1
  fi

  rebuild_reference_clone_unlocked "$name" "$upstream" "$remote_head_branch" || {
    cleanup_stage_entry "$name"
    release_entry_lock "$name"
    return 1
  }
  head_sha="$_FORKER_REFERENCE_HEAD_SHA"

  rm -rf "$(live_pin_dir "$name")"
  set_entry_mode_reference "$name"
  release_entry_lock "$name"

  echo "$name: converted to reference at $head_sha ($_FORKER_REFERENCE_PRIMARY_BRANCH)"
}

reference_to_managed_workflow() {
  local name="$1"
  local upstream real_repo work_repo work_pin primary_branch remote_head_branch
  local state

  require_reference_entry "$name" || return 1
  upstream=$(upstream_url "$name")
  real_repo=$(live_repo_dir "$name")
  acquire_entry_lock "$name" || return 1

  if [ -d "$real_repo/.git" ] && repo_has_stash "$real_repo"; then
    state_workflow "$name" >&2 || true
    echo >&2
    echo "ERROR: $name has reference-local stash entries that would be lost." >&2
    echo "reference-to-managed.sh rebuilds from the upstream primary branch. Clear the stash or keep using the managed bootstrap path if local reference state must be preserved." >&2
    release_entry_lock "$name"
    return 1
  fi

  if [ -d "$real_repo/.git" ]; then
    load_entry_state "$name"
    state="$_FORKER_ENTRY_STATUS"
    if [ "$state" != "reference-clean" ]; then
      state_workflow "$name" >&2 || true
      echo >&2
      echo "ERROR: $name is not a clean read-only reference mirror." >&2
      echo "reference-to-managed.sh rebuilds from the upstream primary branch and does not preserve local reference drift." >&2
      release_entry_lock "$name"
      return 1
    fi
  fi

  if [ -d "$real_repo/.git" ]; then
    primary_branch=$(reference_primary_branch "$real_repo" "$(reference_remote_head_branch "$real_repo" 2>/dev/null || true)" 2>/dev/null || true)
  fi

  if [ -z "$primary_branch" ]; then
    remote_head_branch=$(remote_default_branch "$upstream" 2>/dev/null || true)
    reset_stage_entry "$name"
    work_repo=$(stage_repo_dir "$name")
    if ! build_reference_repo_unlocked "$work_repo" "$upstream" "$remote_head_branch"; then
      cleanup_stage_entry "$name"
      release_entry_lock "$name"
      echo "ERROR: could not resolve the current reference primary branch for $name." >&2
      return 1
    fi
    primary_branch="$_FORKER_REFERENCE_PRIMARY_BRANCH"
    cleanup_stage_entry "$name"
  fi

  reset_stage_entry "$name"
  work_repo=$(stage_repo_dir "$name")
  work_pin=$(stage_pin_dir "$name")
  if ! build_upstream_to_pins_staging "$name" "$primary_branch" 0 "$work_repo" "$work_pin"; then
    cleanup_stage_entry "$name"
    echo "FAILED: previous state is intact" >&2
    release_entry_lock "$name"
    return 1
  fi

  if [ -d "$real_repo/.git" ]; then
    reference_repo_make_writable "$real_repo" || {
      cleanup_stage_entry "$name"
      release_entry_lock "$name"
      echo "ERROR: could not unlock the existing reference clone for $name." >&2
      return 1
    }
  fi

  publish_entry_swap "$name"
  set_entry_mode_managed "$name" "$primary_branch"
  release_entry_lock "$name"

  echo "$name: converted to managed with base_branch=$primary_branch"
  echo "OK: wip HEAD matches pinned HEAD ($_FORKER_BUILD_HEAD_SHA)"
}

state_workflow() {
  local name="$1"

  load_entry_state "$name"

  case "$_FORKER_ENTRY_STATUS" in
    missing)
      echo "$name: clone is missing"
      ;;
    matches-pins)
      echo "$name: wip matches pins"
      ;;
    matches-saved-series)
      echo "$name: wip matches the saved pin series"
      ;;
    clean-upstream-tip)
      echo "$name: clone is clean at $_FORKER_ENTRY_BASELINE_REF and safe to rebuild"
      ;;
    pins-legacy)
      echo "$name: pins use an unsupported legacy patch layout"
      return 1
      ;;
    pins-missing-local-base)
      echo "$name: pins are missing LOCAL_BASE"
      return 1
      ;;
    worktree-dirty-pins)
      echo "$name: clone has changes relative to pins:"
      show_repo_worktree_changes "$_FORKER_ENTRY_REPO"
      return 1
      ;;
    head-not-based-on-local-base)
      echo "$name: HEAD is not based on pinned LOCAL_BASE:"
      echo "  local_base  $_FORKER_ENTRY_LOCAL_BASE"
      echo "  actual      $_FORKER_ENTRY_ACTUAL_HEAD"
      return 1
      ;;
    local-series-has-merges)
      echo "$name: local series contains merge commits after LOCAL_BASE"
      return 1
      ;;
    series-diverged)
      echo "$name: commit series diverged from pins:"
      echo "  local_base  $_FORKER_ENTRY_LOCAL_BASE"
      echo "  pinned      $_FORKER_ENTRY_PINNED_HEAD"
      echo "  actual      $_FORKER_ENTRY_ACTUAL_HEAD"
      git -C "$_FORKER_ENTRY_REPO" log --oneline "$_FORKER_ENTRY_LOCAL_BASE..$_FORKER_ENTRY_ACTUAL_HEAD" 2>/dev/null || true
      return 1
      ;;
    managed-no-pins-clean)
      echo "$name: managed clone has no pins and is clean at $_FORKER_ENTRY_BASELINE_REF"
      ;;
    no-remote-baseline)
      if [ "$_FORKER_ENTRY_MODE" = "reference" ]; then
        echo "$name: reference clone has no mirrored remote branches"
      else
        echo "$name: clone has no remote baseline"
      fi
      return 1
      ;;
    head-diverged)
      if [ "$_FORKER_ENTRY_MODE" = "reference" ]; then
        echo "$name: reference clone drifted from primary $_FORKER_ENTRY_BASELINE_REF:"
        echo "  primary      $_FORKER_ENTRY_BASELINE_SHA"
        echo "  actual       $_FORKER_ENTRY_ACTUAL_HEAD"
        echo "  remote_head  ${_FORKER_ENTRY_REMOTE_HEAD_REF:-unknown}"
        echo "  readonly     $_FORKER_ENTRY_READONLY"
        git -C "$_FORKER_ENTRY_REPO" log --oneline "$_FORKER_ENTRY_BASELINE_SHA..$_FORKER_ENTRY_ACTUAL_HEAD" 2>/dev/null || true
      else
        echo "$name: HEAD diverged from $_FORKER_ENTRY_BASELINE_REF:"
        echo "  baseline  $_FORKER_ENTRY_BASELINE_SHA"
        echo "  actual    $_FORKER_ENTRY_ACTUAL_HEAD"
        git -C "$_FORKER_ENTRY_REPO" log --oneline "$_FORKER_ENTRY_BASELINE_SHA..$_FORKER_ENTRY_ACTUAL_HEAD" 2>/dev/null || true
      fi
      return 1
      ;;
    worktree-dirty-baseline)
      if [ "$_FORKER_ENTRY_MODE" = "reference" ]; then
        echo "$name: reference clone has worktree changes relative to primary $_FORKER_ENTRY_BASELINE_REF:"
        echo "  remote_head  ${_FORKER_ENTRY_REMOTE_HEAD_REF:-unknown}"
        echo "  readonly     $_FORKER_ENTRY_READONLY"
      else
        echo "$name: clone has changes relative to $_FORKER_ENTRY_BASELINE_REF:"
      fi
      show_repo_worktree_changes "$_FORKER_ENTRY_REPO" "$_FORKER_ENTRY_BASELINE_REF"
      return 1
      ;;
    reference-writable)
      echo "$name: reference clone is writable but should be read-only:"
      echo "  primary      $_FORKER_ENTRY_BASELINE_REF"
      echo "  remote_head  ${_FORKER_ENTRY_REMOTE_HEAD_REF:-unknown}"
      echo "  readonly     $_FORKER_ENTRY_READONLY"
      return 1
      ;;
    reference-clean)
      echo "$name: reference clone matches primary $_FORKER_ENTRY_BASELINE_REF"
      echo "  remote_head  ${_FORKER_ENTRY_REMOTE_HEAD_REF:-unknown}"
      echo "  readonly     $_FORKER_ENTRY_READONLY"
      ;;
    *)
      echo "ERROR: unknown entry state for $name: $_FORKER_ENTRY_STATUS" >&2
      return 1
      ;;
  esac
}
state_all_workflow() {
  local exit_code=0
  local name

  while IFS= read -r name; do
    state_workflow "$name" || exit_code=1
  done < <(all_entries)

  return "$exit_code"
}

verify_pins_workflow() {
  local name="$1"

  pins_to_wip_workflow "$name" 1 0
}

verify_all_pins_workflow() {
  local verified=0 failed=0 status line
  local name

  while IFS= read -r name; do
    line=$(verify_pins_workflow "$name" 2>&1) || status=$?
    status=${status:-0}
    printf '%s\n' "$line"

    if [ "$status" -eq 0 ]; then
      verified=$((verified + 1))
    else
      failed=$((failed + 1))
    fi

    unset status
  done < <(managed_entries)

  printf 'summary\tverified=%d\tfailed=%d\n' "$verified" "$failed"
  [ "$failed" -eq 0 ]
}

sync_all_references_workflow() {
  local updated=0 cloned=0 unchanged=0 skipped=0 failed=0
  local name

  while IFS= read -r name; do
    sync_reference_workflow "$name" || true

    case "$_FORKER_SYNC_STATUS" in
      updated) updated=$((updated + 1)) ;;
      cloned) cloned=$((cloned + 1)) ;;
      unchanged) unchanged=$((unchanged + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < <(reference_entries)

  printf 'summary\tupdated=%d\tcloned=%d\tunchanged=%d\tskipped=%d\tfailed=%d\n' \
    "$updated" "$cloned" "$unchanged" "$skipped" "$failed"

  [ "$failed" -eq 0 ]
}

pins_to_missing_wips_workflow() {
  local materialized=0 skipped=0 failed=0 status line
  local name

  while IFS= read -r name; do
    if [ -d "$(live_repo_dir "$name")/.git" ]; then
      if managed_clone_is_replaceable "$name"; then
        printf '%s\tskipped\twip already present\n' "$name"
        skipped=$((skipped + 1))
      else
        printf '%s\tfailed\texisting clone needs manual attention\n' "$name"
        failed=$((failed + 1))
      fi
      continue
    fi

    line=$(pins_to_wip_workflow "$name" 0 0 2>&1) || status=$?
    status=${status:-0}
    printf '%s\n' "$line"

    if [ "$status" -eq 0 ]; then
      materialized=$((materialized + 1))
    else
      failed=$((failed + 1))
    fi

    unset status
  done < <(managed_entries)

  printf 'summary\tmaterialized=%d\tskipped=%d\tfailed=%d\n' "$materialized" "$skipped" "$failed"
  [ "$failed" -eq 0 ]
}

wip_to_series_workflow() {
  local name="$1"
  local mode repo_path pin_path bootstrap=0 current_branch="" pinned_head_sha="" base_commit current_head=""
  local work_dir tmp_repo tmp_pin tmp_series bootstrap_repo bootstrap_pin bootstrap_log
  local before_series_count=0 series_count new_head boot_base_commit
  mode=$(entry_mode "$name")
  if [ "$mode" != "managed" ]; then
    echo "ERROR: $name is a reference entry. Managed pins are required to save a commit series." >&2
    return 1
  fi

  load_managed_clone_context "$name" repo_path pin_path || return 1
  acquire_entry_lock "$name" || return 1
  reset_stage_entry "$name"

  if repo_has_worktree_changes "$repo_path"; then
    echo "ERROR: wip-to-series.sh now records committed history only. Commit or stash local changes first." >&2
    show_repo_worktree_changes "$repo_path"
    release_entry_lock "$name"
    return 1
  fi

  current_branch=$(git -C "$repo_path" branch --show-current)

  work_dir=$(stage_entry_dir "$name")
  tmp_repo="$work_dir/repo"
  tmp_pin="$work_dir/pin"
  tmp_series="$work_dir/series"
  mkdir -p "$tmp_pin"

  if [ -f "$pin_path/HEAD" ]; then
    load_pinned_wip_context "$name" repo_path pin_path pinned_head_sha base_commit current_branch current_head || {
      release_entry_lock "$name"
      return 1
    }
    if [ "$current_branch" != "wip" ]; then
      echo "ERROR: Expected to be on 'wip' branch, but on '$current_branch'." >&2
      release_entry_lock "$name"
      return 1
    fi

    if ! head_is_based_on_ref "$repo_path" "$base_commit" "$current_head"; then
      echo "ERROR: wip is not based on the pinned LOCAL_BASE." >&2
      echo "Use 'bash $TOOL_REL/rebuild-wip.sh $name' to reset before saving again." >&2
      release_entry_lock "$name"
      return 1
    fi

    if commit_range_has_merges "$repo_path" "$base_commit" HEAD; then
      echo "ERROR: wip-to-series.sh requires a linear local series after LOCAL_BASE. Cherry-pick merges into plain commits first." >&2
      release_entry_lock "$name"
      return 1
    fi

    if saved_series_matches_ref "$repo_path" "$pin_path" "$current_head"; then
      echo "No changes to save (commit series already matches pins)."
      release_entry_lock "$name"
      return 0
    fi

    cp -a "$pin_path"/. "$tmp_pin/"
  else
    # Bootstrap save derives the managed base in staging, then compares to it.
    bootstrap=1
    bootstrap_repo="$work_dir/bootstrap-repo"
    bootstrap_pin="$work_dir/bootstrap-pin"
    bootstrap_log="$work_dir/bootstrap-upstream-to-pins.log"

    if ! derive_bootstrap_save_base "$name" "$repo_path" "$bootstrap_repo" "$bootstrap_pin" "$bootstrap_log" boot_base_commit; then
      release_entry_lock "$name"
      return 1
    fi

    cp -a "$bootstrap_pin"/. "$tmp_pin/"
    base_commit="$boot_base_commit"
  fi

  before_series_count=$(saved_series_count "$pin_path" 2>/dev/null || true)
  remove_saved_series "$tmp_pin"
  export_commit_series "$repo_path" "$base_commit" HEAD "$tmp_series"
  series_count=$(count_glob "$tmp_series"/*.patch)

  if [ "$bootstrap" -eq 0 ]; then
    git clone --quiet "$repo_path" "$tmp_repo"
    git -C "$tmp_repo" checkout "$base_commit" >/dev/null 2>&1
    git -C "$tmp_repo" checkout -B wip >/dev/null 2>&1
  else
    tmp_repo="$bootstrap_repo"
  fi

  write_local_base "$tmp_pin" "$base_commit"
  if [ "$series_count" -gt 0 ]; then
    mkdir -p "$(series_dir "$tmp_pin")"
    cp "$tmp_series"/*.patch "$(series_dir "$tmp_pin")/"
  fi

  apply_saved_series "$tmp_repo" "$tmp_pin"

  new_head=$(git -C "$tmp_repo" rev-parse HEAD)

  printf '%s\n' "$new_head" > "$tmp_pin/HEAD"

  publish_pin_swap "$name"
  release_entry_lock "$name"

  if [ "$bootstrap" -eq 1 ] && [ "$series_count" -eq 0 ]; then
    echo "Bootstrapped pins (no local commits to save). Commit $name/pin/ to share."
  elif [ "$bootstrap" -eq 1 ]; then
    echo "Bootstrapped pins and saved $series_count commit(s) in $name/pin/series/. Commit $name/pin/ to share."
  elif [ "$series_count" -eq 0 ] && [ "$before_series_count" -gt 0 ]; then
    echo "Saved an empty local series. Commit $name/pin/ to share."
  else
    echo "Saved $series_count commit(s) in $name/pin/series/. Commit $name/pin/ to share."
  fi
}

series_to_branch_workflow() {
  local name="$1"
  shift

  local mode repo_path pin_path pinned_head_sha local_base current_branch current_head
  local target="${1:-}" target_start target_work saved_count target_count common_prefix
  local -a wip_commits=() commits_to_push=()
  local commit_count fork_remote
  mode=$(entry_mode "$name")
  if [ "$mode" != "managed" ]; then
    echo "ERROR: $name is a reference entry and cannot use series-to-branch.sh." >&2
    return 1
  fi

  acquire_entry_lock "$name" || return 1
  load_pinned_wip_context "$name" repo_path pin_path pinned_head_sha local_base current_branch current_head || {
    release_entry_lock "$name"
    return 1
  }

  if [ "$current_branch" != "wip" ]; then
    echo "ERROR: Expected to be on 'wip' branch, but on '$current_branch'." >&2
    echo "Switch back with:  git -C forks/$name/repo checkout wip" >&2
    release_entry_lock "$name"
    return 1
  fi

  if ! head_is_based_on_ref "$repo_path" "$local_base" "$current_head"; then
    echo "ERROR: wip is not based on the pinned LOCAL_BASE." >&2
    release_entry_lock "$name"
    return 1
  fi

  if commit_range_has_merges "$repo_path" "$local_base" "$current_head"; then
    echo "ERROR: series-to-branch.sh requires a linear local series after LOCAL_BASE. Cherry-pick merges into plain commits first." >&2
    release_entry_lock "$name"
    return 1
  fi

  if repo_has_worktree_changes "$repo_path"; then
    echo "ERROR: wip must be clean before running series-to-branch.sh." >&2
    show_repo_worktree_changes "$repo_path"
    release_entry_lock "$name"
    return 1
  fi

  if ! saved_series_matches_ref "$repo_path" "$pin_path" "$current_head"; then
    echo "ERROR: live wip commit series does not match the saved pin series." >&2
    echo "Run 'bash $TOOL_REL/wip-to-series.sh $name' to save changes before pushing." >&2
    echo "  pinned HEAD: $pinned_head_sha" >&2
    release_entry_lock "$name"
    return 1
  fi

  if [ -z "$target" ]; then
    target=$(git -C "$repo_path" for-each-ref --sort=-committerdate --format='%(refname:short)' 'refs/heads/pr-*' | sed -n '1p')
    if [ -z "$target" ]; then
      echo "ERROR: No target branch. Pass one explicitly, for example 'bash $TOOL_REL/series-to-branch.sh $name pr-123'." >&2
      release_entry_lock "$name"
      return 1
    fi
  fi

  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$target"; then
    target_start="$target"
  elif git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$target"; then
    target_start="origin/$target"
  elif git -C "$repo_path" show-ref --verify --quiet "refs/remotes/fork/$target"; then
    target_start="fork/$target"
  else
    echo "ERROR: Target branch '$target' does not exist locally or on origin/fork." >&2
    release_entry_lock "$name"
    return 1
  fi

  target_work=$(mktemp -d)
  register_exit_cleanup_dir "$target_work"

  saved_count=$(saved_series_count "$pin_path")
  target_count=0
  common_prefix=0
  if git -C "$repo_path" merge-base --is-ancestor "$local_base" "$target_start" >/dev/null 2>&1; then
    export_commit_series "$repo_path" "$local_base" "$target_start" "$target_work/target"
    target_count=$(count_glob "$target_work/target"/*.patch)
    common_prefix=$(series_prefix_length "$(series_dir "$pin_path")" "$target_work/target")

    if [ "$target_count" -ne "$common_prefix" ]; then
      echo "ERROR: target branch '$target' diverged from the saved pin series." >&2
      release_entry_lock "$name"
      return 1
    fi
  fi

  echo "Commits since recording:"
  git -C "$repo_path" log --oneline "$local_base..HEAD"
  echo

  if [ "$saved_count" -eq "$common_prefix" ]; then
    echo "No new commits to push."
    release_entry_lock "$name"
    return 0
  fi

  mapfile -t wip_commits < <(git -C "$repo_path" rev-list --reverse "$local_base..wip")
  commits_to_push=("${wip_commits[@]:$common_prefix}")
  commit_count=${#commits_to_push[@]}

  echo "Cherry-picking $commit_count commit(s) onto $target..."
  git -C "$repo_path" checkout -B "$target" "$target_start"
  if ! git -C "$repo_path" cherry-pick "${commits_to_push[@]}"; then
    echo >&2
    echo "ERROR: Cherry-pick failed. Resolve conflicts on $target, then continue or abort:" >&2
    echo "  git -C forks/$name/repo cherry-pick --continue" >&2
    echo "  git -C forks/$name/repo cherry-pick --abort" >&2
    echo "When done, return with:  git -C forks/$name/repo checkout wip" >&2
    release_entry_lock "$name"
    return 1
  fi

  git -C "$repo_path" checkout wip >/dev/null 2>&1

  fork_remote=$(fork_url "$name" 2>/dev/null) || true
  release_entry_lock "$name"

  echo
  echo "Done. Next steps:"
  if [ -n "${fork_remote:-}" ] && git -C "$repo_path" remote get-url fork >/dev/null 2>&1; then
    echo "  Push the target branch:  git -C forks/$name/repo push fork $target:<remote-branch>"
  elif [ -n "${fork_remote:-}" ]; then
    echo "  Fork remote is configured but missing locally. Re-run upstream-to-pins.sh or pins-to-wip.sh, or add it before pushing."
  else
    echo "  No fork remote is configured for $name. Push the target branch with your chosen remote."
  fi
  echo "  After pushing and updating refs, rebuild pins:  bash $TOOL_REL/upstream-to-pins.sh $name"
}

health_workflow() {
  local errors=0 warns=0 oks=0 mode pin_path repo_path has_manifest has_head has_local_base saved_series name

  report_health() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  }

  health_ok() {
    oks=$((oks + 1))
    report_health OK "$1" "$2" "${3:-}"
  }

  health_warn() {
    warns=$((warns + 1))
    report_health WARN "$1" "$2" "${3:-}"
  }

  health_error() {
    errors=$((errors + 1))
    report_health ERROR "$1" "$2" "${3:-}"
  }

  health_tool() {
    local tool="$1"
    local detail_if_missing="$2"

    if command -v "$tool" >/dev/null 2>&1; then
      health_ok tool "$tool" available
    else
      health_error tool "$tool" "$detail_if_missing"
    fi
  }

  health_pin_state() {
    if [ "$mode" = "reference" ]; then
      if [ "$has_manifest" -eq 1 ] || [ "$has_head" -eq 1 ] || [ "$has_local_base" -eq 1 ] || [ "$saved_series" -gt 0 ]; then
        health_error pin "$name" reference-entry-has-pins
      else
        health_ok pin "$name" no-pins
      fi
      return
    fi

    if [ "$saved_series" -gt 0 ] && [ "$has_manifest" -eq 0 ] && [ "$has_head" -eq 0 ] && [ "$has_local_base" -eq 0 ]; then
      health_error pin "$name" series-without-base-metadata
    elif [ "$has_manifest" -ne "$has_head" ] || [ "$has_manifest" -ne "$has_local_base" ]; then
      health_error pin "$name" manifest-head-local-base-mismatch
    elif [ "$has_manifest" -eq 1 ]; then
      health_ok pin "$name" pinned
    else
      health_warn pin "$name" managed-without-pins
    fi
  }

  health_clone_state() {
    load_entry_state "$name"
    if [ "$_FORKER_ENTRY_STATUS" = "missing" ]; then
      health_warn clone "$name" missing
    elif [ "$_FORKER_ENTRY_STATUS" = "reference-writable" ]; then
      health_error clone "$name" writable-reference
    elif [ "$_FORKER_ENTRY_STATUS" = "local-series-has-merges" ]; then
      health_warn clone "$name" non-linear-local-series
    elif entry_state_is_safe "$name"; then
      health_ok clone "$name" safe
    else
      health_warn clone "$name" dirty-or-diverged
    fi
  }

  health_tool git missing
  health_tool jq missing

  if command -v pnpm >/dev/null 2>&1; then
    health_ok tool pnpm available
  else
    health_ok tool pnpm optional-for-conflicts-only
  fi

  if supports_mv_exchange; then
    health_ok tool mv-exchange available
  else
    health_error tool mv-exchange missing
  fi

  if jq -e type "$FORKS_DIR/config.json" >/dev/null 2>&1; then
    health_ok config config-json readable
  else
    health_error config config-json invalid
  fi

  while IFS= read -r name; do
    mode=$(entry_mode "$name" 2>/dev/null || printf -- '')
    pin_path=$(live_pin_dir "$name")
    repo_path=$(live_repo_dir "$name")
    has_manifest=0
    has_head=0
    has_local_base=0
    saved_series=0

    [ -f "$pin_path/manifest" ] && has_manifest=1
    [ -f "$pin_path/HEAD" ] && has_head=1
    [ -f "$pin_path/LOCAL_BASE" ] && has_local_base=1
    saved_series=$(saved_series_count "$pin_path")

    case "$mode" in
      managed|reference)
        health_ok entry "$name" "mode=$mode"
        ;;
      *)
        health_error entry "$name" "invalid-mode=$mode"
        continue
        ;;
    esac

    if [ -d "$(entry_dir "$name")/.git" ]; then
      health_error clone "$name" old-layout-root-repo
      continue
    fi

    if has_legacy_local_patches "$pin_path"; then
      health_error pin "$name" unsupported-legacy-pin-layout
      continue
    fi

    health_pin_state
    health_clone_state
  done < <(all_entries)

  printf 'summary\tok=%d\twarn=%d\terror=%d\n' "$oks" "$warns" "$errors"
  [ "$errors" -eq 0 ]
}
