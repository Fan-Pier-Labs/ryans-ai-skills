# ci-runner — design notes

## How it runs CI

`scripts/ci-runner.sh` prefers the repo's **own GitHub workflows** over guessing:

1. **`act`** (if installed, with Docker running) — runs the real workflows in
   containers. Highest fidelity, heaviest dependency.
2. **`scripts/run-workflows.py`** — a workflow interpreter that parses
   `.github/workflows/*.yml` and executes the `pull_request`-triggered jobs on
   the host the way GitHub's runner would: same step order, same env layering
   (workflow → job → step), `defaults.run.working-directory`, `${{ }}`
   expressions (secrets/env/steps/matrix/github/runner contexts),
   `if: failure()/always()`, `continue-on-error`, `$GITHUB_ENV` /
   `$GITHUB_OUTPUT` / `$GITHUB_STEP_SUMMARY`, timeouts. `uses:` steps for
   checkout/setup-*/cache/artifacts are no-ops (the checkout exists, the host
   toolchain is used); other actions are skipped with a logged warning.
   `${{ secrets.X }}` resolves from the host environment, else empty — the
   same thing a fork PR sees. Matrixes run their first combination.
3. **Stack heuristics** — only when a repo has no `pull_request` workflows at
   all: lockfile-aware npm/bun/pnpm/yarn running whichever of
   lint/typecheck/build/test scripts exist; pytest; cargo; go.

## State lives on GitHub, not locally

There are no local state files. The **`local-ci` commit status on the head
SHA is the ledger**: before running a PR, the sweep asks
`repos/<repo>/commits/<sha>/status` and skips if a non-`pending` `local-ci`
status is already there. A lone `pending` (a crashed run) doesn't count, so
interrupted runs self-heal on the next sweep. This means any machine with `gh`
auth can run sweeps interchangeably, and "has CI run?" is answered by the PR
page itself.

## Getting change events instead of polling

Three options, in increasing order of immediacy:

1. **Sweep on an interval** (current default) — cron or `/loop 10m`. Simple,
   stateless, ~1 API call per repo per sweep plus one per open PR head.
2. **Conditional polling of the Events API** — `gh api repos/<r>/events` with
   the `If-None-Match` ETag header. GitHub returns `304 Not Modified` for free
   (304s don't count against the rate limit) and advertises the allowed
   cadence in `X-Poll-Interval`. Good for tightening latency to ~1 minute
   without webhooks.
3. **Real push events: `gh webhook forward`** — the official gh extension
   (`gh extension install cli/gh-webhook`) creates a temporary webhook and
   streams deliveries to a local URL over a websocket, no public endpoint
   needed:

   ```bash
   gh webhook forward --repo=<owner>/<repo> --events=push,pull_request --url=http://localhost:9000/hook
   ```

   Org-level (`--org=<org>`) covers every repo at once. Caveats: the
   forwarder is a long-lived foreground process per repo/org, it's built for
   development use (reconnects, but not guaranteed delivery), and personal
   accounts need per-repo forwarding. A tiny local receiver that
   runs `ci-runner.sh` on each delivery turns this into push-triggered CI.
   Missed deliveries are covered by keeping a slow fallback sweep (say,
   hourly) — the commit-status ledger makes overlap harmless.

## The all-local alternative

A different architecture worth considering: keep **everything on this
machine** and treat GitHub as just a git remote.

- **Detection**: maintain persistent mirrors (`git clone --mirror`) of every
  repo under e.g. `~/ci-mirrors/`. A loop runs `git fetch` on each (cheap,
  pure git protocol, no REST rate limits) and diffs
  `git for-each-ref refs/pull/*/head` before/after — new SHAs are the work
  queue. Latency is the fetch interval; a fetch of an unchanged repo is
  near-instant.
- **Execution**: `git worktree add` from the mirror per job — no re-cloning,
  no network in the hot path. Same runner scripts as above.
- **Results**: instead of posting statuses/comments, append to a local ledger
  (`results.jsonl` or SQLite) keyed by `(repo, pr, sha)` and render a static
  `dashboard.html`. The ledger doubles as the dedup state.

Trade-offs versus the GitHub-state design:

| | GitHub-state (current) | All-local |
| --- | --- | --- |
| Results visible on the PR page | ✅ statuses + comments | ❌ only on this machine |
| Works from any machine | ✅ ledger is remote | ❌ ledger is the machine |
| API rate usage | statuses/comments per run | ~zero (git protocol) |
| Change-detection latency | poll interval / webhook | fetch interval (~seconds) |
| Offline operation | ❌ | ✅ runs, posts later |

The two compose well as a **hybrid**: local mirrors for fast, rate-limit-free
change detection, GitHub statuses for publishing — swap the sweep's discovery
step for the mirror differ and keep `run_pr` as is.
