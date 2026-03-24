#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NAME="${1:?Usage: forks/forker/record.sh <name> [ref ...]}"
shift

MODE=$(entry_mode "$NAME")
if [ "$MODE" != "managed" ]; then
  echo "ERROR: $NAME is a reference entry. Use 'bash forks/forker/update.sh $NAME'." >&2
  exit 1
fi

REAL_REPO="$FORKS_DIR/$NAME"
REAL_PIN="$FORKS_DIR/.pin/$NAME"
UPSTREAM=$(upstream_url "$NAME")

if [ $# -gt 0 ]; then
  REFS=("$@")
else
  mapfile -t REFS < <(repo_refs "$NAME")
fi

resolve_conflict() {
  local FILE="$1" F_REL="$2" OLD_RES="${3:-}"
  local COUNT WORK i OURS BASE THEIRS

  COUNT=$(awk 'substr($0,1,7)=="<<<<<<<"{n++} END{print n+0}' "$FILE")
  [ "$COUNT" -gt 0 ] || { echo "ERROR: no conflict markers in $FILE" >&2; return 1; }

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' RETURN

  awk -v dir="$WORK" '
  substr($0,1,7) == "<<<<<<<" { n++; section = "ours"; next }
  substr($0,1,7) == "|||||||" { section = "base";  next }
  substr($0,1,7) == "=======" { section = "theirs"; next }
  substr($0,1,7) == ">>>>>>>" { section = ""; next }
  section { print > (dir "/c" n "_" section) }
  ' "$FILE"

  for i in $(seq 1 "$COUNT"); do
    touch "$WORK/c${i}_ours" "$WORK/c${i}_base" "$WORK/c${i}_theirs"
  done

  local -a SHA=()
  # Fingerprint the full ours/base/theirs payload so a later re-record can
  # safely reuse an earlier resolution even if the surrounding file changed.
  for i in $(seq 1 "$COUNT"); do
    SHA[$i]=$({
      cat "$WORK/c${i}_ours"
      printf '%s\n' '---BOUNDARY---'
      cat "$WORK/c${i}_base" 2>/dev/null
      printf '%s\n' '---BOUNDARY---'
      cat "$WORK/c${i}_theirs"
    } | sha256sum | cut -d' ' -f1)
  done

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

  local NEED_COWORKER=()
  for i in $(seq 1 "$COUNT"); do
    OURS="$WORK/c${i}_ours"
    BASE="$WORK/c${i}_base"
    THEIRS="$WORK/c${i}_theirs"
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
      NEED_COWORKER+=("$i")
    fi
  done

  _finish() {
    local i ours_n base_n theirs_n res_n res_data

    for i in $(seq 1 "$COUNT"); do
      [ -f "$WORK/r$i" ] || { echo "ERROR: missing resolution for conflict $i in $FILE" >&2; return 1; }
    done

    res_data="$WORK/res_data"
    : > "$res_data"
    for i in $(seq 1 "$COUNT"); do
      ours_n=$(wc -l < "$WORK/c${i}_ours")
      base_n=0
      [ -f "$WORK/c${i}_base" ] && base_n=$(wc -l < "$WORK/c${i}_base")
      theirs_n=$(wc -l < "$WORK/c${i}_theirs")
      res_n=$(wc -l < "$WORK/r$i")
      printf 'CONFLICT ours=%d base=%d theirs=%d resolution=%d sha=%s\n' \
        "$ours_n" "$base_n" "$theirs_n" "$res_n" "${SHA[$i]}" >> "$res_data"
      cat "$WORK/r$i" >> "$res_data"
    done

    # Store line counts alongside the fingerprinted payload so replay can
    # reapply the recorded resolution without asking coworker again.
    apply_counted_resolutions "$res_data" "$FILE"
    cp "$res_data" "$FILE.resolution"
  }

  [ ${#NEED_COWORKER[@]} -eq 0 ] && { _finish; return; }

  local STILL_NEED_COWORKER=()
  for i in "${NEED_COWORKER[@]}"; do
    if [ -f "$WORK/old_r$i" ]; then
      if [ -f "$WORK/old_sha$i" ]; then
        local old_sha
        old_sha=$(cat "$WORK/old_sha$i")
        if [ "$old_sha" = "${SHA[$i]}" ]; then
          cp "$WORK/old_r$i" "$WORK/r$i"
          echo "  conflict $i: reused (fingerprint match)" >&2
          continue
        fi
      elif [ -f "$WORK/old_ours_n$i" ]; then
        local curr_on curr_bn curr_tn
        curr_on=$(wc -l < "$WORK/c${i}_ours")
        curr_bn=0
        [ -f "$WORK/c${i}_base" ] && curr_bn=$(wc -l < "$WORK/c${i}_base")
        curr_tn=$(wc -l < "$WORK/c${i}_theirs")
        if [ "$curr_on" = "$(cat "$WORK/old_ours_n$i")" ] \
          && [ "$curr_bn" = "$(cat "$WORK/old_base_n$i")" ] \
          && [ "$curr_tn" = "$(cat "$WORK/old_theirs_n$i")" ]; then
          cp "$WORK/old_r$i" "$WORK/r$i"
          echo "  conflict $i: reused (count match)" >&2
          continue
        fi
      fi
    fi
    STILL_NEED_COWORKER+=("$i")
  done

  [ ${#STILL_NEED_COWORKER[@]} -eq 0 ] && { _finish; return; }
  NEED_COWORKER=("${STILL_NEED_COWORKER[@]}")

  local CLASSIFY_INPUT="" STRATEGIES NUM STRATEGY REST NEED_GENERATE=()
  for i in "${NEED_COWORKER[@]}"; do
    CLASSIFY_INPUT+="=== CONFLICT $i ===
--- ours ---
$(cat "$WORK/c${i}_ours")
--- base ---
$(cat "$WORK/c${i}_base" 2>/dev/null || echo "(unavailable)")
--- theirs ---
$(cat "$WORK/c${i}_theirs")

"
  done

  # Ask coworker for a coarse strategy first so only the genuinely custom
  # cases fall through to full generated merge output.
  STRATEGIES=$(printf '%s\n' "$CLASSIFY_INPUT" | coworker_ask \
    "For each conflict, respond with ONLY the conflict number and one strategy per line:
N OURS       - keep ours (theirs is outdated or superseded)
N THEIRS     - keep theirs (ours is outdated or superseded)
N BOTH_OT    - concatenate ours then theirs
N BOTH_TO    - concatenate theirs then ours
N GENERATE   - needs custom merge
No explanations.")

  while IFS=' ' read -r NUM STRATEGY REST; do
    [[ "${NUM:-}" =~ ^[0-9]+$ ]] || continue
    case "$STRATEGY" in
      OURS)
        cp "$WORK/c${NUM}_ours" "$WORK/r$NUM"
        echo "  conflict $NUM: classified as OURS" >&2
        ;;
      THEIRS)
        cp "$WORK/c${NUM}_theirs" "$WORK/r$NUM"
        echo "  conflict $NUM: classified as THEIRS" >&2
        ;;
      BOTH_OT)
        cat "$WORK/c${NUM}_ours" "$WORK/c${NUM}_theirs" > "$WORK/r$NUM"
        echo "  conflict $NUM: classified as BOTH_OT" >&2
        ;;
      BOTH_TO)
        cat "$WORK/c${NUM}_theirs" "$WORK/c${NUM}_ours" > "$WORK/r$NUM"
        echo "  conflict $NUM: classified as BOTH_TO" >&2
        ;;
      GENERATE)
        NEED_GENERATE+=("$NUM")
        echo "  conflict $NUM: classified as GENERATE" >&2
        ;;
      *)
        NEED_GENERATE+=("$NUM")
        echo "  conflict $NUM: unrecognized strategy '$STRATEGY', using GENERATE" >&2
        ;;
    esac
  done <<< "$STRATEGIES"

  [ ${#NEED_GENERATE[@]} -eq 0 ] && { _finish; return; }

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

  GENERATED=$(printf '%s\n' "$GENERATE_INPUT" | coworker_ask \
    "Merge each conflict meaningfully. Output '=== RESOLUTION N ===' header followed by ONLY the merged code. No explanations, no code fences.")

  printf '%s\n' "$GENERATED" | awk -v dir="$WORK" '
  /^=== RESOLUTION [0-9]+ ===$/ { if (f) close(f); f = dir "/r" $3; buf = ""; next }
  f && /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
  f { if (buf != "") { printf "%s", buf > f; buf = "" }; print > f }
  END { if (f) close(f) }
  '

  _finish
}

if ! bash "$FORKER_DIR/status.sh" "$NAME" >/dev/null 2>&1; then
  bash "$FORKER_DIR/status.sh" "$NAME" >&2
  echo >&2
  echo "ERROR: $NAME has pending work that would be lost." >&2
  echo "Push with 'bash forks/forker/push.sh $NAME', commit, or remove the clone manually." >&2
  exit 1
fi

if has_legacy_local_patches "$REAL_PIN"; then
  echo "ERROR: $NAME still uses an unsupported legacy local patch layout. Delete and regenerate its pins first." >&2
  exit 1
fi

SERIES_TMP=""
if [ "$(saved_series_count "$REAL_PIN")" -gt 0 ]; then
  # Re-record rebuilds the managed base from upstream, but the saved local
  # commit series should survive unchanged and be reapplied afterward.
  SERIES_TMP=$(mktemp -d)
  copy_saved_series "$REAL_PIN" "$SERIES_TMP"
  echo "Preserved $(saved_series_count "$SERIES_TMP") saved series commit(s)"
fi

OLD_RES_TMP=""
if [ "$(count_glob "$REAL_PIN"/res-*.resolution)" -gt 0 ]; then
  OLD_RES_TMP=$(mktemp -d)
  cp "$REAL_PIN"/res-*.resolution "$OLD_RES_TMP/"
fi

WORK_DIR=$(mktemp -d "$FORKS_DIR/.work-${NAME}.XXXXXX")
WORK_REPO="$WORK_DIR/clone"
WORK_PIN="$WORK_DIR/pin"
mkdir -p "$WORK_PIN"

export _FORKER_WORK_REPO="$WORK_REPO"
export _FORKER_WORK_PIN="$WORK_PIN"
REPO_DIR="$WORK_REPO"
PIN_DIR="$WORK_PIN"

cleanup_staging() {
  rm -rf "$WORK_DIR"
  [ -n "${OLD_RES_TMP:-}" ] && rm -rf "$OLD_RES_TMP"
  if [ -n "${SERIES_TMP:-}" ] && [ -d "${SERIES_TMP:-}" ]; then
    echo "FAILED: previous state is intact" >&2
    echo "Saved series preserved in: $SERIES_TMP" >&2
  else
    echo "FAILED: previous state is intact" >&2
  fi
}
trap cleanup_staging EXIT

git clone --filter=blob:none "$UPSTREAM" "$REPO_DIR"

git -C "$REPO_DIR" config merge.conflictStyle diff3
git -C "$REPO_DIR" config core.abbrev 40

DEFAULT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
BASE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" checkout -b wip

printf '%s\t%s\n' "$BASE_SHA" "$DEFAULT_BRANCH" > "$PIN_DIR/manifest"

MERGE_IDX=0
for REF in "${REFS[@]}"; do
  MERGE_IDX=$((MERGE_IDX + 1))
  deterministic_env "$MERGE_IDX"

  if [[ $REF =~ ^[0-9a-f]{7,40}$ ]]; then
    git -C "$REPO_DIR" fetch --depth=1 origin "$REF"
    MERGE_REF="FETCH_HEAD"
  elif [[ $REF =~ ^[0-9]+$ ]]; then
    git -C "$REPO_DIR" fetch origin "pull/$REF/head:pr-$REF"
    MERGE_REF="pr-$REF"
  else
    git -C "$REPO_DIR" fetch origin "refs/heads/$REF:$REF"
    MERGE_REF="$REF"
  fi

  MERGE_SHA=$(git -C "$REPO_DIR" rev-parse "$MERGE_REF")
  printf '%s\t%s\n' "$MERGE_SHA" "$REF" >> "$PIN_DIR/manifest"

  MERGE_MSG="Merge $REF into wip"
  if ! git -C "$REPO_DIR" merge --no-ff -m "$MERGE_MSG" "$MERGE_SHA"; then
    mapfile -t CONFLICTED < <(git -C "$REPO_DIR" diff --name-only --diff-filter=U)

    OLD_MERGE_RES=""
    if [ -n "${OLD_RES_TMP:-}" ] && [ -f "$OLD_RES_TMP/res-${MERGE_IDX}.resolution" ]; then
      OLD_MERGE_RES="$OLD_RES_TMP/res-${MERGE_IDX}.resolution"
    fi

    PIDS=()
    for FILE in "${CONFLICTED[@]}"; do
      resolve_conflict "$REPO_DIR/$FILE" "$FILE" "$OLD_MERGE_RES" > "$REPO_DIR/${FILE}.resolved" &
      PIDS+=($!)
    done

    for i in "${!PIDS[@]}"; do
      if ! wait "${PIDS[$i]}"; then
        echo "ERROR: coworker failed for ${CONFLICTED[$i]}" >&2
        exit 1
      fi
    done

    for FILE in "${CONFLICTED[@]}"; do
      if [ ! -s "$REPO_DIR/${FILE}.resolved" ]; then
        echo "ERROR: coworker returned empty resolution for $FILE" >&2
        exit 1
      fi
      if grep -q '<<<<<<<' "$REPO_DIR/${FILE}.resolved"; then
        echo "ERROR: conflict markers remain in $FILE after resolution" >&2
        exit 1
      fi

      mv "$REPO_DIR/${FILE}.resolved" "$REPO_DIR/$FILE"
      git -C "$REPO_DIR" add "$FILE"

      printf -- '--- %s\n' "$FILE" >> "$PIN_DIR/res-${MERGE_IDX}.resolution"
      cat "$REPO_DIR/${FILE}.resolution" >> "$PIN_DIR/res-${MERGE_IDX}.resolution"
      rm "$REPO_DIR/${FILE}.resolution"
    done

    echo "$MERGE_MSG" > "$REPO_DIR/.git/MERGE_MSG"
    GIT_EDITOR=true git -C "$REPO_DIR" merge --continue
  fi
done

LOCAL_BASE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
# LOCAL_BASE is the exact replayed tip after manifest merges and recorded
# resolutions. The saved local series is always defined relative to this commit.
write_local_base "$PIN_DIR" "$LOCAL_BASE_SHA"

if [ -n "${SERIES_TMP:-}" ]; then
  copy_saved_series "$SERIES_TMP" "$PIN_DIR"
  rm -rf "$SERIES_TMP"

  apply_saved_series "$REPO_DIR" "$PIN_DIR" || {
    echo "Upstream changes may have invalidated the saved series. Rebuild or resave it before re-recording." >&2
    exit 1
  }
fi

HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
printf '%s\n' "$HEAD_SHA" > "$PIN_DIR/HEAD"

FORK_REMOTE=$(fork_url "$NAME" 2>/dev/null) || true
if [ -n "${FORK_REMOTE:-}" ]; then
  git -C "$REPO_DIR" remote add fork "$FORK_REMOTE"
fi

unset _FORKER_WORK_REPO _FORKER_WORK_PIN
trap - EXIT
mkdir -p "$FORKS_DIR/.pin"
rm -rf "$REAL_REPO" "$REAL_PIN"
mv "$WORK_REPO" "$REAL_REPO"
mv "$WORK_PIN" "$REAL_PIN"
rm -rf "$WORK_DIR"
[ -n "${OLD_RES_TMP:-}" ] && rm -rf "$OLD_RES_TMP"

PIN_DIR="$REAL_PIN"

LOCAL_SERIES_COUNT=$(saved_series_count "$PIN_DIR")
RESOLUTION_COUNT=$(count_glob "$PIN_DIR"/res-*.resolution)

echo "Pins recorded in .pin/$NAME/"
echo "  BASE=$BASE_SHA ($DEFAULT_BRANCH)"
echo "  Merges: $MERGE_IDX ref(s)"
echo "  Local base: $LOCAL_BASE_SHA"
if [ "$RESOLUTION_COUNT" -gt 0 ]; then
  echo "  Resolutions: $RESOLUTION_COUNT merge step(s) with conflicts"
else
  echo "  Resolutions: none (no conflicts)"
fi
if [ "$LOCAL_SERIES_COUNT" -gt 0 ]; then
  echo "  Saved series: $LOCAL_SERIES_COUNT commit(s)"
fi
echo "  HEAD=$HEAD_SHA"
