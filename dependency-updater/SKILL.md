---
name: dependency-updater
description: Update dependencies in the current repo (or every recently active repo in the repos/orgs given via REPOS/OWNERS) (npm/bun package.json, Python requirements/pyproject, Cargo, Go modules), verify by launching the app and running the full test suite, and open one pull request per repo. Use whenever the user asks to update dependencies, bump deps, run the updater agent, "freshen packages across my repos", or deal with outdated/vulnerable dependencies — even for a single repo.
---

# Dependency Updater Agent

Updates dependencies in the target repos (the current repo by default; with
`OWNERS`, every repo there active in the last month), verifies each repo still **builds, launches,
and passes its tests** after the bump, and opens a PR per repo. Never merges.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

## Workflow

### 1. Find candidates

```bash
scripts/find-update-candidates.sh
```

Emits one JSON line per target repo:
`{repo, pushedAt, open_update_pr}`. When expanding `OWNERS` the script skips
archived repos, forks, and repos not pushed in the last 30 days; a repo named
explicitly (or the current checkout) is always included. If `open_update_pr` is non-null, a previous update PR is still
open — **update that branch instead of opening a second PR**, or skip the repo
if the existing PR is already current.

### 2. Per repo: clone and branch

```bash
dir=$(mktemp -d "${TMPDIR:-/tmp}/dep-update.XXXXXX")
gh repo clone <repo> "$dir" -- --quiet && cd "$dir"
git checkout -b "deps/auto-update-$(date +%Y%m%d)"
```

Find every manifest, not just the root — monorepos are common here:
`find . -name node_modules -prune -o \( -name package.json -o -name requirements.txt -o -name pyproject.toml -o -name Cargo.toml -o -name go.mod \) -print`.

### 3. Update, per ecosystem

- **npm/bun** — `bunx npm-check-updates -u` in each package dir, then install
  with the manager the lockfile implies (bun/pnpm/yarn/npm) so the lockfile is
  regenerated. If verification later fails on a specific major bump, pin that
  one package back (`ncu -u --target minor --filter <pkg>`) rather than
  abandoning the whole update.
- **Python** — with `uv.lock`: `uv lock --upgrade && uv sync`. Plain
  `requirements.txt`: rewrite each pin to the latest version (check with
  `pip index versions <pkg>` or `pip list --outdated` inside a venv), then
  reinstall clean. `pyproject.toml` without a lockfile: raise the version
  bounds, reinstall.
- **Rust** — `cargo update`, and raise `Cargo.toml` versions for major bumps
  only if the build still passes.
- **Go** — `go get -u ./... && go mod tidy`.

### 4. Verify — this is the point of the skill, don't skim it

A dependency PR that was never run is worse than no PR. For each repo:

1. **Build**: whatever the repo's build is (`build` script, `cargo build`,
   `go build ./...`, `pip install -e .`).
2. **Full test suite**: `test` script / `pytest` / `cargo test` /
   `go test ./...`. All of it, not a subset.
3. **Launch the app** and prove it starts: for a web app run the dev/start
   script, wait for the port, `curl` it and check for a real 200 body; for a
   CLI run `--help` plus one real command; for a library, tests suffice. Read
   the repo's README/CLAUDE.md for the canonical way to run it. Kill whatever
   you started.

If something breaks, **fix it**: prefer adapting the repo's code to the new
API when the change is small and clearly correct (that's the value of an
agent over dependabot); otherwise walk the offending package back to the
newest version that works and note it in the PR. Iterate until green. If a
repo genuinely can't get green, close the branch out and report why — do not
open a red PR.

### 5. Open the PR

```bash
git add -A && git commit -m "chore(deps): update dependencies"
git push -u origin HEAD
gh pr create --title "chore(deps): update dependencies ($(date +%Y-%m-%d))" --body-file body.md
```

PR body must contain, in order: the marker
`<!-- generic-coding-agents:dependency-updater -->`, a table of bumps
(package, old → new, major bumps flagged), any code changes made to adapt to
new APIs, packages held back and why, and **verification evidence** — the test
summary line and proof the app launched. The auto-reviewer and ci-runner
agents will pick these PRs up automatically; the human merges.

### 6. Clean up and report

`rm -rf "$dir"`, kill stray servers. Report per repo: PR link, bump count,
held-back packages, or why it was skipped.

## Guardrails

- One PR per repo per sweep. Never merge, never push to the default branch.
- Don't touch repos with no dependency manifests — report them as skipped.
- Vendored/checked-in `node_modules` or lockfile-only repos: skip, note it.
- Security first: if `npm audit`/`pip-audit` shows a fixable vulnerability,
  say so prominently in the PR body — that PR is worth prioritizing.
- Work repos sequentially; a sweep is allowed to take hours. If the sweep is
  interrupted, finished repos have their PRs already — just resume with the
  candidate script (repos with an open update PR come back flagged).
