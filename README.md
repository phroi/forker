# Forker

Deterministic record/replay for external repo forks.

Named after what it does: forker manages forked repositories — cloning, merging refs, resolving conflicts, and producing deterministic builds.

All fork entries are defined in `forks/config.json`. Scripts accept an entry name (e.g., `ccc`) as their first argument.

## Directory structure

```
forks/
├── .gitignore           # track only .pin/ and config.json
├── .pin/                # computed state per entry (committed)
│   └── ccc/
│       ├── HEAD
│       ├── manifest
│       ├── res-2.resolution
│       └── local-001-*.patch
├── config.json          # unified config, entries keyed by name
├── forker/              # fork management tool (bootstrapped on install)
├── ccc/                 # gitignored clone
├── contracts/           # gitignored clone (reference)
└── whitepaper/          # gitignored clone (reference)
```

## config.json

```json
{
  "ccc": {
    "upstream": "https://github.com/org/repo.git",
    "fork": "git@github.com:you/repo.git",
    "refs": ["42", "feature-branch", "releases/next"],
    "workspace": {
      "include": ["packages/*"],
      "exclude": ["packages/demo"]
    }
  },
  "contracts": {
    "upstream": "https://github.com/org/contracts.git",
    "refs": []
  }
}
```

- **upstream**: Git URL to clone from
- **fork**: SSH URL of developer fork, added as `fork` remote after replay
- **refs**: Merge refs — PR numbers, branch names, or commit SHAs (auto-detected). Empty = reference-only (shallow clone)
- **workspace**: Glob patterns for pnpm workspace inclusion/exclusion

## .pin/ format

```
forks/.pin/ccc/
  HEAD              # expected SHA after full replay
  manifest          # base SHA + merge refs (TSV, one per line)
  res-2.resolution  # conflict resolution for merge step 2 (gaps = no conflicts)
  local-001.patch   # local development patch
```

- **HEAD**: expected final SHA after everything (merges, patch.sh, local patches). Verified at end of replay
- **manifest**: TSV, one line per ref. Line 1 is the base commit; subsequent lines are merge refs applied sequentially onto `wip`
- **res-N.resolution**: counted conflict resolution for merge step N. Positional format with `CONFLICT ours=N base=M theirs=K resolution=R` headers — parser reads counts and skips lines, never inspects content. Human-readable and editable: you can inspect what was resolved, edit by hand, or diff across re-records
- **local-\*.patch**: standard unified diffs, applied in lexicographic order after merges + patch.sh, each as a deterministic commit

## How it works

1. **Auto-replay** — `.pnpmfile.cjs` runs at `pnpm install` time. If `.pin/<name>/manifest` exists but the clone doesn't, it auto-triggers `forks/forker/replay.sh` to rebuild from pins. Reference-only entries (no pins, empty refs) are shallow-cloned instead

2. **Workspace override** — `.pnpmfile.cjs` scans `forks/config.json` and rewrites matching dependencies to `workspace:*` when clones exist. This is necessary because `catalog:` specifiers resolve to a semver range _before_ pnpm considers workspace linking — even with `link-workspace-packages = true`, pnpm fetches from the registry without this hook. When no clone exists, the hook is a no-op and deps resolve from the registry normally

3. **Source-level types** — `patch.sh` rewrites fork package exports to point at `.ts` source instead of `.d.ts`, then creates a deterministic git commit (fixed author/date). This gives real-time type feedback — changes in fork source are immediately visible to stack packages without rebuilding. It also ensures record and replay produce the same HEAD hash

4. **Diagnostic filtering** — `tsgo-filter.sh` (at repo root) wraps `tsgo` and suppresses diagnostics originating from fork clone paths. Fork source may not satisfy the stack's strict tsconfig (`verbatimModuleSyntax`, `noImplicitOverride`, `noUncheckedIndexedAccess`), so the wrapper only fails on diagnostics from stack source. When no forks are cloned, packages fall back to plain `tsgo`

5. **Pending work safety** — `bash forks/forker/status.sh <name>` checks for uncommitted/unpushed work (exit 0 = safe to wipe, exit 1 = has work). The `record`, `clean`, and `reset` scripts guard against data loss automatically

## Recording

```bash
bash forks/forker/record.sh ccc          # refs from config.json
bash forks/forker/record.sh ccc 42 main  # override refs on CLI
```

Clones upstream, merges configured refs, resolves conflicts, runs patch.sh, applies local patches, writes .pin/. Commit the resulting `.pin/` directory so other contributors get the same build.

`record.sh` also regenerates the fork workspace entries in `pnpm-workspace.yaml` (between `@generated` markers) — manual edits to that section are overwritten on re-record.

### Ref auto-detection

Refs are auto-detected by pattern:

- `^[0-9a-f]{7,40}$` → commit SHA
- `^[0-9]+$` → GitHub PR number (fetched as `pull/N/head`)
- everything else → branch name

### Conflict resolution

Recording uses a tiered approach:

- **Tier 0**: Deterministic — one side matches base → take the other (zero tokens)
- **Tier 1**: Strategy classification — AI picks OURS/THEIRS/BOTH/GENERATE (~5 tokens per conflict)
- **Tier 2**: Code generation — AI generates merged code (hunks only, for GENERATE conflicts)

Resolutions are stored as counted resolution files in `.pin/<name>/res-N.resolution`.

## Developing in a fork

Work directly in `forks/<name>/` on the `wip` branch.

### Saving local patches

```bash
bash forks/forker/save.sh ccc [description]
```

Captures all changes (committed + uncommitted) relative to the pinned HEAD as a patch in `.pin/<name>/`. Patches survive re-records and replays.

Example:

1. Edit files in `forks/ccc/`
2. `bash forks/forker/save.sh ccc my-feature` → creates `.pin/ccc/local-001-my-feature.patch`
3. Edit more files
4. `bash forks/forker/save.sh ccc another-fix` → creates `.pin/ccc/local-002-another-fix.patch`
5. `bash forks/forker/clean.sh ccc && pnpm install` → replays merges + patches, HEAD matches

### Upstream contribution workflow

1. Develop and test on `wip`. Only push to the fork remote when changes are validated against the stack
2. `bash forks/forker/push.sh ccc` — cherry-picks your commits onto the PR branch
3. Push the PR branch: `cd forks/ccc && git push fork <pr-branch>:<remote-branch>`
4. Add the PR number to `refs` in `forks/config.json` — order PRs by target branch from upstream to downstream, so each group merges cleanly onto its base before the next layer begins
5. `bash forks/forker/record.sh ccc` and `pnpm check:full` to verify
6. Don't open upstream PRs prematurely — keep changes on the fork until production-ready

## Switching modes

| Mode                                      | Command                                                    |
| ----------------------------------------- | ---------------------------------------------------------- |
| Check for pending work                    | `bash forks/forker/status.sh ccc` (exit 0 = clean)         |
| Local fork (default when .pin/ committed) | `pnpm install` auto-replays                                |
| Published packages                        | `bash forks/forker/reset.sh ccc && pnpm install`           |
| Re-record from scratch                    | `bash forks/forker/record.sh ccc` (aborts if pending work) |
| Force re-replay                           | `bash forks/forker/clean.sh ccc && pnpm install`           |

## Requirements

- **Recording** (`record.sh`): AI Coworker CLI (`pnpm coworker:ask`) for conflict resolution + `jq`
- **Replay** (`pnpm install`): `jq` only — works for any contributor with just pnpm

## Licensing

This source code, crafted with care by [Phroi](https://phroi.com/), is freely available on [GitHub](https://github.com/phroi/forker/) and it is released under the [MIT License](./LICENSE).
