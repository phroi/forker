#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d)
trap 'chmod -R u+w "$ROOT" 2>/dev/null || true; rm -rf "$ROOT"' EXIT

TEST_ROOT="$ROOT/work"
FORKS_ROOT="$TEST_ROOT/forks"
FORKER_ROOT="$FORKS_ROOT/phroi_forker/repo"

NEXT_GIT_TIMESTAMP=1700000000

git_commit_with_next_timestamp() {
  local repo="$1"
  shift
  local ts="$NEXT_GIT_TIMESTAMP"
  NEXT_GIT_TIMESTAMP=$((NEXT_GIT_TIMESTAMP + 60))

  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
    git -C "$repo" commit "$@"
}

mkdir -p "$FORKER_ROOT"
SOURCE_FORKER="$(cd "$(dirname "$0")/.." && pwd)"
cp -a "$SOURCE_FORKER"/. "$FORKER_ROOT/"
chmod -R u+w "$FORKER_ROOT" || true
rm -rf "$FORKER_ROOT/.git"

CMD_OUTPUT=""
CMD_STATUS=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local message="$2"
  [ "$CMD_STATUS" -eq "$expected" ] || fail "$message (expected status $expected, got $CMD_STATUS)"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message"
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

run_cmd() {
  set +e
  CMD_OUTPUT=$("$@" 2>&1)
  CMD_STATUS=$?
  set -e
}

create_upstream() {
  local name="$1"
  local branch="$2"
  local work="$ROOT/src-$name"
  local bare="$ROOT/$name.git"

  git init "$work" >/dev/null 2>&1
  git -C "$work" config user.email ci@example.com
  git -C "$work" config user.name ci
  printf '%s\n' "$name base" > "$work/README.md"
  git -C "$work" add README.md
  git_commit_with_next_timestamp "$work" -m "init" >/dev/null 2>&1
  git -C "$work" branch -M "$branch"

  git init --bare "$bare" >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin "$branch" >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"

  printf '%s\t%s\n' "$work" "$bare"
}

append_commit() {
  local work="$1"
  local branch="$2"
  local file="$3"
  local text="$4"

  printf '%s\n' "$text" >> "$work/$file"
  git -C "$work" add "$file"
  git_commit_with_next_timestamp "$work" -m "update $file" >/dev/null 2>&1
  git -C "$work" push origin "$branch" >/dev/null 2>&1
}

create_branch_commit() {
  local work="$1"
  local base_branch="$2"
  local new_branch="$3"
  local file="$4"
  local text="$5"

  git -C "$work" checkout -b "$new_branch" "$base_branch" >/dev/null 2>&1
  printf '%s\n' "$text" >> "$work/$file"
  git -C "$work" add "$file"
  git_commit_with_next_timestamp "$work" -m "branch $new_branch" >/dev/null 2>&1
  git -C "$work" push -u origin "$new_branch" >/dev/null 2>&1
  git -C "$work" checkout "$base_branch" >/dev/null 2>&1
}

create_repo_from_dir() {
  local source_dir="$1"
  local name="$2"
  local branch="$3"
  local work="$ROOT/src-$name"
  local bare="$ROOT/$name.git"

  mkdir -p "$work"
  cp -a "$source_dir"/. "$work/"
  rm -rf "$work/.git"

  git init "$work" >/dev/null 2>&1
  git -C "$work" config user.email ci@example.com
  git -C "$work" config user.name ci
  git -C "$work" add .
  git_commit_with_next_timestamp "$work" -m "init" >/dev/null 2>&1
  git -C "$work" branch -M "$branch"

  git init --bare "$bare" >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin "$branch" >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"

  printf '%s\t%s\n' "$work" "$bare"
}

init_git_root() {
  local root="$1"

  mkdir -p "$root"
  git init "$root" >/dev/null 2>&1
  git -C "$root" config user.email ci@example.com
  git -C "$root" config user.name ci
}

IFS=$'\t' read -r REF_WORK REF_BARE <<< "$(create_upstream reference-upstream main)"
IFS=$'\t' read -r MANAGED_WORK MANAGED_BARE <<< "$(create_upstream managed-upstream main)"
IFS=$'\t' read -r MERGED_WORK MERGED_BARE <<< "$(create_upstream merged-upstream main)"
IFS=$'\t' read -r BOOT_WORK BOOT_BARE <<< "$(create_upstream bootstrap-upstream main)"
IFS=$'\t' read -r BOOT_REFS_WORK BOOT_REFS_BARE <<< "$(create_upstream bootstrap-refs-upstream main)"
IFS=$'\t' read -r BRANCHY_REF_WORK BRANCHY_REF_BARE <<< "$(create_upstream branchy-reference-upstream main)"
IFS=$'\t' read -r CONVERT_REF_WORK CONVERT_REF_BARE <<< "$(create_upstream convertible-reference-upstream main)"
create_branch_commit "$BOOT_REFS_WORK" main feature README.md 'feature branch content'
create_branch_commit "$BRANCHY_REF_WORK" main dev README.md 'branchy dev content'
create_branch_commit "$CONVERT_REF_WORK" main dev README.md 'convertible dev content'

cat > "$FORKS_ROOT/config.json" <<JSON
{
  "managed": {
    "upstream": "file://$MANAGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "merged": {
    "upstream": "file://$MERGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "bootstrap": {
    "upstream": "file://$BOOT_BARE",
    "mode": "managed",
    "refs": []
  },
  "bootstrap_refs": {
    "upstream": "file://$BOOT_REFS_BARE",
    "mode": "managed",
    "refs": ["feature"]
  },
  "reference": {
    "upstream": "file://$REF_BARE",
    "mode": "reference"
  },
  "branchy_reference": {
    "upstream": "file://$BRANCHY_REF_BARE",
    "mode": "reference"
  },
  "convertible_reference": {
    "upstream": "file://$CONVERT_REF_BARE",
    "mode": "reference"
  }
}
JSON

run_cmd bash "$FORKER_ROOT/health.sh"
assert_status 0 "health.sh should succeed on clean test setup"
assert_contains "$CMD_OUTPUT" $'summary\tok=' "health.sh should print a summary line"
assert_contains "$CMD_OUTPUT" $'\terror=0' "health.sh should report zero errors"
assert_contains "$CMD_OUTPUT" $'\twarn=11\t' "health.sh should report the extra managed entry warnings"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
FORKS_DIR="$2"
acquire_entry_lock managed
false
' _ "$FORKER_ROOT" "$FORKS_ROOT"
assert_status 1 "acquire_entry_lock should still release the lock on shell exit"
[ ! -d "$FORKS_ROOT/.lock/managed.lock" ] || fail "acquire_entry_lock should not leak locks after set -e exits"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
FORKS_DIR="$2"
acquire_entry_lock managed
release_entry_lock managed
mkdir -p "$(entry_lock_dir managed)"
' _ "$FORKER_ROOT" "$FORKS_ROOT"
assert_status 0 "release_entry_lock should succeed before shell exit"
[ -d "$FORKS_ROOT/.lock/managed.lock" ] || fail "release_entry_lock should unregister EXIT cleanup before another process reacquires the lock"
rm -rf "$FORKS_ROOT/.lock/managed.lock"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
FORKS_DIR="$2"
reset_stage_entry managed
false
' _ "$FORKER_ROOT" "$FORKS_ROOT"
assert_status 1 "reset_stage_entry should still clean staged entries on shell exit"
[ ! -d "$FORKS_ROOT/.stage/managed" ] || fail "reset_stage_entry should not leak staged entries after set -e exits"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
FORKS_DIR="$2"
reset_stage_entry managed
cleanup_stage_entry managed
mkdir -p "$(stage_entry_dir managed)"
' _ "$FORKER_ROOT" "$FORKS_ROOT"
assert_status 0 "cleanup_stage_entry should succeed before shell exit"
[ -d "$FORKS_ROOT/.stage/managed" ] || fail "cleanup_stage_entry should unregister EXIT cleanup before staged entries are recreated"
rm -rf "$FORKS_ROOT/.stage/managed"

BOOTSTRAP_WORKSPACE_ROOT="$ROOT/bootstrap-workspace"
BOOTSTRAP_WORKSPACE_FORKS="$BOOTSTRAP_WORKSPACE_ROOT/forks"
BOOTSTRAP_WORKSPACE_FORKER="$BOOTSTRAP_WORKSPACE_FORKS/phroi_forker/repo"

mkdir -p "$BOOTSTRAP_WORKSPACE_FORKER"
cp -a "$SOURCE_FORKER"/. "$BOOTSTRAP_WORKSPACE_FORKER/"
chmod -R u+w "$BOOTSTRAP_WORKSPACE_FORKER" || true
rm -rf "$BOOTSTRAP_WORKSPACE_FORKER/.git"

IFS=$'\t' read -r _ PHROI_FORKER_BARE <<< "$(create_repo_from_dir "$SOURCE_FORKER" bootstrap-workspace-forker master)"
IFS=$'\t' read -r _ BOOTSTRAP_WORKSPACE_REF_BARE <<< "$(create_upstream bootstrap-workspace-reference main)"
IFS=$'\t' read -r _ BOOTSTRAP_WORKSPACE_MANAGED_BARE <<< "$(create_upstream bootstrap-workspace-managed main)"

cat > "$BOOTSTRAP_WORKSPACE_FORKS/config.json" <<JSON
{
  "phroi_forker": {
    "upstream": "file://$PHROI_FORKER_BARE",
    "mode": "managed",
    "refs": []
  },
  "managed": {
    "upstream": "file://$BOOTSTRAP_WORKSPACE_MANAGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "reference": {
    "upstream": "file://$BOOTSTRAP_WORKSPACE_REF_BARE",
    "mode": "reference"
  }
}
JSON

rm -rf "$BOOTSTRAP_WORKSPACE_FORKS/managed/repo" "$BOOTSTRAP_WORKSPACE_FORKS/reference"

run_cmd bash "$BOOTSTRAP_WORKSPACE_FORKER/materialize-workspace.sh"
assert_status 0 "materialize-workspace.sh should populate the rest of forks when phroi_forker is already present"
assert_contains "$CMD_OUTPUT" $'summary\tupdated=0\tcloned=1\tunchanged=0\tskipped=0\tfailed=0' "materialize-workspace.sh should sync reference entries"
assert_contains "$CMD_OUTPUT" $'summary\tderived=2\tskipped=0\tfailed=0' "materialize-workspace.sh should derive missing managed pins before materializing"
assert_contains "$CMD_OUTPUT" $'summary\tmaterialized=0\tskipped=2\tfailed=0' "materialize-workspace.sh should skip managed clones once upstream pin bootstrap published them"
[ -d "$BOOTSTRAP_WORKSPACE_FORKS/phroi_forker/repo/.git" ] || fail "materialize-workspace.sh should preserve an existing managed phroi_forker clone"
[ -d "$BOOTSTRAP_WORKSPACE_FORKS/reference/repo/.git" ] || fail "materialize-workspace.sh should clone missing reference entries"
[ -d "$BOOTSTRAP_WORKSPACE_FORKS/managed/repo/.git" ] || fail "materialize-workspace.sh should materialize missing managed entries"

BOOTSTRAP_REFERENCE_ROOT="$ROOT/bootstrap-workspace-reference"
BOOTSTRAP_REFERENCE_FORKS="$BOOTSTRAP_REFERENCE_ROOT/forks"
BOOTSTRAP_REFERENCE_FORKER="$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/repo"

mkdir -p "$BOOTSTRAP_REFERENCE_FORKER"
cp -a "$SOURCE_FORKER"/. "$BOOTSTRAP_REFERENCE_FORKER/"
chmod -R u+w "$BOOTSTRAP_REFERENCE_FORKER" || true
rm -rf "$BOOTSTRAP_REFERENCE_FORKER/.git"

IFS=$'\t' read -r _ PHROI_FORKER_REF_BARE <<< "$(create_repo_from_dir "$SOURCE_FORKER" bootstrap-workspace-reference-forker master)"
IFS=$'\t' read -r _ BOOTSTRAP_REFERENCE_REF_BARE <<< "$(create_upstream bootstrap-workspace-reference-only main)"
IFS=$'\t' read -r _ BOOTSTRAP_REFERENCE_MANAGED_BARE <<< "$(create_upstream bootstrap-workspace-reference-managed main)"

cat > "$BOOTSTRAP_REFERENCE_FORKS/config.json" <<JSON
{
  "phroi_forker": {
    "upstream": "file://$PHROI_FORKER_REF_BARE",
    "mode": "reference"
  },
  "managed": {
    "upstream": "file://$BOOTSTRAP_REFERENCE_MANAGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "reference": {
    "upstream": "file://$BOOTSTRAP_REFERENCE_REF_BARE",
    "mode": "reference"
  }
}
JSON

rm -rf "$BOOTSTRAP_REFERENCE_FORKS/managed/repo" "$BOOTSTRAP_REFERENCE_FORKS/reference"

run_cmd bash "$BOOTSTRAP_REFERENCE_FORKER/materialize-workspace.sh"
assert_status 0 "materialize-workspace.sh should bootstrap when phroi_forker is configured as a reference entry"
assert_contains "$CMD_OUTPUT" $'summary\tupdated=0\tcloned=2\tunchanged=0\tskipped=0\tfailed=0' "materialize-workspace.sh should sync phroi_forker and other missing reference entries"
assert_contains "$CMD_OUTPUT" $'summary\tderived=1\tskipped=0\tfailed=0' "materialize-workspace.sh should derive missing managed pins in reference mode"
assert_contains "$CMD_OUTPUT" $'summary\tmaterialized=0\tskipped=1\tfailed=0' "materialize-workspace.sh should skip managed clones after deriving pins in reference mode"
[ -d "$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/repo/.git" ] || fail "materialize-workspace.sh should materialize a reference-configured phroi_forker clone"
[ ! -w "$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/repo/README.md" ] || fail "materialize-workspace.sh should leave a reference-configured phroi_forker clone read-only"
[ -d "$BOOTSTRAP_REFERENCE_FORKS/reference/repo/.git" ] || fail "materialize-workspace.sh should still clone other reference entries in reference mode"
[ -d "$BOOTSTRAP_REFERENCE_FORKS/managed/repo/.git" ] || fail "materialize-workspace.sh should still materialize managed entries in reference mode"

run_cmd bash "$BOOTSTRAP_REFERENCE_FORKER/reference-to-managed.sh" phroi_forker
assert_status 0 "reference-to-managed.sh should convert phroi_forker itself on hosts without mv --exchange"
assert_contains "$CMD_OUTPUT" 'phroi_forker: converted to managed with base_branch=master' "reference-to-managed.sh should preserve the tool repo primary branch during self-conversion"
assert_equals "$(jq -r '.phroi_forker.mode' "$BOOTSTRAP_REFERENCE_FORKS/config.json")" 'managed' "reference-to-managed.sh should rewrite phroi_forker to managed mode"
assert_equals "$(jq -r '.phroi_forker.base_branch' "$BOOTSTRAP_REFERENCE_FORKS/config.json")" 'master' "reference-to-managed.sh should record phroi_forker base_branch during self-conversion"
assert_equals "$(jq -c '.phroi_forker.refs' "$BOOTSTRAP_REFERENCE_FORKS/config.json")" '[]' "reference-to-managed.sh should keep phroi_forker refs explicit after self-conversion"
[ -d "$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/pin" ] || fail "reference-to-managed.sh should create pin state when phroi_forker converts itself"
assert_equals "$(git -C "$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/repo" branch --show-current)" 'wip' "reference-to-managed.sh should leave phroi_forker on wip after self-conversion"
[ -w "$BOOTSTRAP_REFERENCE_FORKS/phroi_forker/repo/README.md" ] || fail "reference-to-managed.sh should leave self-converted phroi_forker writable"

BOOTSTRAP_SCRATCH_ROOT="$ROOT/bootstrap-workspace-scratch"
BOOTSTRAP_SCRATCH_FORKS="$BOOTSTRAP_SCRATCH_ROOT/forks"
BOOTSTRAP_SCRATCH_FORKER="$BOOTSTRAP_SCRATCH_ROOT/.scratch/forker/repo"

mkdir -p "$BOOTSTRAP_SCRATCH_FORKER"
cp -a "$SOURCE_FORKER"/. "$BOOTSTRAP_SCRATCH_FORKER/"
chmod -R u+w "$BOOTSTRAP_SCRATCH_FORKER" || true
rm -rf "$BOOTSTRAP_SCRATCH_FORKER/.git"

IFS=$'\t' read -r _ BOOTSTRAP_SCRATCH_REF_BARE <<< "$(create_upstream bootstrap-workspace-scratch-reference main)"
IFS=$'\t' read -r _ BOOTSTRAP_SCRATCH_MANAGED_BARE <<< "$(create_upstream bootstrap-workspace-scratch-managed main)"

mkdir -p "$BOOTSTRAP_SCRATCH_FORKS"
cat > "$BOOTSTRAP_SCRATCH_FORKS/config.json" <<JSON
{
  "managed": {
    "upstream": "file://$BOOTSTRAP_SCRATCH_MANAGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "reference": {
    "upstream": "file://$BOOTSTRAP_SCRATCH_REF_BARE",
    "mode": "reference"
  }
}
JSON

rm -rf "$BOOTSTRAP_SCRATCH_FORKS/managed/repo" "$BOOTSTRAP_SCRATCH_FORKS/reference"

run_cmd bash "$BOOTSTRAP_SCRATCH_FORKER/materialize-workspace.sh"
assert_status 0 "materialize-workspace.sh should work from a scratch clone outside forks/"
assert_contains "$CMD_OUTPUT" $'summary\tupdated=0\tcloned=1\tunchanged=0\tskipped=0\tfailed=0' "materialize-workspace.sh should still sync reference entries from a scratch clone"
assert_contains "$CMD_OUTPUT" $'summary\tderived=1\tskipped=0\tfailed=0' "materialize-workspace.sh should derive missing managed pins from a scratch clone"
assert_contains "$CMD_OUTPUT" $'summary\tmaterialized=0\tskipped=1\tfailed=0' "materialize-workspace.sh should skip managed clones after deriving pins from a scratch clone"
[ -d "$BOOTSTRAP_SCRATCH_FORKS/reference/repo/.git" ] || fail "materialize-workspace.sh should clone reference entries from a scratch tool checkout"
[ -d "$BOOTSTRAP_SCRATCH_FORKS/managed/repo/.git" ] || fail "materialize-workspace.sh should materialize managed entries from a scratch tool checkout"

BOOTSTRAP_SHIM_EMPTY_ROOT="$ROOT/bootstrap-shim-empty"
BOOTSTRAP_SHIM_EMPTY_FORKS="$BOOTSTRAP_SHIM_EMPTY_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_EMPTY_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_EMPTY_ROOT/apps/demo"

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$PHROI_FORKER_BARE" bash -c 'set -euo pipefail
cd "$1/apps/demo"
bash < "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_EMPTY_ROOT" "$SOURCE_FORKER"
assert_status 0 "bootstrap.sh should seed and bootstrap a zero-data repo"
assert_equals "$(jq -r '.phroi_forker.mode' "$BOOTSTRAP_SHIM_EMPTY_FORKS/config.json")" 'reference' "bootstrap.sh should seed phroi_forker as a reference entry"
assert_equals "$(jq -r '.phroi_forker.upstream' "$BOOTSTRAP_SHIM_EMPTY_FORKS/config.json")" "file://$PHROI_FORKER_BARE" "bootstrap.sh should seed the configured tool upstream"
[ -d "$BOOTSTRAP_SHIM_EMPTY_FORKS/phroi_forker/repo/.git" ] || fail "bootstrap.sh should materialize the phroi_forker reference clone"
[ ! -w "$BOOTSTRAP_SHIM_EMPTY_FORKS/phroi_forker/repo/README.md" ] || fail "bootstrap.sh should leave bootstrapped reference clones read-only"
[ ! -d "$BOOTSTRAP_SHIM_EMPTY_FORKS/.stage/bootstrap-phroi_forker" ] || fail "bootstrap.sh should clean its temporary bootstrap checkout on success"
assert_contains "$(cat "$BOOTSTRAP_SHIM_EMPTY_FORKS/.gitignore")" '*/repo/' "bootstrap.sh should ensure forks/.gitignore ignores live clones"

BOOTSTRAP_SHIM_GITIGNORE_ROOT="$ROOT/bootstrap-shim-gitignore"
BOOTSTRAP_SHIM_GITIGNORE_FORKS="$BOOTSTRAP_SHIM_GITIGNORE_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_GITIGNORE_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_GITIGNORE_FORKS"
printf '%s' 'custom-rule' > "$BOOTSTRAP_SHIM_GITIGNORE_FORKS/.gitignore"

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$PHROI_FORKER_BARE" bash -c 'set -euo pipefail
cd "$1"
bash "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_GITIGNORE_ROOT" "$SOURCE_FORKER"
assert_status 0 "bootstrap.sh should preserve existing gitignore lines without a trailing newline"
grep -Fqx 'custom-rule' "$BOOTSTRAP_SHIM_GITIGNORE_FORKS/.gitignore" || fail "bootstrap.sh should preserve the last pre-existing gitignore rule"
grep -Fqx '*/repo/' "$BOOTSTRAP_SHIM_GITIGNORE_FORKS/.gitignore" || fail "bootstrap.sh should add the repo ignore rule after a missing trailing newline"

BOOTSTRAP_SHIM_EXISTING_ROOT="$ROOT/bootstrap-shim-existing"
BOOTSTRAP_SHIM_EXISTING_FORKS="$BOOTSTRAP_SHIM_EXISTING_ROOT/forks"
IFS=$'\t' read -r _ BOOTSTRAP_SHIM_REF_BARE <<< "$(create_upstream bootstrap-shim-reference main)"
IFS=$'\t' read -r _ BOOTSTRAP_SHIM_MANAGED_BARE <<< "$(create_upstream bootstrap-shim-managed main)"

init_git_root "$BOOTSTRAP_SHIM_EXISTING_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_EXISTING_FORKS"
cat > "$BOOTSTRAP_SHIM_EXISTING_FORKS/config.json" <<JSON
{
  "managed": {
    "upstream": "file://$BOOTSTRAP_SHIM_MANAGED_BARE",
    "mode": "managed",
    "refs": []
  },
  "reference": {
    "upstream": "file://$BOOTSTRAP_SHIM_REF_BARE",
    "mode": "reference"
  }
}
JSON

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$PHROI_FORKER_BARE" bash -c 'set -euo pipefail
cd "$1"
bash "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_EXISTING_ROOT" "$SOURCE_FORKER"
assert_status 0 "bootstrap.sh should add phroi_forker and bootstrap existing fork configs"
assert_equals "$(jq -r '.phroi_forker.mode' "$BOOTSTRAP_SHIM_EXISTING_FORKS/config.json")" 'reference' "bootstrap.sh should add phroi_forker as a reference entry"
if jq -e '.phroi_forker | has("fork") or has("refs") or has("base_branch")' "$BOOTSTRAP_SHIM_EXISTING_FORKS/config.json" >/dev/null 2>&1; then
  fail "bootstrap.sh should add only minimal phroi_forker fields"
fi
assert_contains "$CMD_OUTPUT" $'summary\tderived=1\tskipped=0\tfailed=0' "bootstrap.sh should derive missing managed pins through materialize-workspace.sh"
[ -f "$BOOTSTRAP_SHIM_EXISTING_FORKS/managed/pin/HEAD" ] || fail "bootstrap.sh should derive managed pin state"
[ -d "$BOOTSTRAP_SHIM_EXISTING_FORKS/managed/repo/.git" ] || fail "bootstrap.sh should materialize managed repos"
[ -d "$BOOTSTRAP_SHIM_EXISTING_FORKS/reference/repo/.git" ] || fail "bootstrap.sh should materialize reference repos"
[ -d "$BOOTSTRAP_SHIM_EXISTING_FORKS/phroi_forker/repo/.git" ] || fail "bootstrap.sh should materialize the tool clone"

BOOTSTRAP_SHIM_INVALID_ROOT="$ROOT/bootstrap-shim-invalid"
BOOTSTRAP_SHIM_INVALID_FORKS="$BOOTSTRAP_SHIM_INVALID_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_INVALID_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_INVALID_FORKS"
cat > "$BOOTSTRAP_SHIM_INVALID_FORKS/config.json" <<JSON
{
  "broken": {
    "upstream": "file://$BOOTSTRAP_SHIM_MANAGED_BARE"
  }
}
JSON

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$PHROI_FORKER_BARE" bash -c 'set -euo pipefail
cd "$1"
bash "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_INVALID_ROOT" "$SOURCE_FORKER"
assert_status 1 "bootstrap.sh should reject configs without explicit modes"
assert_contains "$CMD_OUTPUT" 'all forks/config.json entries must declare mode=managed or mode=reference' "bootstrap.sh should explain invalid mode configuration"
[ ! -d "$BOOTSTRAP_SHIM_INVALID_FORKS/.stage/bootstrap-phroi_forker" ] || fail "bootstrap.sh should clean its temporary bootstrap checkout on failure"

BOOTSTRAP_SHIM_ARRAY_ROOT="$ROOT/bootstrap-shim-array"
BOOTSTRAP_SHIM_ARRAY_FORKS="$BOOTSTRAP_SHIM_ARRAY_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_ARRAY_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_ARRAY_FORKS"
printf '%s\n' '[]' > "$BOOTSTRAP_SHIM_ARRAY_FORKS/config.json"

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$PHROI_FORKER_BARE" bash -c 'set -euo pipefail
cd "$1"
bash "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_ARRAY_ROOT" "$SOURCE_FORKER"
assert_status 1 "bootstrap.sh should reject non-object config JSON"
assert_contains "$CMD_OUTPUT" 'must be a JSON object' "bootstrap.sh should explain non-object config JSON"

BOOTSTRAP_SHIM_CLONE_FAIL_ROOT="$ROOT/bootstrap-shim-clone-fail"
BOOTSTRAP_SHIM_CLONE_FAIL_FORKS="$BOOTSTRAP_SHIM_CLONE_FAIL_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_CLONE_FAIL_ROOT"

run_cmd env FORKER_BOOTSTRAP_UPSTREAM="file://$ROOT/does-not-exist.git" bash -c 'set -euo pipefail
cd "$1"
bash "$2/bootstrap.sh"' _ "$BOOTSTRAP_SHIM_CLONE_FAIL_ROOT" "$SOURCE_FORKER"
assert_status 1 "bootstrap.sh should fail clearly when the bootstrap tool clone fails"
assert_contains "$CMD_OUTPUT" 'could not clone phroi_forker from' "bootstrap.sh should report the failing phroi_forker upstream"
assert_contains "$CMD_OUTPUT" 'fatal:' "bootstrap.sh should preserve git clone stderr on bootstrap clone failure"
[ ! -d "$BOOTSTRAP_SHIM_CLONE_FAIL_FORKS/.stage/bootstrap-phroi_forker" ] || fail "bootstrap.sh should clean the bootstrap staging dir after clone failures"

BOOTSTRAP_SHIM_CONFIG_TMP_ROOT="$ROOT/bootstrap-shim-config-tmp"
BOOTSTRAP_SHIM_CONFIG_TMP_FORKS="$BOOTSTRAP_SHIM_CONFIG_TMP_ROOT/forks"

init_git_root "$BOOTSTRAP_SHIM_CONFIG_TMP_ROOT"
mkdir -p "$BOOTSTRAP_SHIM_CONFIG_TMP_FORKS"
cat > "$BOOTSTRAP_SHIM_CONFIG_TMP_FORKS/config.json" <<JSON
{
  "reference": {
    "upstream": "file://$BOOTSTRAP_SHIM_REF_BARE",
    "mode": "reference"
  }
}
JSON

run_cmd bash -c 'set -euo pipefail
source "$1/bootstrap.sh"
trap cleanup_bootstrap_temp EXIT
mv() {
  return 1
}
ensure_config "$2/forks/config.json"' _ "$SOURCE_FORKER" "$BOOTSTRAP_SHIM_CONFIG_TMP_ROOT"
assert_status 1 "bootstrap.sh should fail when config replacement cannot be published"
if compgen -G "$BOOTSTRAP_SHIM_CONFIG_TMP_FORKS/config.json.tmp.*" >/dev/null; then
  fail "bootstrap.sh should clean config temp files after config replacement failures"
fi

CUSTOM_LAYOUT_FORKS="$ROOT/custom-layout/phroi-worktrees"
CUSTOM_LAYOUT_FORKER="$CUSTOM_LAYOUT_FORKS/phroi_forker/repo"

mkdir -p "$CUSTOM_LAYOUT_FORKER"
cp -a "$SOURCE_FORKER"/. "$CUSTOM_LAYOUT_FORKER/"
chmod -R u+w "$CUSTOM_LAYOUT_FORKER" || true
rm -rf "$CUSTOM_LAYOUT_FORKER/.git"
printf '{}\n' > "$CUSTOM_LAYOUT_FORKS/config.json"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
printf "%s\n" "$TOOL_REL"' _ "$CUSTOM_LAYOUT_FORKER"
assert_status 0 "lib.sh should resolve TOOL_REL from a custom forks directory name"
assert_equals "$CMD_OUTPUT" 'phroi-worktrees/phroi_forker/repo' "lib.sh should use the discovered forks directory basename in TOOL_REL"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
source "$1/workflow-lib.sh"
coworker_ask() {
  cat >/dev/null
  if [[ "$1" == For\ each\ conflict* ]]; then
    printf "%s\n" "1 GENERATE"
  else
    printf "=== RESOLUTION 1 ===\nmerged line\n\n"
  fi
}
file=$(mktemp)
actual=$(mktemp)
expected=$(mktemp)
cat > "$file" <<'"'"'EOF'"'"'
<<<<<<< ours
ours line
||||||| base
base line
=======
theirs line
>>>>>>> theirs
EOF
printf "merged line\n\n" > "$expected"
resolve_conflict "$file" sample.txt > "$actual"
cmp -s "$actual" "$expected"
grep -q "resolution=2" "$file.resolution"' bash "$FORKER_ROOT"
assert_status 0 "resolve_conflict should preserve generated trailing blank lines in recorded resolutions"

run_cmd bash -c 'set -euo pipefail
source "$1/lib.sh"
source "$1/workflow-lib.sh"
coworker_ask() {
  cat >/dev/null
  if [[ "$1" == For\ each\ conflict* ]]; then
    printf "%s\n" "1 GENERATE"
  else
    printf "=== RESOLUTION 1 ===\nmerged line"
  fi
}
file=$(mktemp)
cat > "$file" <<'"'"'EOF'"'"'
<<<<<<< ours
ours line
||||||| base
base line
=======
theirs line
>>>>>>> theirs
EOF
resolve_conflict "$file" sample.txt > "$file.resolved"
grep -q "^merged line$" "$file.resolved"
grep -q "resolution=1" "$file.resolution"' bash "$FORKER_ROOT"
assert_status 0 "resolve_conflict should count lines correctly without a final newline"

run_cmd bash "$FORKER_ROOT/sync-reference.sh" reference
assert_status 0 "sync-reference.sh should clone a missing reference entry"
assert_contains "$CMD_OUTPUT" $'reference\tcloned\t-\t' "sync-reference.sh should report a clone"

run_cmd bash "$FORKER_ROOT/state.sh" reference
assert_status 0 "state.sh should accept a clean reference clone"
[ ! -w "$FORKS_ROOT/reference/repo/README.md" ] || fail "sync-reference.sh should leave reference clones read-only"
assert_contains "$CMD_OUTPUT" 'reference clone matches primary origin/main' "state.sh should report a clean reference clone"
assert_contains "$CMD_OUTPUT" 'readonly     yes' "state.sh should report read-only reference clones"

run_cmd bash "$FORKER_ROOT/rebuild-pins.sh" reference
assert_status 1 "rebuild-pins.sh should refuse reference entries"
assert_contains "$CMD_OUTPUT" "Use 'bash forks/phroi_forker/repo/sync-reference.sh reference'." "rebuild-pins.sh should explain its reference-entry scope"

append_commit "$REF_WORK" main README.md 'remote update'

OLD_REF_SHA=$(git -C "$FORKS_ROOT/reference/repo" rev-parse HEAD)
run_cmd bash "$FORKER_ROOT/sync-reference.sh" reference
assert_status 0 "sync-reference.sh should refresh a clean reference clone"
assert_contains "$CMD_OUTPUT" $'reference\tupdated\t' "sync-reference.sh should report an update"
NEW_REF_SHA=$(git -C "$FORKS_ROOT/reference/repo" rev-parse HEAD)
[ "$OLD_REF_SHA" != "$NEW_REF_SHA" ] || fail "reference clone should move to a new commit"
[ ! -w "$FORKS_ROOT/reference/repo/README.md" ] || fail "sync-reference.sh should relock reference clones after updating"

chmod -R u+w "$FORKS_ROOT/reference/repo"
printf '%s\n' 'stash-only change' >> "$FORKS_ROOT/reference/repo/README.md"
git -C "$FORKS_ROOT/reference/repo" stash push --include-untracked -m temp >/dev/null 2>&1
run_cmd bash "$FORKER_ROOT/state.sh" reference
assert_status 1 "state.sh should surface stash-only reference state"
assert_contains "$CMD_OUTPUT" 'reference clone has stash entries that sync preserves but destructive workflows reject' "state.sh should explain reference stash state"
assert_contains "$CMD_OUTPUT" 'stash@{0}: On main: temp' "state.sh should show reference stash entries"
run_cmd bash "$FORKER_ROOT/sync-reference.sh" reference
assert_status 0 "sync-reference.sh should ignore stash-only drift in reference clones"
assert_contains "$CMD_OUTPUT" $'reference\tupdated\t' "sync-reference.sh should relock a writable reference clone"
[ -n "$(git -C "$FORKS_ROOT/reference/repo" stash list)" ] || fail "sync-reference.sh should preserve reference stashes"
[ ! -w "$FORKS_ROOT/reference/repo/README.md" ] || fail "sync-reference.sh should relock a stashed reference clone"

run_cmd bash "$FORKER_ROOT/sync-reference.sh" branchy_reference
assert_status 0 "sync-reference.sh should clone a multi-branch reference entry"
assert_contains "$CMD_OUTPUT" $'branchy_reference\tcloned\t-\t' "sync-reference.sh should report a clone for multi-branch references"
assert_equals "$(git -C "$FORKS_ROOT/branchy_reference/repo" branch --show-current)" 'dev' "sync-reference.sh should check out the newest mirrored branch"

run_cmd bash "$FORKER_ROOT/state.sh" branchy_reference
assert_status 0 "state.sh should accept a clean multi-branch reference clone"
assert_contains "$CMD_OUTPUT" 'reference clone matches primary origin/dev' "state.sh should report the derived primary branch"
assert_contains "$CMD_OUTPUT" 'remote_head  origin/main' "state.sh should report the upstream remote HEAD separately"

chmod -R u+w "$FORKS_ROOT/branchy_reference/repo"
run_cmd bash "$FORKER_ROOT/state.sh" branchy_reference
assert_status 1 "state.sh should reject writable reference clones"
assert_contains "$CMD_OUTPUT" 'reference clone is writable but should be read-only' "state.sh should explain writable reference drift"

printf '%s\n' 'manual override change' >> "$FORKS_ROOT/branchy_reference/repo/README.md"
touch "$FORKS_ROOT/branchy_reference/repo/extra.tmp"
run_cmd bash "$FORKER_ROOT/remove-reference.sh" branchy_reference
assert_status 1 "remove-reference.sh should reject drifted reference clones"
assert_contains "$CMD_OUTPUT" 'ERROR: branchy_reference has local reference state that would be lost.' "remove-reference.sh should explain reference drift loss risk"
[ -d "$FORKS_ROOT/branchy_reference/repo/.git" ] || fail "remove-reference.sh should leave drifted reference clones in place on failure"
run_cmd bash "$FORKER_ROOT/sync-reference.sh" branchy_reference
assert_status 0 "sync-reference.sh should discard local reference worktree drift"
assert_contains "$CMD_OUTPUT" $'branchy_reference\tupdated\t' "sync-reference.sh should report resetting reference drift"
[ ! -e "$FORKS_ROOT/branchy_reference/repo/extra.tmp" ] || fail "sync-reference.sh should remove untracked files from reference clones"
[ ! -w "$FORKS_ROOT/branchy_reference/repo/README.md" ] || fail "sync-reference.sh should relock reference clones after discarding drift"

append_commit "$BRANCHY_REF_WORK" main README.md 'branchy main hotfix'
run_cmd bash "$FORKER_ROOT/sync-reference.sh" branchy_reference
assert_status 0 "sync-reference.sh should refresh the primary branch when another branch becomes newer"
assert_contains "$CMD_OUTPUT" $'branchy_reference\tupdated\t' "sync-reference.sh should report primary branch changes"
assert_equals "$(git -C "$FORKS_ROOT/branchy_reference/repo" branch --show-current)" 'main' "sync-reference.sh should switch to the newest mirrored branch"

run_cmd bash "$FORKER_ROOT/state.sh" branchy_reference
assert_status 0 "state.sh should accept a refreshed multi-branch reference clone"
assert_contains "$CMD_OUTPUT" 'reference clone matches primary origin/main' "state.sh should track the new primary branch"

run_cmd bash "$FORKER_ROOT/sync-reference.sh" convertible_reference
assert_status 0 "sync-reference.sh should clone a convertible reference entry"
assert_equals "$(git -C "$FORKS_ROOT/convertible_reference/repo" branch --show-current)" 'dev' "sync-reference.sh should start convertible references on their newest branch"

chmod -R u+w "$FORKS_ROOT/branchy_reference/repo"
printf '%s\n' 'unsafe reference edit' >> "$FORKS_ROOT/branchy_reference/repo/README.md"
run_cmd bash "$FORKER_ROOT/reference-to-managed.sh" branchy_reference
assert_status 1 "reference-to-managed.sh should reject writable drifted reference clones"
assert_contains "$CMD_OUTPUT" 'ERROR: branchy_reference is not a clean read-only reference mirror.' "reference-to-managed.sh should explain writable reference drift"

run_cmd bash "$FORKER_ROOT/sync-reference.sh" branchy_reference
assert_status 0 "sync-reference.sh should relock a reference clone after discarding local drift"

chmod -R u+w "$FORKS_ROOT/reference/repo"
printf '%s\n' 'stash conversion blocker' >> "$FORKS_ROOT/reference/repo/README.md"
git -C "$FORKS_ROOT/reference/repo" stash push --include-untracked -m 'reference conversion blocker' >/dev/null 2>&1
chmod -R a-w "$FORKS_ROOT/reference/repo"
run_cmd bash "$FORKER_ROOT/reference-to-managed.sh" reference
assert_status 1 "reference-to-managed.sh should reject reference clones with stash entries"
assert_contains "$CMD_OUTPUT" 'reference-local stash entries that would be lost' "reference-to-managed.sh should explain stash loss risk"
chmod -R u+w "$FORKS_ROOT/reference/repo"
git -C "$FORKS_ROOT/reference/repo" stash drop >/dev/null 2>&1
chmod -R a-w "$FORKS_ROOT/reference/repo"

run_cmd bash "$FORKER_ROOT/sync-all-references.sh"
assert_status 0 "sync-all-references.sh should complete when entries are healthy"
assert_contains "$CMD_OUTPUT" $'summary\tupdated=0\tcloned=0\tunchanged=3\tskipped=0\tfailed=0' "sync-all-references.sh should print an aggregate summary"

run_cmd bash "$FORKER_ROOT/state.sh" does_not_exist
assert_status 1 "state.sh should reject unknown entries"
assert_contains "$CMD_OUTPUT" 'ERROR: does_not_exist is not configured.' "state.sh should explain missing config entries"

run_cmd bash "$FORKER_ROOT/sync-reference.sh" does_not_exist
assert_status 1 "sync-reference.sh should reject unknown entries"
assert_contains "$CMD_OUTPUT" 'ERROR: does_not_exist is not configured.' "sync-reference.sh should explain missing config entries"

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" does_not_exist
assert_status 1 "wip-to-series.sh should reject unknown entries"
assert_contains "$CMD_OUTPUT" 'ERROR: does_not_exist is not configured.' "wip-to-series.sh should explain missing config entries"

chmod -R u+w "$FORKS_ROOT/reference/repo"
git -C "$FORKS_ROOT/reference/repo" stash clear >/dev/null 2>&1
chmod -R a-w "$FORKS_ROOT/reference/repo"

tmp="$FORKS_ROOT/config.json.tmp"
jq --arg upstream "file://$REF_BARE" '.missing_reference = {"upstream": $upstream, "mode": "reference"}' "$FORKS_ROOT/config.json" > "$tmp"
mv "$tmp" "$FORKS_ROOT/config.json"

run_cmd bash "$FORKER_ROOT/remove-reference.sh" missing_reference reference
assert_status 0 "remove-reference.sh should remove multiple explicit reference entries"
assert_contains "$CMD_OUTPUT" 'missing_reference: removed reference entry' "remove-reference.sh should remove missing reference entries from config"
assert_contains "$CMD_OUTPUT" 'reference: removed reference entry' "remove-reference.sh should remove existing reference entries"
assert_contains "$CMD_OUTPUT" $'summary\tremoved=2\tfailed=0' "remove-reference.sh should summarize multi-entry removal"
assert_equals "$(jq -r 'has("missing_reference")' "$FORKS_ROOT/config.json")" 'false' "remove-reference.sh should delete missing reference entries from config"
assert_equals "$(jq -r 'has("reference")' "$FORKS_ROOT/config.json")" 'false' "remove-reference.sh should delete removed reference entries from config"
[ ! -e "$FORKS_ROOT/missing_reference" ] || fail "remove-reference.sh should tolerate already-missing reference directories"
[ ! -d "$FORKS_ROOT/reference" ] || fail "remove-reference.sh should delete removed reference directories"

chmod -R u+w "$FORKS_ROOT/branchy_reference/repo"
printf '%s\n' 'stash removal blocker' >> "$FORKS_ROOT/branchy_reference/repo/README.md"
git -C "$FORKS_ROOT/branchy_reference/repo" stash push --include-untracked -m 'reference removal blocker' >/dev/null 2>&1
chmod -R a-w "$FORKS_ROOT/branchy_reference/repo"
run_cmd bash "$FORKER_ROOT/remove-reference.sh" branchy_reference
assert_status 1 "remove-reference.sh should reject reference clones with stash entries"
assert_contains "$CMD_OUTPUT" 'reference-local stash entries that would be lost' "remove-reference.sh should explain stash loss risk"
assert_equals "$(jq -r 'has("branchy_reference")' "$FORKS_ROOT/config.json")" 'true' "remove-reference.sh should leave the config entry in place on failure"
[ -d "$FORKS_ROOT/branchy_reference/repo/.git" ] || fail "remove-reference.sh should leave the live repo in place on failure"

chmod -R u+w "$FORKS_ROOT/branchy_reference/repo"
git -C "$FORKS_ROOT/branchy_reference/repo" stash drop >/dev/null 2>&1
chmod -R a-w "$FORKS_ROOT/branchy_reference/repo"
run_cmd bash "$FORKER_ROOT/remove-reference.sh" branchy_reference
assert_status 0 "remove-reference.sh should remove clean reference entries"
assert_contains "$CMD_OUTPUT" 'branchy_reference: removed reference entry' "remove-reference.sh should report the removed entry"
assert_equals "$(jq -r 'has("branchy_reference")' "$FORKS_ROOT/config.json")" 'false' "remove-reference.sh should delete the config entry"
[ ! -d "$FORKS_ROOT/branchy_reference" ] || fail "remove-reference.sh should delete the live entry directory"

run_cmd bash "$FORKER_ROOT/reference-to-managed.sh" convertible_reference
assert_status 0 "reference-to-managed.sh should convert a reference entry into a managed clone"
assert_contains "$CMD_OUTPUT" 'convertible_reference: converted to managed with base_branch=dev' "reference-to-managed.sh should preserve the current reference primary branch"
assert_equals "$(jq -r '.convertible_reference.mode' "$FORKS_ROOT/config.json")" 'managed' "reference-to-managed.sh should rewrite config mode"
assert_equals "$(jq -r '.convertible_reference.base_branch' "$FORKS_ROOT/config.json")" 'dev' "reference-to-managed.sh should record the managed base branch"
assert_equals "$(jq -c '.convertible_reference.refs' "$FORKS_ROOT/config.json")" '[]' "reference-to-managed.sh should not invent managed merge refs"
[ -d "$FORKS_ROOT/convertible_reference/pin" ] || fail "reference-to-managed.sh should create pin state"
assert_equals "$(git -C "$FORKS_ROOT/convertible_reference/repo" branch --show-current)" 'wip' "reference-to-managed.sh should leave a writable managed wip clone"
[ -w "$FORKS_ROOT/convertible_reference/repo/README.md" ] || fail "reference-to-managed.sh should leave managed clones writable"
assert_contains "$(cat "$FORKS_ROOT/convertible_reference/repo/README.md")" 'convertible dev content' "reference-to-managed.sh should preserve the current reference content"

run_cmd bash "$FORKER_ROOT/state.sh" convertible_reference
assert_status 0 "state.sh should treat a converted managed entry as pinned"
assert_contains "$CMD_OUTPUT" 'wip matches pins' "state.sh should report the converted managed entry as pinned"

run_cmd bash "$FORKER_ROOT/upstream-to-pins.sh" managed
assert_status 0 "upstream-to-pins.sh should bootstrap a managed entry with no refs"
assert_contains "$CMD_OUTPUT" 'Pins rebuilt in managed/pin/' "upstream-to-pins.sh should write managed pins"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" config --get remote.origin.promisor 2>/dev/null || true)" '' "upstream-to-pins.sh should not leave managed clones as promisor clones"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" config --get remote.origin.partialclonefilter 2>/dev/null || true)" '' "upstream-to-pins.sh should not leave managed clones with a partial clone filter"

run_cmd bash "$FORKER_ROOT/upstream-to-pins.sh" merged
assert_status 0 "upstream-to-pins.sh should bootstrap a disposable managed entry for conversion"
assert_contains "$CMD_OUTPUT" 'Pins rebuilt in merged/pin/' "upstream-to-pins.sh should write pins before converting to reference"

run_cmd bash "$FORKER_ROOT/managed-to-reference.sh" merged
assert_status 0 "managed-to-reference.sh should convert a managed entry back to reference mode"
assert_contains "$CMD_OUTPUT" 'merged: converted to reference at ' "managed-to-reference.sh should report the rebuilt reference clone"
assert_equals "$(jq -r '.merged.mode' "$FORKS_ROOT/config.json")" 'reference' "managed-to-reference.sh should rewrite config mode"
[ ! -d "$FORKS_ROOT/merged/pin" ] || fail "managed-to-reference.sh should remove managed pin state"
assert_equals "$(git -C "$FORKS_ROOT/merged/repo" branch --show-current)" 'main' "managed-to-reference.sh should leave a reference clone on the default branch"
assert_equals "$(git -C "$FORKS_ROOT/merged/repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}')" 'origin/main' "managed-to-reference.sh should track the upstream default branch"
[ ! -w "$FORKS_ROOT/merged/repo/README.md" ] || fail "managed-to-reference.sh should relock converted reference clones"

run_cmd bash "$FORKER_ROOT/state.sh" merged
assert_status 0 "state.sh should treat a converted entry as a clean reference clone"
assert_contains "$CMD_OUTPUT" 'reference clone matches primary origin/main' "state.sh should report the converted entry as reference-clean"
assert_contains "$CMD_OUTPUT" 'readonly     yes' "state.sh should report converted reference clones as read-only"

run_cmd bash "$FORKER_ROOT/upstream-to-pins.sh" merged
assert_status 1 "upstream-to-pins.sh should reject entries converted back to reference mode"
assert_contains "$CMD_OUTPUT" "Use 'bash forks/phroi_forker/repo/sync-reference.sh merged'." "managed workflows should redirect converted entries to sync-reference.sh"

mkdir -p "$FORKS_ROOT/bootstrap"
git clone --quiet --branch main "file://$BOOT_BARE" "$FORKS_ROOT/bootstrap/repo"
git -C "$FORKS_ROOT/bootstrap/repo" config user.email ci@example.com
git -C "$FORKS_ROOT/bootstrap/repo" config user.name ci
printf '%s\n' 'bootstrap local text change' >> "$FORKS_ROOT/bootstrap/repo/README.md"
printf '\x02\x03bootstrap-binary\n' > "$FORKS_ROOT/bootstrap/repo/bootstrap.bin"
git -C "$FORKS_ROOT/bootstrap/repo" add README.md bootstrap.bin
git -C "$FORKS_ROOT/bootstrap/repo" commit -m 'bootstrap local series' >/dev/null 2>&1

BOOT_BEFORE_STATUS=$(git -C "$FORKS_ROOT/bootstrap/repo" status --short)
BOOT_BEFORE_HEAD=$(git -C "$FORKS_ROOT/bootstrap/repo" rev-parse HEAD)

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" bootstrap
assert_status 0 "wip-to-series.sh should bootstrap pins for an unpinned managed clone"
assert_contains "$CMD_OUTPUT" 'Bootstrapped pins and saved 1 commit(s) in bootstrap/pin/series/.' "bootstrap save should report pin creation"

run_cmd bash "$FORKER_ROOT/state.sh" bootstrap
assert_status 0 "state.sh should treat a saved bootstrap worktree as safe"
assert_contains "$CMD_OUTPUT" 'wip matches the saved pin series' "state should explain bootstrap saved state"

[ -f "$FORKS_ROOT/bootstrap/pin/manifest" ] || fail "bootstrap save should create a manifest"
[ -f "$FORKS_ROOT/bootstrap/pin/HEAD" ] || fail "bootstrap save should create a HEAD pin"
[ -f "$FORKS_ROOT/bootstrap/pin/LOCAL_BASE" ] || fail "bootstrap save should create LOCAL_BASE"
[ "$(find "$FORKS_ROOT/bootstrap/pin/series" -name '*.patch' | wc -l)" -eq 1 ] || fail "bootstrap save should create one saved series patch"

BOOT_AFTER_STATUS=$(git -C "$FORKS_ROOT/bootstrap/repo" status --short)
BOOT_AFTER_HEAD=$(git -C "$FORKS_ROOT/bootstrap/repo" rev-parse HEAD)
assert_equals "$BOOT_AFTER_STATUS" "$BOOT_BEFORE_STATUS" "bootstrap save should leave the live worktree untouched"
assert_equals "$BOOT_AFTER_HEAD" "$BOOT_BEFORE_HEAD" "bootstrap save should not move the live clone HEAD"

rm -rf "$FORKS_ROOT/bootstrap/repo"
run_cmd bash "$FORKER_ROOT/pins-to-wip.sh" bootstrap
assert_status 0 "pins-to-wip.sh should rebuild a bootstrap-saved managed clone"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "bootstrap replay should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/bootstrap/repo/README.md")" 'bootstrap local text change' "bootstrap replay should restore saved text changes"
[ -f "$FORKS_ROOT/bootstrap/repo/bootstrap.bin" ] || fail "bootstrap replay should restore saved binary files"

mkdir -p "$FORKS_ROOT/bootstrap_refs"
git clone --quiet --branch main "file://$BOOT_REFS_BARE" "$FORKS_ROOT/bootstrap_refs/repo"
git -C "$FORKS_ROOT/bootstrap_refs/repo" config user.email ci@example.com
git -C "$FORKS_ROOT/bootstrap_refs/repo" config user.name ci
git -C "$FORKS_ROOT/bootstrap_refs/repo" fetch origin "+refs/heads/feature:refs/remotes/origin/feature" >/dev/null 2>&1
git -C "$FORKS_ROOT/bootstrap_refs/repo" merge --no-edit origin/feature >/dev/null 2>&1
printf '%s\n' 'bootstrap refs local text change' >> "$FORKS_ROOT/bootstrap_refs/repo/README.md"
printf '\x04\x05bootstrap-refs-binary\n' > "$FORKS_ROOT/bootstrap_refs/repo/bootstrap-refs.bin"
git -C "$FORKS_ROOT/bootstrap_refs/repo" add README.md bootstrap-refs.bin
git -C "$FORKS_ROOT/bootstrap_refs/repo" commit -m 'bootstrap refs local series' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" bootstrap_refs
assert_status 1 "bootstrap save with refs should reject clones not based on the derived managed base"
assert_contains "$CMD_OUTPUT" 'Run '\''bash forks/phroi_forker/repo/upstream-to-pins.sh bootstrap_refs'\'' first' "bootstrap save with refs should require a canonical managed base"

rm -rf "$FORKS_ROOT/bootstrap_refs/repo"
run_cmd bash "$FORKER_ROOT/upstream-to-pins.sh" bootstrap_refs
assert_status 0 "upstream-to-pins.sh should bootstrap a managed entry with refs"
assert_contains "$CMD_OUTPUT" 'Pins rebuilt in bootstrap_refs/pin/' "upstream-to-pins.sh should write ref-based pins"

rm -rf "$FORKS_ROOT/bootstrap_refs/repo"
run_cmd bash "$FORKER_ROOT/pins-to-wip.sh" bootstrap_refs
assert_status 0 "pins-to-wip.sh should rebuild a managed clone with refs"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "bootstrap refs replay should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/bootstrap_refs/repo/README.md")" 'feature branch content' "bootstrap refs replay should include the configured ref merge"

run_cmd bash "$FORKER_ROOT/pins-to-missing-wips.sh"
assert_status 0 "pins-to-missing-wips.sh should skip existing clean managed clones"
assert_contains "$CMD_OUTPUT" $'summary\tmaterialized=0\tskipped=4\tfailed=0' "pins-to-missing-wips.sh should summarize clean existing clones as skips"

run_cmd bash "$FORKER_ROOT/verify-pins.sh" managed
assert_status 0 "verify-pins.sh should dry-run replay for one managed entry"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "verify-pins.sh should confirm the pinned HEAD"

run_cmd bash "$FORKER_ROOT/verify-all-pins.sh"
assert_status 0 "verify-all-pins.sh should dry-run replay for all managed entries"
assert_contains "$CMD_OUTPUT" $'summary\tverified=4\tfailed=0' "verify-all-pins.sh should print an aggregate summary"

run_cmd bash "$FORKER_ROOT/state.sh" managed
assert_status 0 "state.sh should accept a clean managed clone"
assert_contains "$CMD_OUTPUT" 'wip matches pins' "managed state should report pin alignment"

printf '%s\n' 'stashed change' >> "$FORKS_ROOT/managed/repo/README.md"
git -C "$FORKS_ROOT/managed/repo" stash push -m 'unsafe local stash' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/state.sh" managed
assert_status 1 "state.sh should treat stash entries as unsafe managed state"
assert_contains "$CMD_OUTPUT" 'stash@{0}: On wip: unsafe local stash' "state.sh should surface the stash in its dirty-state report"

run_cmd bash "$FORKER_ROOT/rebuild-wip.sh" managed
assert_status 1 "rebuild-wip.sh should refuse to replace a managed clone with a stash"
assert_contains "$CMD_OUTPUT" 'pending work that would be lost' "rebuild-wip.sh should reject stashed local state"

git -C "$FORKS_ROOT/managed/repo" stash drop >/dev/null 2>&1

git -C "$FORKS_ROOT/managed/repo" config user.email ci@example.com
git -C "$FORKS_ROOT/managed/repo" config user.name ci
git -C "$FORKS_ROOT/managed/repo" branch pr-1 >/dev/null 2>&1
printf '%s\n' 'saved series text' >> "$FORKS_ROOT/managed/repo/README.md"
printf '\x00\x01local-binary\n' > "$FORKS_ROOT/managed/repo/local.bin"
git -C "$FORKS_ROOT/managed/repo" add README.md local.bin
git -C "$FORKS_ROOT/managed/repo" commit -m 'save local series' >/dev/null 2>&1

BEFORE_STATUS=$(git -C "$FORKS_ROOT/managed/repo" status --short)
BEFORE_HEAD=$(git -C "$FORKS_ROOT/managed/repo" rev-parse HEAD)

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" managed
assert_status 0 "wip-to-series.sh should save a local commit series"
assert_contains "$CMD_OUTPUT" 'Saved 1 commit(s) in managed/pin/series/.' "wip-to-series.sh should write the saved series"

AFTER_STATUS=$(git -C "$FORKS_ROOT/managed/repo" status --short)
AFTER_HEAD=$(git -C "$FORKS_ROOT/managed/repo" rev-parse HEAD)
assert_equals "$AFTER_STATUS" "$BEFORE_STATUS" "wip-to-series.sh should leave the live worktree untouched"
assert_equals "$AFTER_HEAD" "$BEFORE_HEAD" "wip-to-series.sh should not move the live clone HEAD"

run_cmd bash "$FORKER_ROOT/state.sh" managed
assert_status 0 "state.sh should treat a saved managed worktree as safe"
assert_contains "$CMD_OUTPUT" 'wip matches the saved pin series' "state should explain saved managed state"

run_cmd bash "$FORKER_ROOT/series-to-branch.sh" managed pr-missing
assert_status 1 "series-to-branch.sh should still validate the target branch"
assert_contains "$CMD_OUTPUT" "Target branch 'pr-missing' does not exist" "series-to-branch.sh should require a valid target branch"

run_cmd bash "$FORKER_ROOT/series-to-branch.sh" managed pr-1
assert_status 0 "series-to-branch.sh should allow a saved clean series without replaying"
assert_contains "$CMD_OUTPUT" 'No fork remote is configured for managed.' "series-to-branch.sh should explain missing fork remotes"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" branch --show-current)" 'wip' "series-to-branch.sh should return to wip on success"
assert_contains "$(git -C "$FORKS_ROOT/managed/repo" log --oneline pr-1 -1)" 'save local series' "series-to-branch.sh should cherry-pick the saved commit series onto the target branch"
git -C "$FORKS_ROOT/managed/repo" push origin pr-1:pr-1 >/dev/null 2>&1

printf '%s\n' 'unsaved follow-up' >> "$FORKS_ROOT/managed/repo/README.md"
git -C "$FORKS_ROOT/managed/repo" add README.md
git -C "$FORKS_ROOT/managed/repo" commit -m 'unsaved follow-up' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/series-to-branch.sh" managed pr-1
assert_status 1 "series-to-branch.sh should reject unsaved local commits"
assert_contains "$CMD_OUTPUT" 'Run '\''bash forks/phroi_forker/repo/wip-to-series.sh managed'\'' to save changes before pushing.' "series-to-branch.sh should require saving before push"

[ -f "$FORKS_ROOT/managed/pin/LOCAL_BASE" ] || fail "wip-to-series.sh should write LOCAL_BASE"
[ "$(find "$FORKS_ROOT/managed/pin/series" -name '*.patch' | wc -l)" -eq 1 ] || fail "wip-to-series.sh should write one saved series patch"

rm -rf "$FORKS_ROOT/managed/repo"
run_cmd bash "$FORKER_ROOT/pins-to-wip.sh" managed
assert_status 0 "pins-to-wip.sh should rebuild a managed clone from pins"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "pins-to-wip.sh should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/managed/repo/README.md")" 'saved series text' "pins-to-wip.sh should restore saved text changes"
[ -f "$FORKS_ROOT/managed/repo/local.bin" ] || fail "pins-to-wip.sh should restore saved binary files"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" config --get remote.origin.promisor 2>/dev/null || true)" '' "pins-to-wip.sh should not rebuild managed clones as promisor clones"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" config --get remote.origin.partialclonefilter 2>/dev/null || true)" '' "pins-to-wip.sh should not rebuild managed clones with a partial clone filter"

run_cmd bash "$FORKER_ROOT/pins-to-wip.sh" managed
assert_status 1 "pins-to-wip.sh should refuse to overwrite an existing managed clone"
assert_contains "$CMD_OUTPUT" 'Use '\''bash forks/phroi_forker/repo/rebuild-wip.sh managed'\'' instead.' "pins-to-wip.sh should tell the user how to rebuild"

run_cmd bash "$FORKER_ROOT/rebuild-wip.sh" managed
assert_status 0 "rebuild-wip.sh should replace an existing clean managed clone"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "rebuild-wip.sh should verify the rebuilt HEAD"

rm -rf "$FORKS_ROOT/managed/repo"
mkdir -p "$FORKS_ROOT/managed"
git clone --quiet --branch main "file://$MANAGED_BARE" "$FORKS_ROOT/managed/repo"
run_cmd bash "$FORKER_ROOT/rebuild-wip.sh" managed
assert_status 0 "rebuild-wip.sh should accept a clean upstream-tip managed clone"
assert_contains "$CMD_OUTPUT" 'OK: wip HEAD matches pinned HEAD' "rebuild-wip.sh should rebuild from a disposable upstream-tip clone"
assert_contains "$(cat "$FORKS_ROOT/managed/repo/README.md")" 'saved series text' "rebuild-wip.sh should restore the saved series after replacing an upstream-tip clone"

git -C "$FORKS_ROOT/managed/repo" config user.email ci@example.com
git -C "$FORKS_ROOT/managed/repo" config user.name ci

printf '%s\n' 'scratch' > "$FORKS_ROOT/managed/repo/scratch.txt"
run_cmd bash "$FORKER_ROOT/series-to-branch.sh" managed pr-1
assert_status 1 "series-to-branch.sh should reject a dirty wip branch"
assert_contains "$CMD_OUTPUT" 'wip must be clean' "series-to-branch.sh should explain the clean-worktree requirement"
rm -f "$FORKS_ROOT/managed/repo/scratch.txt"

printf '%s\n' 'commit for pr branch' >> "$FORKS_ROOT/managed/repo/README.md"
git -C "$FORKS_ROOT/managed/repo" add README.md
git -C "$FORKS_ROOT/managed/repo" commit -m 'test push flow' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" managed
assert_status 0 "wip-to-series.sh should keep rewriting the full saved series"
assert_contains "$CMD_OUTPUT" 'Saved 2 commit(s) in managed/pin/series/.' "wip-to-series.sh should rewrite the full saved series after later commits"

run_cmd bash "$FORKER_ROOT/series-to-branch.sh" managed pr-1
assert_status 0 "series-to-branch.sh should cherry-pick onto the target branch"
assert_contains "$CMD_OUTPUT" 'No fork remote is configured for managed.' "series-to-branch.sh should explain missing fork remotes"
assert_equals "$(git -C "$FORKS_ROOT/managed/repo" branch --show-current)" 'wip' "series-to-branch.sh should return to wip on success"
assert_contains "$(git -C "$FORKS_ROOT/managed/repo" log --oneline pr-1 -1)" 'test push flow' "series-to-branch.sh should cherry-pick the commit onto the target branch"

rm -rf "$FORKS_ROOT/bootstrap/repo"
printf '%s\n' 'dirty blocker' > "$FORKS_ROOT/bootstrap_refs/repo/dirty.txt"
run_cmd bash "$FORKER_ROOT/pins-to-missing-wips.sh"
assert_status 1 "pins-to-missing-wips.sh should continue past failures and return non-zero when any materialization fails"
assert_contains "$CMD_OUTPUT" $'summary\tmaterialized=1\tskipped=2\tfailed=1' "pins-to-missing-wips.sh should print an aggregate summary"
[ -d "$FORKS_ROOT/bootstrap/repo/.git" ] || fail "pins-to-missing-wips.sh should still rebuild missing managed clones"
rm -f "$FORKS_ROOT/bootstrap_refs/repo/dirty.txt"

run_cmd bash "$FORKER_ROOT/rebuild-pins.sh" bootstrap
assert_status 0 "rebuild-pins.sh should discard saved series and rebuild from upstream"
assert_contains "$CMD_OUTPUT" 'Pins rebuilt in bootstrap/pin/' "rebuild-pins.sh should rewrite the pin set"
assert_equals "$(cat "$FORKS_ROOT/bootstrap/repo/README.md")" 'bootstrap-upstream base' "rebuild-pins.sh should discard the saved local text"
[ "$(find "$FORKS_ROOT/bootstrap/pin/series" -name '*.patch' 2>/dev/null | wc -l)" -eq 0 ] || fail "rebuild-pins.sh should clear the saved series"

FAKEBIN="$ROOT/fake-bin"
mkdir -p "$FAKEBIN"
ln -s "$(command -v bash)" "$FAKEBIN/bash"
ln -s "$(command -v basename)" "$FAKEBIN/basename"
ln -s "$(command -v mv)" "$FAKEBIN/mv"
ln -s "$(command -v git)" "$FAKEBIN/git"
ln -s "$(command -v jq)" "$FAKEBIN/jq"
ln -s "$(command -v dirname)" "$FAKEBIN/dirname"

run_cmd env PATH="$FAKEBIN" /bin/bash "$FORKER_ROOT/health.sh"
assert_status 0 "health.sh should treat pnpm as optional"
assert_contains "$CMD_OUTPUT" $'OK\ttool\tpnpm\toptional-for-conflicts-only' "health.sh should report missing pnpm as optional"

run_cmd bash "$FORKER_ROOT/health.sh"
assert_status 0 "health.sh should still succeed after workflow operations"
assert_contains "$CMD_OUTPUT" $'summary\tok=' "health.sh should still print a summary"
assert_contains "$CMD_OUTPUT" $'\terror=0' "health.sh should still report zero errors"

git -C "$FORKS_ROOT/managed/repo" checkout -b side-merge >/dev/null 2>&1
printf '%s\n' 'merge side branch change' >> "$FORKS_ROOT/managed/repo/README.md"
git -C "$FORKS_ROOT/managed/repo" add README.md
git -C "$FORKS_ROOT/managed/repo" commit -m 'side merge change' >/dev/null 2>&1
git -C "$FORKS_ROOT/managed/repo" checkout wip >/dev/null 2>&1
git -C "$FORKS_ROOT/managed/repo" merge --no-ff --no-edit side-merge >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/wip-to-series.sh" managed
assert_status 1 "wip-to-series.sh should reject merge commits in the local series"
assert_contains "$CMD_OUTPUT" 'linear local series' "wip-to-series.sh should explain the linear-history requirement"

run_cmd bash "$FORKER_ROOT/state.sh" managed
assert_status 1 "state.sh should reject merge commits in the local series"
assert_contains "$CMD_OUTPUT" 'contains merge commits after LOCAL_BASE' "state.sh should surface merge commits after LOCAL_BASE"

printf '%s\n' 'PASS'
