# Forker

Deterministic fork management for external repositories.

Forker manages:

- `reference`: shallow clone kept current from upstream
- `managed`: reproducible fork whose authoritative state lives in `forks/<name>/pin/`

Each entry root looks like:

```text
forks/<name>/
  repo/
  pin/
```

`repo/` is the live git clone. `pin/` is tracked fork state.
Only `forks/<name>/{repo,pin}` is live state. `forks/.stage/` is disposable scratch.

## Start Here

- In devcontainer, `postCreateCommand` bootstraps the full workspace automatically.
- Run commands from the repo root.
- Tooling: `git` 2.22+, `jq`, `mv` with `--exchange`, and `pnpm` only when conflict resolution needs `pnpm coworker:ask`.
- Manual fresh-repo setup:

```bash
mkdir -p forks/phroi_forker
git clone --filter=blob:none https://github.com/phroi/forker.git forks/phroi_forker/repo
bash forks/phroi_forker/repo/bootstrap-workspace.sh
```

- If setup looks wrong, run `bash forks/phroi_forker/repo/health.sh`.

## Use This When

- Full workspace bootstrap: `bash forks/phroi_forker/repo/bootstrap-workspace.sh`
- Refresh all references: `bash forks/phroi_forker/repo/sync-all-references.sh`
- Refresh one reference clone: `bash forks/phroi_forker/repo/sync-reference.sh <name>`
- Materialize missing managed clones: `bash forks/phroi_forker/repo/pins-to-missing-wips.sh`
- Safely replace one managed clone: `bash forks/phroi_forker/repo/rebuild-wip.sh <name>`
- Derive fresh pins (discarding old pins and saved series): `bash forks/phroi_forker/repo/rebuild-pins.sh <name> [ref ...]`
- Refresh pins (preserving saved work): `bash forks/phroi_forker/repo/upstream-to-pins.sh <name> [ref ...]`
- Materialize one missing managed clone from pins: `bash forks/phroi_forker/repo/pins-to-wip.sh <name>`
- Save committed `wip` work into pins: `bash forks/phroi_forker/repo/wip-to-series.sh <name>`
- Apply saved work onto a target branch, or the newest local `pr-*` if omitted: `bash forks/phroi_forker/repo/series-to-branch.sh <name> [target]`
- Inspect state: `bash forks/phroi_forker/repo/state.sh <name>`, `bash forks/phroi_forker/repo/state-all.sh`, `bash forks/phroi_forker/repo/health.sh`
- Dry-run replay: `bash forks/phroi_forker/repo/verify-pins.sh <name>`, `bash forks/phroi_forker/repo/verify-all-pins.sh`

## Rules That Matter

- `rebuild-wip.sh` is the only public managed command that may replace an existing clone.
- A managed clone is safe to replace when it is missing, already matches pins, its saved series matches pins, or it is clean and exactly at upstream tip with no local-only commits.
- `pins-to-wip.sh` is missing-only. If the clone already exists, use `rebuild-wip.sh`.
- `upstream-to-pins.sh` preserves the saved series. `rebuild-pins.sh` discards old pins, old saved series, and old recorded resolutions.
- `wip-to-series.sh` records committed history only. For pinned entries it expects a clean `wip` branch in `forks/<name>/repo` with a linear local series after `LOCAL_BASE`.
- `series-to-branch.sh` expects a clean `wip` whose live commit series matches the saved pin series.

## Pin Model

```text
forks/<name>/pin/
  manifest
  LOCAL_BASE
  series/
  HEAD
  res-N.resolution
```

- `manifest`: base commit plus exact merged refs and commits
- `LOCAL_BASE`: replayed tip after merges, before saved local commits
- `series/*.patch`: saved local commit series
- `HEAD`: deterministic replayed tip
- `res-N.resolution`: recorded merge conflict resolutions

## Notes

- Public scripts are thin wrappers; destructive workflow logic lives in sourced helpers.
- Conflicted record/bootstrap paths shell out through `pnpm coworker:ask`; there is no standalone `coworker_ask` binary.
- Replay and verify reuse recorded `res-N.resolution` data.
- If a recorded merge SHA can no longer be fetched from upstream, rerun `rebuild-pins.sh`.
