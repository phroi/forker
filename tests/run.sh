#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

TEST_ROOT="$ROOT/work"
FORKS_ROOT="$TEST_ROOT/forks"
FORKER_ROOT="$FORKS_ROOT/phroi_forker"

mkdir -p "$FORKER_ROOT"
SOURCE_FORKER="$(cd "$(dirname "$0")/.." && pwd)"
cp -a "$SOURCE_FORKER"/. "$FORKER_ROOT/"
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
  git -C "$work" commit -m "init" >/dev/null 2>&1
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
  git -C "$work" commit -m "update $file" >/dev/null 2>&1
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
  git -C "$work" commit -m "branch $new_branch" >/dev/null 2>&1
  git -C "$work" push -u origin "$new_branch" >/dev/null 2>&1
  git -C "$work" checkout "$base_branch" >/dev/null 2>&1
}

IFS=$'\t' read -r REF_WORK REF_BARE <<< "$(create_upstream reference-upstream main)"
IFS=$'\t' read -r MANAGED_WORK MANAGED_BARE <<< "$(create_upstream managed-upstream main)"
IFS=$'\t' read -r BOOT_WORK BOOT_BARE <<< "$(create_upstream bootstrap-upstream main)"
IFS=$'\t' read -r BOOT_REFS_WORK BOOT_REFS_BARE <<< "$(create_upstream bootstrap-refs-upstream main)"
create_branch_commit "$BOOT_REFS_WORK" main feature README.md 'feature branch content'

cat > "$FORKS_ROOT/config.json" <<JSON
{
  "managed": {
    "upstream": "file://$MANAGED_BARE",
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
  }
}
JSON

run_cmd bash "$FORKER_ROOT/doctor.sh"
assert_status 0 "doctor should succeed on clean test setup"
assert_contains "$CMD_OUTPUT" $'summary\tok=' "doctor should print a summary line"
assert_contains "$CMD_OUTPUT" $'\terror=0' "doctor should report zero errors"

run_cmd bash "$FORKER_ROOT/update.sh" reference
assert_status 0 "update.sh should clone a missing reference entry"
assert_contains "$CMD_OUTPUT" $'reference\tcloned\t-\t' "update.sh should report a clone"

run_cmd bash "$FORKER_ROOT/status.sh" reference
assert_status 0 "status.sh should accept a clean reference clone"
assert_contains "$CMD_OUTPUT" 'clone is clean' "status.sh should report a clean reference clone"

run_cmd bash "$FORKER_ROOT/reset.sh" reference
assert_status 1 "reset.sh should refuse reference entries"
assert_contains "$CMD_OUTPUT" 'reset.sh only applies to managed entries' "reset.sh should explain its managed-only scope"

printf '%s\n' 'dirty change' >> "$FORKS_ROOT/reference/README.md"
run_cmd bash "$FORKER_ROOT/status.sh" reference
assert_status 1 "status.sh should reject a dirty reference clone"
assert_contains "$CMD_OUTPUT" 'changes relative to' "dirty reference status should explain why"

run_cmd bash "$FORKER_ROOT/update.sh" reference
assert_status 0 "update.sh should skip a dirty reference clone without failing"
assert_contains "$CMD_OUTPUT" $'reference\tskipped\t' "update.sh should report a skipped dirty clone"

git -C "$FORKS_ROOT/reference" checkout -- README.md >/dev/null 2>&1
append_commit "$REF_WORK" main README.md 'remote update'

OLD_REF_SHA=$(git -C "$FORKS_ROOT/reference" rev-parse HEAD)
run_cmd bash "$FORKER_ROOT/update.sh" reference
assert_status 0 "update.sh should refresh a clean reference clone"
assert_contains "$CMD_OUTPUT" $'reference\tupdated\t' "update.sh should report an update"
NEW_REF_SHA=$(git -C "$FORKS_ROOT/reference" rev-parse HEAD)
[ "$OLD_REF_SHA" != "$NEW_REF_SHA" ] || fail "reference clone should move to a new commit"

run_cmd bash "$FORKER_ROOT/update-all.sh"
assert_status 0 "update-all.sh should complete when entries are healthy"
assert_contains "$CMD_OUTPUT" $'bootstrap\tskipped\t-\t-\tmode=managed use record.sh or replay.sh' "update-all.sh should skip bootstrap managed entries"
assert_contains "$CMD_OUTPUT" $'bootstrap_refs\tskipped\t-\t-\tmode=managed use record.sh or replay.sh' "update-all.sh should skip managed ref bootstrap entries"
assert_contains "$CMD_OUTPUT" $'managed\tskipped\t-\t-\tmode=managed use record.sh or replay.sh' "update-all.sh should skip managed entries"
assert_contains "$CMD_OUTPUT" $'summary\tupdated=0\tcloned=0\tunchanged=1\tskipped=3\tfailed=0' "update-all.sh should print an aggregate summary"

run_cmd bash "$FORKER_ROOT/record.sh" managed
assert_status 0 "record.sh should bootstrap a managed entry with no refs"
assert_contains "$CMD_OUTPUT" 'Pins recorded in .pin/managed/' "record.sh should write managed pins"

git clone --quiet --branch main "file://$BOOT_BARE" "$FORKS_ROOT/bootstrap"
git -C "$FORKS_ROOT/bootstrap" config user.email ci@example.com
git -C "$FORKS_ROOT/bootstrap" config user.name ci
printf '%s\n' 'bootstrap local text change' >> "$FORKS_ROOT/bootstrap/README.md"
printf '\x02\x03bootstrap-binary\n' > "$FORKS_ROOT/bootstrap/bootstrap.bin"
git -C "$FORKS_ROOT/bootstrap" add README.md bootstrap.bin
git -C "$FORKS_ROOT/bootstrap" commit -m 'bootstrap local series' >/dev/null 2>&1

BOOT_BEFORE_STATUS=$(git -C "$FORKS_ROOT/bootstrap" status --short)
BOOT_BEFORE_HEAD=$(git -C "$FORKS_ROOT/bootstrap" rev-parse HEAD)

run_cmd bash "$FORKER_ROOT/save.sh" bootstrap
assert_status 0 "save.sh should bootstrap pins for an unpinned managed clone"
assert_contains "$CMD_OUTPUT" 'Bootstrapped pins and saved 1 commit(s) in .pin/bootstrap/series/.' "bootstrap save should report pin creation"

run_cmd bash "$FORKER_ROOT/status.sh" bootstrap
assert_status 0 "status.sh should treat a saved bootstrap worktree as safe"
assert_contains "$CMD_OUTPUT" 'saved series matches pins' "status should explain bootstrap saved state"

[ -f "$FORKS_ROOT/.pin/bootstrap/manifest" ] || fail "bootstrap save should create a manifest"
[ -f "$FORKS_ROOT/.pin/bootstrap/HEAD" ] || fail "bootstrap save should create a HEAD pin"
[ -f "$FORKS_ROOT/.pin/bootstrap/LOCAL_BASE" ] || fail "bootstrap save should create LOCAL_BASE"
[ "$(find "$FORKS_ROOT/.pin/bootstrap/series" -name '*.patch' | wc -l)" -eq 1 ] || fail "bootstrap save should create one saved series patch"

BOOT_AFTER_STATUS=$(git -C "$FORKS_ROOT/bootstrap" status --short)
BOOT_AFTER_HEAD=$(git -C "$FORKS_ROOT/bootstrap" rev-parse HEAD)
assert_equals "$BOOT_AFTER_STATUS" "$BOOT_BEFORE_STATUS" "bootstrap save should leave the live worktree untouched"
assert_equals "$BOOT_AFTER_HEAD" "$BOOT_BEFORE_HEAD" "bootstrap save should not move the live clone HEAD"

rm -rf "$FORKS_ROOT/bootstrap"
run_cmd bash "$FORKER_ROOT/replay.sh" bootstrap
assert_status 0 "replay.sh should rebuild a bootstrap-saved managed clone"
assert_contains "$CMD_OUTPUT" 'OK: replay HEAD matches pinned HEAD' "bootstrap replay should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/bootstrap/README.md")" 'bootstrap local text change' "bootstrap replay should restore saved text changes"
[ -f "$FORKS_ROOT/bootstrap/bootstrap.bin" ] || fail "bootstrap replay should restore saved binary files"

git clone --quiet --branch main "file://$BOOT_REFS_BARE" "$FORKS_ROOT/bootstrap_refs"
git -C "$FORKS_ROOT/bootstrap_refs" config user.email ci@example.com
git -C "$FORKS_ROOT/bootstrap_refs" config user.name ci
git -C "$FORKS_ROOT/bootstrap_refs" fetch origin "+refs/heads/feature:refs/remotes/origin/feature" >/dev/null 2>&1
git -C "$FORKS_ROOT/bootstrap_refs" merge --no-edit origin/feature >/dev/null 2>&1
printf '%s\n' 'bootstrap refs local text change' >> "$FORKS_ROOT/bootstrap_refs/README.md"
printf '\x04\x05bootstrap-refs-binary\n' > "$FORKS_ROOT/bootstrap_refs/bootstrap-refs.bin"
git -C "$FORKS_ROOT/bootstrap_refs" add README.md bootstrap-refs.bin
git -C "$FORKS_ROOT/bootstrap_refs" commit -m 'bootstrap refs local series' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/save.sh" bootstrap_refs
assert_status 1 "bootstrap save with refs should reject clones not based on the derived managed base"
assert_contains "$CMD_OUTPUT" 'Run '\''bash forks/phroi_forker/record.sh bootstrap_refs'\'' first' "bootstrap save with refs should require a canonical managed base"

rm -rf "$FORKS_ROOT/bootstrap_refs"
run_cmd bash "$FORKER_ROOT/record.sh" bootstrap_refs
assert_status 0 "record.sh should bootstrap a managed entry with refs"
assert_contains "$CMD_OUTPUT" 'Pins recorded in .pin/bootstrap_refs/' "record.sh should write ref-based pins"

rm -rf "$FORKS_ROOT/bootstrap_refs"
run_cmd bash "$FORKER_ROOT/replay.sh" bootstrap_refs
assert_status 0 "replay.sh should rebuild a managed clone with refs"
assert_contains "$CMD_OUTPUT" 'OK: replay HEAD matches pinned HEAD' "bootstrap refs replay should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/bootstrap_refs/README.md")" 'feature branch content' "bootstrap refs replay should include the configured ref merge"

run_cmd bash "$FORKER_ROOT/replay-all.sh"
assert_status 0 "replay-all.sh should skip existing clean managed clones"
assert_contains "$CMD_OUTPUT" $'summary\treplayed=0\tskipped=3\tfailed=0' "replay-all.sh should summarize clean existing clones as skips"

run_cmd bash "$FORKER_ROOT/verify-pins.sh" managed
assert_status 0 "verify-pins.sh should dry-run replay for one managed entry"
assert_contains "$CMD_OUTPUT" 'OK: replay HEAD matches pinned HEAD' "verify-pins.sh should confirm the pinned HEAD"

run_cmd bash "$FORKER_ROOT/verify-pins-all.sh"
assert_status 0 "verify-pins-all.sh should dry-run replay for all managed entries"
assert_contains "$CMD_OUTPUT" $'summary\tverified=3\tfailed=0' "verify-pins-all.sh should print an aggregate summary"

run_cmd bash "$FORKER_ROOT/status.sh" managed
assert_status 0 "status.sh should accept a clean managed clone"
assert_contains "$CMD_OUTPUT" 'matches pins' "managed status should report pin alignment"

git -C "$FORKS_ROOT/managed" config user.email ci@example.com
git -C "$FORKS_ROOT/managed" config user.name ci
git -C "$FORKS_ROOT/managed" branch pr-1 >/dev/null 2>&1
printf '%s\n' 'saved series text' >> "$FORKS_ROOT/managed/README.md"
printf '\x00\x01local-binary\n' > "$FORKS_ROOT/managed/local.bin"
git -C "$FORKS_ROOT/managed" add README.md local.bin
git -C "$FORKS_ROOT/managed" commit -m 'save local series' >/dev/null 2>&1

BEFORE_STATUS=$(git -C "$FORKS_ROOT/managed" status --short)
BEFORE_HEAD=$(git -C "$FORKS_ROOT/managed" rev-parse HEAD)

run_cmd bash "$FORKER_ROOT/save.sh" managed
assert_status 0 "save.sh should save a local commit series"
assert_contains "$CMD_OUTPUT" 'Saved 1 commit(s) in .pin/managed/series/.' "save.sh should write the saved series"

AFTER_STATUS=$(git -C "$FORKS_ROOT/managed" status --short)
AFTER_HEAD=$(git -C "$FORKS_ROOT/managed" rev-parse HEAD)
assert_equals "$AFTER_STATUS" "$BEFORE_STATUS" "save.sh should leave the live worktree untouched"
assert_equals "$AFTER_HEAD" "$BEFORE_HEAD" "save.sh should not move the live clone HEAD"

run_cmd bash "$FORKER_ROOT/status.sh" managed
assert_status 0 "status.sh should treat a saved managed worktree as safe"
assert_contains "$CMD_OUTPUT" 'saved series matches pins' "status should explain saved managed state"

run_cmd bash "$FORKER_ROOT/push.sh" managed pr-missing
assert_status 1 "push.sh should still validate the target branch"
assert_contains "$CMD_OUTPUT" "Target branch 'pr-missing' does not exist" "push.sh should require a valid target branch"

run_cmd bash "$FORKER_ROOT/push.sh" managed pr-1
assert_status 0 "push.sh should allow a saved clean series without replaying"
assert_contains "$CMD_OUTPUT" 'No fork remote is configured for managed.' "push.sh should explain missing fork remotes"
assert_equals "$(git -C "$FORKS_ROOT/managed" branch --show-current)" 'wip' "push.sh should return to wip on success"
assert_contains "$(git -C "$FORKS_ROOT/managed" log --oneline pr-1 -1)" 'save local series' "push.sh should cherry-pick the saved commit series onto the target branch"
git -C "$FORKS_ROOT/managed" push origin pr-1:pr-1 >/dev/null 2>&1

printf '%s\n' 'unsaved follow-up' >> "$FORKS_ROOT/managed/README.md"
git -C "$FORKS_ROOT/managed" add README.md
git -C "$FORKS_ROOT/managed" commit -m 'unsaved follow-up' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/push.sh" managed pr-1
assert_status 1 "push.sh should reject unsaved local commits"
assert_contains "$CMD_OUTPUT" 'Run '\''bash forks/phroi_forker/save.sh managed'\'' before pushing.' "push.sh should require saving before push"

[ -f "$FORKS_ROOT/.pin/managed/LOCAL_BASE" ] || fail "save.sh should write LOCAL_BASE"
[ "$(find "$FORKS_ROOT/.pin/managed/series" -name '*.patch' | wc -l)" -eq 1 ] || fail "save.sh should write one saved series patch"

rm -rf "$FORKS_ROOT/managed"
run_cmd bash "$FORKER_ROOT/replay.sh" managed
assert_status 0 "replay.sh should rebuild a managed clone from pins"
assert_contains "$CMD_OUTPUT" 'OK: replay HEAD matches pinned HEAD' "replay.sh should verify the rebuilt HEAD"
assert_contains "$(cat "$FORKS_ROOT/managed/README.md")" 'saved series text' "replay.sh should restore saved text changes"
[ -f "$FORKS_ROOT/managed/local.bin" ] || fail "replay.sh should restore saved binary files"

run_cmd bash "$FORKER_ROOT/replay.sh" managed
assert_status 1 "replay.sh should refuse to overwrite an existing managed clone"
assert_contains "$CMD_OUTPUT" 'Use '\''bash forks/phroi_forker/clean.sh managed'\'' before replaying.' "replay.sh should tell the user how to rebuild"

git -C "$FORKS_ROOT/managed" config user.email ci@example.com
git -C "$FORKS_ROOT/managed" config user.name ci

printf '%s\n' 'scratch' > "$FORKS_ROOT/managed/scratch.txt"
run_cmd bash "$FORKER_ROOT/push.sh" managed pr-1
assert_status 1 "push.sh should reject a dirty wip branch"
assert_contains "$CMD_OUTPUT" 'wip must be clean' "push.sh should explain the clean-worktree requirement"
rm -f "$FORKS_ROOT/managed/scratch.txt"

printf '%s\n' 'commit for pr branch' >> "$FORKS_ROOT/managed/README.md"
git -C "$FORKS_ROOT/managed" add README.md
git -C "$FORKS_ROOT/managed" commit -m 'test push flow' >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/save.sh" managed
assert_status 0 "save.sh should keep rewriting the full saved series"
assert_contains "$CMD_OUTPUT" 'Saved 2 commit(s) in .pin/managed/series/.' "save.sh should rewrite the full saved series after later commits"

run_cmd bash "$FORKER_ROOT/push.sh" managed pr-1
assert_status 0 "push.sh should cherry-pick onto the target branch"
assert_contains "$CMD_OUTPUT" 'No fork remote is configured for managed.' "push.sh should explain missing fork remotes"
assert_equals "$(git -C "$FORKS_ROOT/managed" branch --show-current)" 'wip' "push.sh should return to wip on success"
assert_contains "$(git -C "$FORKS_ROOT/managed" log --oneline pr-1 -1)" 'test push flow' "push.sh should cherry-pick the commit onto the target branch"

rm -rf "$FORKS_ROOT/bootstrap"
printf '%s\n' 'dirty blocker' > "$FORKS_ROOT/bootstrap_refs/dirty.txt"
run_cmd bash "$FORKER_ROOT/replay-all.sh"
assert_status 1 "replay-all.sh should continue past failures and return non-zero when any replay fails"
assert_contains "$CMD_OUTPUT" $'summary\treplayed=1\tskipped=1\tfailed=1' "replay-all.sh should print an aggregate summary"
[ -d "$FORKS_ROOT/bootstrap/.git" ] || fail "replay-all.sh should still rebuild missing managed clones"
rm -f "$FORKS_ROOT/bootstrap_refs/dirty.txt"

FAKEBIN="$ROOT/fake-bin"
mkdir -p "$FAKEBIN"
ln -s "$(command -v bash)" "$FAKEBIN/bash"
ln -s "$(command -v basename)" "$FAKEBIN/basename"
ln -s "$(command -v git)" "$FAKEBIN/git"
ln -s "$(command -v jq)" "$FAKEBIN/jq"
ln -s "$(command -v dirname)" "$FAKEBIN/dirname"

run_cmd env PATH="$FAKEBIN" /bin/bash "$FORKER_ROOT/doctor.sh"
assert_status 0 "doctor should treat pnpm as optional"
assert_contains "$CMD_OUTPUT" $'OK\ttool\tpnpm\toptional-for-conflicts-only' "doctor should report missing pnpm as optional"

run_cmd bash "$FORKER_ROOT/doctor.sh"
assert_status 0 "doctor should still succeed after workflow operations"
assert_contains "$CMD_OUTPUT" $'summary\tok=' "doctor should still print a summary"
assert_contains "$CMD_OUTPUT" $'\terror=0' "doctor should still report zero errors"

git -C "$FORKS_ROOT/managed" checkout -b side-merge >/dev/null 2>&1
printf '%s\n' 'merge side branch change' >> "$FORKS_ROOT/managed/README.md"
git -C "$FORKS_ROOT/managed" add README.md
git -C "$FORKS_ROOT/managed" commit -m 'side merge change' >/dev/null 2>&1
git -C "$FORKS_ROOT/managed" checkout wip >/dev/null 2>&1
git -C "$FORKS_ROOT/managed" merge --no-ff --no-edit side-merge >/dev/null 2>&1

run_cmd bash "$FORKER_ROOT/save.sh" managed
assert_status 1 "save.sh should reject merge commits in the local series"
assert_contains "$CMD_OUTPUT" 'linear local series' "save.sh should explain the linear-history requirement"

run_cmd bash "$FORKER_ROOT/status.sh" managed
assert_status 1 "status.sh should reject merge commits in the local series"
assert_contains "$CMD_OUTPUT" 'contains merge commits after LOCAL_BASE' "status.sh should surface merge commits after LOCAL_BASE"

printf '%s\n' 'PASS'
