---
name: ci-runner
description: Run CI locally for every open pull request in the current repo (or the repos/orgs given via REPOS/OWNERS) — a stand-in for GitHub Actions while the account is out of CI credits. Executes each repo's own .github/workflows YAML on this machine via a workflow interpreter, several PRs in parallel, and posts the result back as a commit status (plus a log comment on failure). Runs either on an interval or driven by GitHub webhook deliveries. Use whenever the user asks to run CI on PRs, "check if my PRs pass", start the CI agent, run tests across open PRs, or mentions GitHub Actions being out of credits/minutes.
---

# CI Runner Agent

When GitHub Actions credits/minutes are exhausted, this agent runs CI on the
local machine instead. It is **entirely deterministic** —
one script does everything, and once started it needs no model judgment:

```bash
scripts/ci-runner.sh          # one full sweep over the target repos (default: the current repo)
scripts/watch.sh              # stay running: CI on GitHub events, polling if events are unavailable
```

`ci-runner.sh` is one sweep and exits; `watch.sh` is the long-running front end.
Discovery and execution are separate modes, so any trigger can drive the same
executor:

| Mode | What it does |
| --- | --- |
| `ci-runner.sh` (default) | discover, run up to `$JOBS` PRs **in parallel**, print the summary |
| `ci-runner.sh --discover` | print work items as `repo<TAB>pr<TAB>sha` |
| `ci-runner.sh --repos` | print the resolved target repos |
| `ci-runner.sh --run-one REPO PR SHA` | run exactly one PR (what the fan-out and the webhook receiver call) |

What one sweep does, per open non-draft PR whose head SHA has no `local-ci`
commit status yet (up to `JOBS` of these at a time, default 4):

1. Shallow-clones the repo and checks out the PR head (`pull/N/head`).
2. Runs the repo's **own CI definition**, in order of preference:
   - `act` + Docker (if ever installed) — the real workflows, containerized;
   - `scripts/run-workflows.py` — interprets `.github/workflows/*.yml` and
     runs the `pull_request` jobs on this machine the way GitHub's runner
     would (step order, env layering, working-directory defaults, `${{ }}`
     expressions, `if:`/`continue-on-error`, `$GITHUB_ENV`/`$GITHUB_OUTPUT`;
     checkout/setup/cache actions become no-ops, secrets resolve from the
     host env or empty like a fork PR);
   - stack heuristics (lockfile-aware node scripts, pytest, cargo, go) only
     when the repo has no `pull_request` workflows at all.
3. Posts a **commit status** on the head SHA (context `local-ci`) — visible in
   the PR's checks area.
4. On failure, posts/updates one PR comment (marker
   `generic-coding-agents:ci-runner`) with the tail of the log. The same
   comment is edited to ✅ when a later run goes green — never a comment per run.

**No local state.** The `local-ci` status on the head SHA is itself the
"already ran" ledger — the sweep queries it and skips finished commits, so any
machine can run sweeps and interrupted runs (stuck at `pending`) self-heal.
New commits on a PR make it eligible again automatically.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

The cron form below runs outside any checkout, so give it `REPOS` or `OWNERS`
explicitly.

## Running it continuously

**Preferred: `scripts/watch.sh`.** It stays running and reacts to GitHub
events instead of polling for them — `gh webhook forward` (the official
`cli/gh-webhook` extension) creates a temporary webhook and streams
deliveries over a websocket, so no public endpoint is needed;
`webhook-receiver.py` turns each `push` / `pull_request` delivery into a
`--run-one` call.

```bash
REPOS='owner/repo' scripts/watch.sh
```

Creating that webhook **needs admin on the repo**. If any part of the event
path fails — extension not installable, no admin rights, forwarder dies later
— `watch.sh` logs a `WARNING` and degrades to interval polling, which needs no
special permission. It never exits just because events are unavailable. Even
in event mode a slow fallback sweep keeps running, because `gh webhook
forward` is a development tool with no delivery guarantee; the commit-status
ledger makes the overlap harmless.

**Alternative: sweep on an interval.** `ci-runner.sh` is single-sweep by
design, so looping is the harness's job — `/loop 15m` in Claude Code, or cron:

```bash
*/15 * * * * REPOS='owner/repo' /path/to/generic-coding-agents/ci-runner/scripts/ci-runner.sh >> ~/.cache/generic-coding-agents/ci-runner/sweep.log 2>&1
```

Size the interval above the sweep's wall-clock time, or ticks overlap. With
`JOBS=4` a sweep costs roughly `ceil(PRs / 4) x per-PR time`.

For the Events-API ETag option and a fully local mirror-based architecture,
see [README.md](README.md) in this directory.

After each sweep, relay the script's summary table (printed at the end: PR,
result, duration) to the user. Zero-work sweeps are normal.

## Judgment calls (the only non-deterministic part)

- The interpreter logs a `WARN` for every workflow feature it degrades
  (skipped third-party action, unresolved expression, reduced matrix). If a
  failure looks caused by a degradation rather than the PR, say so in the
  report instead of letting the red status stand unexplained.
- Jobs needing `container:`/`services:` are skipped without Docker — if those
  repos matter, suggest installing Docker + `act`.
- Parallelism has two failure modes worth naming rather than retrying blindly:
  workflows that bind a **fixed port** collide when two jobs run at once, and
  a high `JOBS` on a laptop thrashes RAM/disk and shows up as unrelated-looking
  timeouts. If failures appear only under load and pass when re-run alone,
  lower `JOBS` — don't report them as PR breakage.
- If the same PR fails repeatedly on the same infrastructure error (missing
  system dep, disk full), fix the environment or tell the user — don't let the
  loop re-fail silently forever.
- Never "fix" a failing PR from this skill. This agent reports; the repair work
  belongs to a human or a different session.

## Tuning

Env vars: `REPOS` (space-separated `owner/repo`), `OWNERS` (space-separated
users/orgs; neither set → the current repo), `DAYS` (repo-activity window when
expanding `OWNERS`, default 30), `ONLY` (substring filter on the repo slug),
`JOBS` (PRs run concurrently, default 4), `STATUS_CONTEXT` (default
`local-ci`), `FORCE=1` to re-run heads that already have a status,
`KEEP_WORK=1` to keep work directories for debugging. `watch.sh` adds
`POLL_INTERVAL` (polling-mode gap, default 900s) and `FALLBACK_SWEEP`
(event-mode safety-net gap, default 3600s). Secrets a workflow needs (e.g.
`SOME_API_TEST_CREDS`) can be exported in the sweep's environment.
