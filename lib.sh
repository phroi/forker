#!/usr/bin/env bash
# Shared helpers for fork management scripts

FORKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORKS_DIR="$(cd "$FORKER_DIR/.." && pwd)"
ROOT_DIR="$(cd "$FORKS_DIR/.." && pwd)"

# Read a value from forks/config.json for a given entry
# Usage: config_val <name> <jq-expr>
config_val() {
  jq -r ".[\"$1\"] | $2" "$FORKS_DIR/config.json"
}

# Get the clone directory path for a fork entry.
# When _FORKER_WORK_REPO is exported (atomic-swap mode in record/replay),
# returns the staging path so subprocesses like patch.sh target it.
# Usage: repo_dir <name>
repo_dir() {
  if [ -n "${_FORKER_WORK_REPO:-}" ]; then
    echo "$_FORKER_WORK_REPO"
  else
    echo "$FORKS_DIR/$1"
  fi
}

# Get the pin directory path for a fork entry.
# When _FORKER_WORK_PIN is exported (atomic-swap mode in record.sh),
# returns the staging path.
# Usage: pin_dir <name>
pin_dir() {
  if [ -n "${_FORKER_WORK_PIN:-}" ]; then
    echo "$_FORKER_WORK_PIN"
  else
    echo "$FORKS_DIR/.pin/$1"
  fi
}

# Get the upstream URL from config
# Usage: upstream_url <name>
upstream_url() {
  config_val "$1" '.upstream'
}

# Get the fork URL from config (may be empty)
# Usage: fork_url <name>
fork_url() {
  local url
  url=$(config_val "$1" '.fork // empty')
  [ -n "$url" ] && echo "$url"
}

# Get the refs array from config as lines
# Usage: repo_refs <name>
repo_refs() {
  config_val "$1" '.refs[]'
}

# Discover all fork entry names from config.json (excludes forker itself)
# Usage: discover_forks
discover_forks() {
  local tool_name
  tool_name=$(basename "$FORKER_DIR")
  jq -r --arg skip "$tool_name" 'keys[] | select(. != $skip)' "$FORKS_DIR/config.json"
}

# Read the expected HEAD SHA from .pin/<name>/HEAD
# Usage: pinned_head <pin-dir>
pinned_head() {
  local f="$1/HEAD"
  [ -f "$f" ] && cat "$f" || return 1
}

# Return path to .pin/<name>/manifest if it exists
# Usage: manifest_file <pin-dir>
manifest_file() {
  local f="$1/manifest"
  [ -f "$f" ] && echo "$f" || return 1
}

# Check whether pins exist (manifest present)
# Usage: has_pin <pin-dir>
has_pin() {
  [ -f "$1/manifest" ]
}

# Count merge refs in manifest (total lines minus base line)
# Usage: merge_count <pin-dir>
merge_count() {
  local mf
  mf=$(manifest_file "$1") || return 1
  echo $(( $(wc -l < "$mf") - 1 ))
}

# Export deterministic git identity for reproducible commits
# Usage: deterministic_env <epoch-seconds>
deterministic_env() {
  export GIT_AUTHOR_NAME="ci" GIT_AUTHOR_EMAIL="ci@local"
  export GIT_COMMITTER_NAME="ci" GIT_COMMITTER_EMAIL="ci@local"
  export GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000"
}

# Count files matching a glob pattern (pipefail-safe alternative to ls|wc -l)
# Usage: count_glob pattern  (e.g., count_glob "$dir"/local-*.patch)
count_glob() {
  local n=0
  for f in "$@"; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

# Apply local patches from .pin/<name>/ as deterministic commits.
# Timestamp sequence continues from patch.sh: merge_count+1 is patch.sh,
# so local patches start at merge_count+2.
# Returns 1 if any patch fails to apply (caller should add remediation advice).
# Usage: apply_local_patches <repo-dir> <pin-dir>
apply_local_patches() {
  local repo_dir="$1" p_dir="$2"
  local mc ts patch name
  mc=$(merge_count "$p_dir") || mc=0
  ts=$((mc + 2))
  for patch in "$p_dir"/local-*.patch; do
    [ -f "$patch" ] || return 0
    name=$(basename "$patch" .patch)
    echo "Applying local patch: $name" >&2
    if ! git -C "$repo_dir" apply "$patch"; then
      echo "ERROR: Local patch $name failed to apply." >&2
      return 1
    fi
    deterministic_env "$ts"
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -m "local: $name"
    ts=$((ts + 1))
  done
}

# Apply counted conflict resolutions to a single conflicted file.
# Reads resolution data (CONFLICT headers + content lines) from $1,
# walks the conflicted file $2 positionally by line counts (never inspects
# content), and outputs the resolved file to stdout.
# Exits non-zero if the conflict count in the resolution data doesn't match
# the number of <<<<<<< markers in the file (catches fake markers).
# Usage: apply_counted_resolutions <resolution-data> <conflicted-file>
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

# Regenerate fork workspace entries in pnpm-workspace.yaml.
# Reads forks/config.json and replaces the section between
# @generated markers with computed include/exclude globs.
# Usage: sync_workspace_yaml
sync_workspace_yaml() {
  local yaml="$ROOT_DIR/pnpm-workspace.yaml"
  local entries=""

  while IFS= read -r name; do
    mapfile -t includes < <(config_val "$name" '.workspace.include // [] | .[]')
    [ ${#includes[@]} -eq 0 ] && continue

    for inc in "${includes[@]}"; do
      entries+="  - forks/${name}/${inc}"$'\n'
    done

    mapfile -t excludes < <(config_val "$name" '.workspace.exclude // [] | .[]')
    for excl in "${excludes[@]}"; do
      entries+="  - \"!forks/${name}/${excl}\""$'\n'
    done
  done < <(discover_forks)

  awk -v entries="$entries" '
    /^  # @generated begin forker-workspaces/ { print; printf "%s", entries; skip=1; next }
    /^  # @generated end forker-workspaces/ { skip=0; print; next }
    !skip { print }
  ' "$yaml" > "$yaml.tmp" && mv "$yaml.tmp" "$yaml"
}

# Apply a multi-file resolution file to a repo directory.
# Splits by "--- path" headers into per-file chunks, then calls
# apply_counted_resolutions for each file, replacing it in-place.
# Usage: apply_resolution_file <repo-dir> <resolution-file>
apply_resolution_file() {
  local repo_dir="$1" res_file="$2"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Split by --- headers; write path list and per-file chunks
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

  local i=0 path
  while IFS= read -r path; do
    i=$((i + 1))
    apply_counted_resolutions "$tmp_dir/chunk-$i" "$repo_dir/$path" \
      > "$repo_dir/${path}.resolved.tmp"
    mv "$repo_dir/${path}.resolved.tmp" "$repo_dir/$path"
  done < "$tmp_dir/paths"
}
