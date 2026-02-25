#!/usr/bin/env bash
set -euo pipefail

# Usage: forks/forker/record.sh <name> [ref ...]
#   ref auto-detection:
#     ^[0-9a-f]{7,40}$ → commit SHA
#     ^[0-9]+$          → GitHub PR number
#     everything else   → branch name
#   No refs on CLI → reads from config.json
#   No refs at all → just clone, no merges

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Signal .pnpmfile.cjs to skip auto-replay during recording
export FORKER_RECORDING=1

NAME="${1:?Usage: forks/forker/record.sh <name> [ref ...]}"
shift

# Real (final) paths — used for guard, local patch preservation, and swap target
REAL_REPO="$FORKS_DIR/$NAME"
REAL_PIN="$FORKS_DIR/.pin/$NAME"
UPSTREAM=$(upstream_url "$NAME")

# Collect refs: CLI args override config.json
if [ $# -gt 0 ]; then
  REFS=("$@")
else
  mapfile -t REFS < <(repo_refs "$NAME")
fi

# ---------------------------------------------------------------------------
# resolve_conflict <conflicted-file> <file-rel-path> [old-resolution-file]
#   Tiered merge conflict resolution (diff3 markers required):
#     Tier 0:  Deterministic — one side matches base → take the other (0 tokens)
#     Reuse:   Fingerprint match — old resolution valid for unchanged hunks (0 tokens)
#     Tier 1:  Strategy classification — LLM picks OURS/THEIRS/BOTH/GENERATE (~5 tokens)
#     Tier 2:  Code generation — LLM generates merged code for hunks only
#   Outputs the resolved file to stdout.
#   Writes counted resolution to <file>.resolution (collected into .pin/<name>/res-N.resolution after merge).
# ---------------------------------------------------------------------------
resolve_conflict() {
  local FILE="$1" F_REL="$2" OLD_RES="${3:-}"
  local COUNT WORK i OURS BASE THEIRS

  COUNT=$(awk 'substr($0,1,7)=="<<<<<<<"{n++} END{print n+0}' "$FILE")
  [ "$COUNT" -gt 0 ] || { echo "ERROR: no conflict markers in $FILE" >&2; return 1; }

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' RETURN

  # Extract ours / base / theirs for each conflict hunk
  awk -v dir="$WORK" '
  substr($0,1,7) == "<<<<<<<" { n++; section = "ours"; next }
  substr($0,1,7) == "|||||||" { section = "base";  next }
  substr($0,1,7) == "=======" { section = "theirs"; next }
  substr($0,1,7) == ">>>>>>>" { section = ""; next }
  section { print > (dir "/c" n "_" section) }
  ' "$FILE"

  # Ensure ours/theirs files exist even for empty hunks (edit/delete conflicts)
  for i in $(seq 1 "$COUNT"); do
    touch "$WORK/c${i}_ours" "$WORK/c${i}_theirs"
  done

  # Compute content fingerprint for each hunk (deterministic reuse across re-records).
  # Boundary markers prevent content from one section bleeding into another's hash.
  local -a SHA=()
  for i in $(seq 1 "$COUNT"); do
    SHA[$i]=$({ cat "$WORK/c${i}_ours"; echo "---BOUNDARY---"
                cat "$WORK/c${i}_base" 2>/dev/null; echo "---BOUNDARY---"
                cat "$WORK/c${i}_theirs"; } | sha256sum | cut -d' ' -f1)
  done

  # Parse old resolution for reuse: extract per-hunk sha, counts, and content
  if [ -n "$OLD_RES" ] && [ -f "$OLD_RES" ]; then
    awk -v target="$F_REL" -v dir="$WORK" '
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
    ' "$OLD_RES"
  fi

  # Tier 0: Deterministic resolution (no LLM needed)
  local NEED_LLM=()
  for i in $(seq 1 "$COUNT"); do
    OURS="$WORK/c${i}_ours"; BASE="$WORK/c${i}_base"; THEIRS="$WORK/c${i}_theirs"
    if [ ! -f "$BASE" ]; then
      NEED_LLM+=("$i"); continue
    fi
    if diff -q "$OURS" "$BASE" >/dev/null 2>&1; then
      cp "$THEIRS" "$WORK/r$i"
      echo "  conflict $i: deterministic (take theirs)" >&2
    elif diff -q "$THEIRS" "$BASE" >/dev/null 2>&1; then
      cp "$OURS" "$WORK/r$i"
      echo "  conflict $i: deterministic (take ours)" >&2
    elif diff -q "$OURS" "$THEIRS" >/dev/null 2>&1; then
      cp "$OURS" "$WORK/r$i"
      echo "  conflict $i: deterministic (sides identical)" >&2
    else
      NEED_LLM+=("$i")
    fi
  done

  # --- helper: verify, reconstruct resolved file, write resolution sidecar ---
  _finish() {
    for i in $(seq 1 "$COUNT"); do
      [ -f "$WORK/r$i" ] || { echo "ERROR: missing resolution for conflict $i in $FILE" >&2; return 1; }
    done

    # Build per-file counted resolution data
    local res_data="$WORK/res_data"
    : > "$res_data"
    for i in $(seq 1 "$COUNT"); do
      local ours_n=0 base_n=0 theirs_n=0 res_n=0
      ours_n=$(wc -l < "$WORK/c${i}_ours")
      [ -f "$WORK/c${i}_base" ] && base_n=$(wc -l < "$WORK/c${i}_base")
      theirs_n=$(wc -l < "$WORK/c${i}_theirs")
      res_n=$(wc -l < "$WORK/r$i")
      printf 'CONFLICT ours=%d base=%d theirs=%d resolution=%d sha=%s\n' \
        "$ours_n" "$base_n" "$theirs_n" "$res_n" "${SHA[$i]}" >> "$res_data"
      cat "$WORK/r$i" >> "$res_data"
    done

    # Apply counted resolutions to reconstruct resolved file (verifies counts)
    apply_counted_resolutions "$res_data" "$FILE"

    # Write resolution sidecar (collected into res-N.resolution by caller)
    cp "$res_data" "$FILE.resolution"
  }

  [ ${#NEED_LLM[@]} -eq 0 ] && { _finish; return; }

  # Try reusing old resolutions for unchanged conflicts (avoids LLM non-determinism)
  local STILL_NEED_LLM=()
  for i in "${NEED_LLM[@]}"; do
    if [ -f "$WORK/old_r$i" ]; then
      if [ -f "$WORK/old_sha$i" ]; then
        # Strong match: content fingerprint
        local old_sha
        old_sha=$(cat "$WORK/old_sha$i")
        if [ "$old_sha" = "${SHA[$i]}" ]; then
          cp "$WORK/old_r$i" "$WORK/r$i"
          echo "  conflict $i: reused (fingerprint match)" >&2
          continue
        fi
      elif [ -f "$WORK/old_ours_n$i" ]; then
        # Weak match (bootstrap): line counts only (sha not yet recorded)
        local curr_on curr_bn curr_tn
        curr_on=$(wc -l < "$WORK/c${i}_ours")
        curr_bn=0; [ -f "$WORK/c${i}_base" ] && curr_bn=$(wc -l < "$WORK/c${i}_base")
        curr_tn=$(wc -l < "$WORK/c${i}_theirs")
        if [ "$curr_on" = "$(cat "$WORK/old_ours_n$i")" ] && \
           [ "$curr_bn" = "$(cat "$WORK/old_base_n$i")" ] && \
           [ "$curr_tn" = "$(cat "$WORK/old_theirs_n$i")" ]; then
          cp "$WORK/old_r$i" "$WORK/r$i"
          echo "  conflict $i: reused (count match, bootstrapping sha)" >&2
          continue
        fi
      fi
    fi
    STILL_NEED_LLM+=("$i")
  done
  [ ${#STILL_NEED_LLM[@]} -eq 0 ] && { _finish; return; }
  NEED_LLM=("${STILL_NEED_LLM[@]}")

  # Tier 1: Strategy classification (~5 output tokens per conflict)
  local CLASSIFY_INPUT="" STRATEGIES NUM STRATEGY REST NEED_GENERATE=()
  for i in "${NEED_LLM[@]}"; do
    CLASSIFY_INPUT+="=== CONFLICT $i ===
--- ours ---
$(cat "$WORK/c${i}_ours")
--- base ---
$(cat "$WORK/c${i}_base" 2>/dev/null || echo "(unavailable)")
--- theirs ---
$(cat "$WORK/c${i}_theirs")

"
  done

  STRATEGIES=$(printf '%s\n' "$CLASSIFY_INPUT" | pnpm --silent coworker:ask \
    -p "For each conflict, respond with ONLY the conflict number and one strategy per line:
N OURS       — keep ours (theirs is outdated/superseded)
N THEIRS     — keep theirs (ours is outdated/superseded)
N BOTH_OT    — concatenate ours then theirs
N BOTH_TO    — concatenate theirs then ours
N GENERATE   — needs custom merge
No explanations.")

  while IFS=' ' read -r NUM STRATEGY REST; do
    [[ "${NUM:-}" =~ ^[0-9]+$ ]] || continue
    case "$STRATEGY" in
      OURS)    cp "$WORK/c${NUM}_ours" "$WORK/r$NUM";   echo "  conflict $NUM: classified → OURS" >&2 ;;
      THEIRS)  cp "$WORK/c${NUM}_theirs" "$WORK/r$NUM"; echo "  conflict $NUM: classified → THEIRS" >&2 ;;
      BOTH_OT) cat "$WORK/c${NUM}_ours" "$WORK/c${NUM}_theirs" > "$WORK/r$NUM"; echo "  conflict $NUM: classified → BOTH (ours first)" >&2 ;;
      BOTH_TO) cat "$WORK/c${NUM}_theirs" "$WORK/c${NUM}_ours" > "$WORK/r$NUM"; echo "  conflict $NUM: classified → BOTH (theirs first)" >&2 ;;
      GENERATE) NEED_GENERATE+=("$NUM"); echo "  conflict $NUM: classified → GENERATE" >&2 ;;
      *) NEED_GENERATE+=("$NUM"); echo "  conflict $NUM: unrecognized '$STRATEGY', falling back to GENERATE" >&2 ;;
    esac
  done <<< "$STRATEGIES"

  [ ${#NEED_GENERATE[@]} -eq 0 ] && { _finish; return; }

  # Tier 2: Code generation (only for GENERATE conflicts — hunks only output)
  local GENERATE_INPUT="" GENERATED
  for i in "${NEED_GENERATE[@]}"; do
    GENERATE_INPUT+="=== CONFLICT $i ===
--- ours ---
$(cat "$WORK/c${i}_ours")
--- base ---
$(cat "$WORK/c${i}_base" 2>/dev/null || echo "(unavailable)")
--- theirs ---
$(cat "$WORK/c${i}_theirs")

"
  done

  GENERATED=$(printf '%s\n' "$GENERATE_INPUT" | pnpm --silent coworker:ask \
    -p "Merge each conflict meaningfully. Output '=== RESOLUTION N ===' header followed by ONLY the merged code. No explanations, no code fences.")

  printf '%s\n' "$GENERATED" | awk -v dir="$WORK" '
  /^=== RESOLUTION [0-9]+ ===$/ { if (f) close(f); f = dir "/r" $3; buf = ""; next }
  f && /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
  f { if (buf != "") { printf "%s", buf > f; buf = "" }; print > f }
  END { if (f) close(f) }
  '

  _finish
}

# Guard: abort if clone has pending work
if ! bash "$FORKER_DIR/status.sh" "$NAME" >/dev/null 2>&1; then
  bash "$FORKER_DIR/status.sh" "$NAME" >&2
  echo "" >&2
  echo "ERROR: $NAME has pending work that would be lost." >&2
  echo "Push with 'bash forks/forker/push.sh $NAME', commit, or remove the clone manually." >&2
  exit 1
fi

# Preserve local patches before wiping
LOCAL_PATCHES_TMP=""
if [ "$(count_glob "$REAL_PIN"/local-*.patch)" -gt 0 ]; then
  LOCAL_PATCHES_TMP=$(mktemp -d)
  cp "$REAL_PIN"/local-*.patch "$LOCAL_PATCHES_TMP/"
  echo "Preserved $(count_glob "$LOCAL_PATCHES_TMP"/local-*.patch) local patch(es)"
fi

# Preserve old resolutions for deterministic reuse on re-record
OLD_RES_TMP=""
if [ "$(count_glob "$REAL_PIN"/res-*.resolution)" -gt 0 ]; then
  OLD_RES_TMP=$(mktemp -d)
  cp "$REAL_PIN"/res-*.resolution "$OLD_RES_TMP/"
fi

# Build in a staging area (same filesystem → atomic mv)
WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
WORK_REPO="$WORK_DIR/clone"
WORK_PIN="$WORK_DIR/pin"
mkdir -p "$WORK_PIN"

# Export overrides so subprocesses (patch.sh) target the staging area
export _FORKER_WORK_REPO="$WORK_REPO"
export _FORKER_WORK_PIN="$WORK_PIN"
REPO_DIR="$WORK_REPO"
PIN_DIR="$WORK_PIN"

cleanup_on_error() {
  rm -rf "$WORK_DIR"
  [ -n "${OLD_RES_TMP:-}" ] && rm -rf "$OLD_RES_TMP"
  if [ -n "${LOCAL_PATCHES_TMP:-}" ] && [ -d "${LOCAL_PATCHES_TMP:-}" ]; then
    echo "FAILED — previous state is intact" >&2
    echo "Local patches preserved in: $LOCAL_PATCHES_TMP" >&2
  else
    echo "FAILED — previous state is intact" >&2
  fi
}
trap cleanup_on_error ERR

git clone --filter=blob:none "$UPSTREAM" "$REPO_DIR"

# Enable diff3 conflict markers so conflict resolution can see the base version.
# Force full 40-char SHAs in |||||| base markers so they're identical across runs
# (default core.abbrev varies with object count, breaking resolution replay).
git -C "$REPO_DIR" config merge.conflictStyle diff3
git -C "$REPO_DIR" config core.abbrev 40

# Capture default branch name and base SHA before any merges
DEFAULT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
BASE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" checkout -b wip

# Write manifest: base line first
printf '%s\t%s\n' "$BASE_SHA" "$DEFAULT_BRANCH" > "$PIN_DIR/manifest"

MERGE_IDX=0

for REF in "${REFS[@]}"; do
  MERGE_IDX=$((MERGE_IDX + 1))

  deterministic_env "$MERGE_IDX"

  # Case A: full (7-40 char) hex commit SHA
  if [[ $REF =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$REPO_DIR" fetch --depth=1 origin "$REF"
    MERGE_REF="FETCH_HEAD"

  # Case B: all digits → GitHub pull request number
  elif [[ $REF =~ ^[0-9]+$ ]]; then
    git -C "$REPO_DIR" fetch origin "pull/$REF/head:pr-$REF"
    MERGE_REF="pr-$REF"

  # Case C: branch name
  else
    git -C "$REPO_DIR" fetch origin "refs/heads/$REF:$REF"
    MERGE_REF="$REF"
  fi

  # Capture the resolved SHA for this ref before merging
  MERGE_SHA=$(git -C "$REPO_DIR" rev-parse "$MERGE_REF")

  # Append merge ref line to manifest
  printf '%s\t%s\n' "$MERGE_SHA" "$REF" >> "$PIN_DIR/manifest"

  # Use explicit merge message so record and replay produce identical commits
  MERGE_MSG="Merge $REF into wip"

  # Merge by SHA (not named ref or FETCH_HEAD) so conflict marker lines
  # (>>>>>>> <ref>) are identical between record and replay. Both use the
  # same pinned SHA, so counted resolutions apply with correct line counts.
  if ! git -C "$REPO_DIR" merge --no-ff -m "$MERGE_MSG" "$MERGE_SHA"; then
    # Capture conflicted file list BEFORE resolution
    mapfile -t CONFLICTED < <(git -C "$REPO_DIR" diff --name-only --diff-filter=U)

    # Determine old resolution file for this merge step (deterministic reuse)
    OLD_MERGE_RES=""
    if [ -n "${OLD_RES_TMP:-}" ] && [ -f "$OLD_RES_TMP/res-${MERGE_IDX}.resolution" ]; then
      OLD_MERGE_RES="$OLD_RES_TMP/res-${MERGE_IDX}.resolution"
    fi

    # Resolve conflicted files with AI Coworker (parallel, hunks-only)
    PIDS=()
    for FILE in "${CONFLICTED[@]}"; do
      resolve_conflict "$REPO_DIR/$FILE" "$FILE" "$OLD_MERGE_RES" \
        > "$REPO_DIR/${FILE}.resolved" &
      PIDS+=($!)
    done

    # Wait for all resolutions and check exit codes
    for i in "${!PIDS[@]}"; do
      if ! wait "${PIDS[$i]}"; then
        echo "ERROR: AI Coworker failed for ${CONFLICTED[$i]}" >&2
        exit 1
      fi
    done

    # Validate, apply resolutions, and collect per-file diffs
    for FILE in "${CONFLICTED[@]}"; do
      if [ ! -s "$REPO_DIR/${FILE}.resolved" ]; then
        echo "ERROR: AI Coworker returned empty resolution for $FILE" >&2
        exit 1
      fi
      if grep -q '<<<<<<<' "$REPO_DIR/${FILE}.resolved"; then
        echo "ERROR: Conflict markers remain in $FILE after resolution" >&2
        exit 1
      fi

      mv "$REPO_DIR/${FILE}.resolved" "$REPO_DIR/$FILE"
      git -C "$REPO_DIR" add "$FILE"

      # Append per-file resolution with path header (written by resolve_conflict)
      printf -- '--- %s\n' "$FILE" >> "$PIN_DIR/res-${MERGE_IDX}.resolution"
      cat "$REPO_DIR/${FILE}.resolution" >> "$PIN_DIR/res-${MERGE_IDX}.resolution"
      rm "$REPO_DIR/${FILE}.resolution"
    done

    # Overwrite MERGE_MSG so merge --continue uses our deterministic message
    echo "$MERGE_MSG" > "$REPO_DIR/.git/MERGE_MSG"
    GIT_EDITOR=true git -C "$REPO_DIR" merge --continue
  fi
done

bash "$FORKER_DIR/patch.sh" "$NAME" "$MERGE_IDX"

# Restore and apply local patches
if [ -n "${LOCAL_PATCHES_TMP:-}" ]; then
  cp "$LOCAL_PATCHES_TMP"/local-*.patch "$PIN_DIR/"
  rm -rf "$LOCAL_PATCHES_TMP"

  apply_local_patches "$REPO_DIR" "$PIN_DIR" || {
    echo "Upstream changes may have invalidated it. Edit or remove the patch and re-record." >&2
    exit 1
  }
fi

# Write HEAD file
HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
printf '%s\n' "$HEAD_SHA" > "$PIN_DIR/HEAD"

# Add fork remote for pushing (SSH for auth), if configured
FORK_REMOTE=$(fork_url "$NAME" 2>/dev/null) || true
if [ -n "${FORK_REMOTE:-}" ]; then
  git -C "$REPO_DIR" remote add fork "$FORK_REMOTE"
fi

# --- Atomic swap: move staging area to final location ---
unset _FORKER_WORK_REPO _FORKER_WORK_PIN
trap - ERR
rm -rf "$REAL_REPO" "$REAL_PIN"
mv "$WORK_REPO" "$REAL_REPO"
mv "$WORK_PIN" "$REAL_PIN"
rm -rf "$WORK_DIR"
[ -n "${OLD_RES_TMP:-}" ] && rm -rf "$OLD_RES_TMP"

REPO_DIR="$REAL_REPO"
PIN_DIR="$REAL_PIN"

# Regenerate fork workspace entries in pnpm-workspace.yaml
sync_workspace_yaml

LOCAL_PATCH_COUNT=$(count_glob "$PIN_DIR"/local-*.patch)
RESOLUTION_COUNT=$(count_glob "$PIN_DIR"/res-*.resolution)

echo "Pins recorded in .pin/$NAME/"
echo "  BASE=$BASE_SHA ($DEFAULT_BRANCH)"
echo "  Merges: $MERGE_IDX ref(s)"
if [ "$RESOLUTION_COUNT" -gt 0 ]; then
  echo "  Resolutions: $RESOLUTION_COUNT merge step(s) with conflicts"
else
  echo "  Resolutions: none (no conflicts)"
fi
if [ "$LOCAL_PATCH_COUNT" -gt 0 ]; then
  echo "  Local patches: $LOCAL_PATCH_COUNT"
fi
echo "  HEAD=$HEAD_SHA"
