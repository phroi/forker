# Forker

Deterministic fork management for external repositories.

Forker manages two entry modes from `forks/config.json`:

- `managed`: replayable forks stored in `forks/.pin/<name>/`
- `reference`: shallow clones kept current with `update.sh`

## Config

```json
{
  "ckb-devrel_ccc": {
    "upstream": "https://github.com/org/repo.git",
    "fork": "git@github.com:you/repo.git",
    "mode": "managed",
    "refs": ["42", "feature-branch"]
  },
  "nervosnetwork_ckb": {
    "upstream": "https://github.com/org/other-repo.git",
    "mode": "reference"
  }
}
```

- `upstream`: clone source
- `fork`: optional push remote for `push.sh`
- `mode`: `managed` or `reference`
- `refs`: optional managed merge refs; empty means bootstrap from upstream HEAD

## Managed Pins

Managed state lives in `forks/.pin/<name>/`.

```text
forks/.pin/ckb-devrel_ccc/
  HEAD
  LOCAL_BASE
  manifest
  res-2.resolution
  series/
    0001.patch
    0002.patch
```

- `manifest`: base commit plus merged refs
- `LOCAL_BASE`: replayed tip after merges, before saved local commits
- `series/*.patch`: saved local commit series from `git format-patch`
- `HEAD`: deterministic replayed tip after `git am`
- `res-N.resolution`: counted merge conflict resolutions

## Core Commands

Reference entries:

```bash
bash forks/phroi_forker/update.sh nervosnetwork_ckb
bash forks/phroi_forker/update-all.sh
```

- bootstrap or refresh shallow reference clones
- skip dirty clones instead of overwriting them

Managed entries:

```bash
bash forks/phroi_forker/record.sh ckb-devrel_ccc
bash forks/phroi_forker/replay.sh ckb-devrel_ccc
bash forks/phroi_forker/save.sh ckb-devrel_ccc
bash forks/phroi_forker/push.sh ckb-devrel_ccc pr-123
```

- `record.sh`: rebuild pins from upstream plus configured refs
- `replay.sh`: rebuild a missing managed clone from pins, using the recorded merge SHAs after fetching the configured refs
- `save.sh`: save the committed range from `LOCAL_BASE..wip` as `series/*.patch`
- `push.sh`: cherry-pick the saved `wip` series onto a target branch

## Save Workflow

`save.sh` is commit-series based.

- requires a clean worktree
- requires `wip` for already pinned entries
- saves committed history only; uncommitted work must be committed or stashed first
- requires a linear local series after `LOCAL_BASE`; merge commits are not allowed there
- rewrites the whole saved series each time
- bootstrap save for an unpinned managed clone derives the managed base with `record.sh`, then stores commits on top of that base
- bootstrap save only works when the live clone is already based on that derived managed base; otherwise record first

After `save.sh`, the live clone is still your live branch state. If you want the canonical replayed `wip`, clean and replay.

## Push Workflow

`push.sh` requires:

- a clean `wip` branch
- a live commit series that matches the saved pin series
- a linear local series after `LOCAL_BASE`
- a target branch that already exists locally, or as `origin/<target>` or `fork/<target>`
- if the target branch already contains a prefix of the saved series, `push.sh` only cherry-picks the missing suffix

If the target is omitted, `push.sh` uses the most recently updated local `pr-*` branch.

## Pin Preflight

```bash
bash forks/phroi_forker/verify-pins.sh ckb-devrel_ccc
bash forks/phroi_forker/verify-pins-all.sh
```

- `verify-pins.sh`: dry-run replay for one managed entry without touching the live clone
- `verify-pins-all.sh`: run the same dry-run across all managed entries and print a summary

## Safety Commands

```bash
bash forks/phroi_forker/status.sh ckb-devrel_ccc
bash forks/phroi_forker/status-all.sh
bash forks/phroi_forker/clean.sh ckb-devrel_ccc
bash forks/phroi_forker/replay-all.sh
bash forks/phroi_forker/reset.sh ckb-devrel_ccc
bash forks/phroi_forker/doctor.sh
```

- `status.sh`: safe-to-wipe check for one entry
- `status-all.sh`: same for all configured entries
- `clean.sh`: remove a safe clone
- `replay-all.sh`: replay missing managed clones, skip safe existing ones, continue past failures
- `reset.sh`: managed-only full reset of clone plus pins
- `doctor.sh`: read-only validation of tools, config, pin shape, and clone state

## Conflict Resolution

Managed recording resolves merge conflicts in this order:

1. deterministic reuse when one side matches base or both sides match
2. reuse of previously recorded resolutions when fingerprints still match
3. coworker classification for simple keep/concat choices
4. coworker generation only for conflicts that still need a custom merge

Replay uses recorded `res-N.resolution` data and does not need the assistant.
Replaying a managed fork still depends on the recorded merge SHAs remaining available from upstream after fetching their named refs. If a recorded SHA is no longer fetchable, re-record.

## Requirements

- `git`, `jq`
- `pnpm coworker:ask` for conflicted `record.sh`, and for bootstrap `save.sh` when deriving a managed base that hits conflicts

## Scope

This checkout documents only core forker behavior.
