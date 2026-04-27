# Forker

Forker manages reference clones and managed forks under `forks/<name>/{repo,pin}`.

It manages:

- `reference`: read-only upstream mirror that fetches all remote branches and checks out the newest mirrored branch
- `managed`: writable, reproducible fork whose authoritative state lives in `forks/<name>/pin/`

Each entry root looks like:

```text
forks/<name>/
  repo/
  pin/
```

`repo/` is the live git clone. `pin/` is tracked fork state.
Only `forks/<name>/{repo,pin}` is live state. `forks/.stage/` is disposable scratch.

## Use This When

- Full workspace bootstrap: `bash forks/phroi_forker/repo/bootstrap-workspace.sh`
- Refresh all references: `bash forks/phroi_forker/repo/sync-all-references.sh`
- Refresh one reference clone: `bash forks/phroi_forker/repo/sync-reference.sh <name>`
- Remove one or more reference entries entirely: `bash forks/phroi_forker/repo/remove-reference.sh <name> [name ...]`
- Convert one clean read-only reference entry into a writable managed clone pinned at its current primary branch: `bash forks/phroi_forker/repo/reference-to-managed.sh <name>`
- Materialize missing managed clones: `bash forks/phroi_forker/repo/pins-to-missing-wips.sh`
- Safely replace one managed clone: `bash forks/phroi_forker/repo/rebuild-wip.sh <name>`
- Derive fresh pins (discarding old pins and saved series): `bash forks/phroi_forker/repo/rebuild-pins.sh <name> [ref ...]`
- Refresh pins (preserving saved work): `bash forks/phroi_forker/repo/upstream-to-pins.sh <name> [ref ...]`
- Drop pin state and convert one managed entry back to a reference clone: `bash forks/phroi_forker/repo/managed-to-reference.sh <name>`
- Materialize one missing managed clone from pins: `bash forks/phroi_forker/repo/pins-to-wip.sh <name>`
- Save committed `wip` work into pins: `bash forks/phroi_forker/repo/wip-to-series.sh <name>`
- Apply saved work onto a target branch, or the newest local `pr-*` if omitted: `bash forks/phroi_forker/repo/series-to-branch.sh <name> [target]`
- Inspect state: `bash forks/phroi_forker/repo/state.sh <name>`, `bash forks/phroi_forker/repo/state-all.sh`, `bash forks/phroi_forker/repo/health.sh`
- Dry-run replay: `bash forks/phroi_forker/repo/verify-pins.sh <name>`, `bash forks/phroi_forker/repo/verify-all-pins.sh`

## Rules That Matter

- `rebuild-wip.sh` is the only public managed command that may replace an existing clone.
- Reference clones are read-only between explicit mutation commands. `sync-reference.sh` may reset them to the newest mirrored upstream branch and relock them afterward.
- `remove-reference.sh` only removes missing or clean reference entries. It refuses local reference drift and stash entries because deleting the clone would drop that git state.
- A managed clone is safe to replace when it is missing, already matches pins, its saved series matches pins, or it is clean and exactly at upstream tip with no local-only commits.
- `managed-to-reference.sh` only works for replaceable managed entries. It deletes `pin/` and rewrites the config entry to `mode=reference`.
- `reference-to-managed.sh` only accepts a clean read-only reference mirror. It rebuilds from the upstream primary branch, records that branch as managed `base_branch`, and leaves a writable `wip` clone.
- `pins-to-wip.sh` is missing-only. If the clone already exists, use `rebuild-wip.sh`.
- `upstream-to-pins.sh` preserves the saved series. `rebuild-pins.sh` discards old pins, old saved series, and old recorded resolutions.
- `wip-to-series.sh` records committed history only. For pinned entries it expects a clean `wip` branch in `forks/<name>/repo` with a linear local series after `LOCAL_BASE`.
- `series-to-branch.sh` expects a clean `wip` whose live commit series matches the saved pin series.

## Managed Base Branch

- Managed entries may set `base_branch` in `forks/config.json`.
- Pin rebuilds start from `base_branch` when present, otherwise they fall back to the upstream default branch.
- `refs` still means extra upstream branches or PR refs merged on top of `base_branch`.

## Pin Model

```text
forks/<name>/pin/
  manifest
  LOCAL_BASE
  series/
    0001-fix-readme.patch
  HEAD
  res-N.resolution
```

- `manifest`: base commit plus exact merged refs and commits
- `LOCAL_BASE`: replayed tip after merges, before saved local commits
- `series/*.patch`: saved local commit series
- `HEAD`: deterministic replayed tip
- `res-N.resolution`: recorded merge conflict resolutions

## Notes

- Conflicted record/bootstrap paths shell out through `pnpm coworker:ask`; there is no standalone `coworker_ask` binary.
- Replay and verify reuse recorded `res-N.resolution` data.
- If a recorded merge SHA can no longer be fetched from upstream, rerun `rebuild-pins.sh`.
