---
name: ci-runner
description: Run CI locally for every open pull request across the configured GitHub accounts (OWNERS; defaults to the authenticated gh user and their orgs) — a stand-in for GitHub Actions while the account is out of CI credits. Executes each repo's own .github/workflows YAML on this machine via a workflow interpreter, and posts the result back as a commit status (plus a log comment on failure). Use whenever the user asks to run CI on PRs, "check if my PRs pass", start the CI agent, run tests across open PRs, or mentions GitHub Actions being out of credits/minutes.
---

# CI Runner Agent

When GitHub Actions credits/minutes are exhausted, this agent runs CI on the
local machine instead. It is **entirely deterministic** —
one script does everything, and once started it needs no model judgment:

```bash
scripts/ci-runner.sh          # one full sweep over both owners
```

What one sweep does, per open non-draft PR whose head SHA has no `local-ci`
commit status yet:

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

## Running it as an agent

The script is single-sweep by design; looping is the harness's job. When asked
to "start the CI runner", run it on an interval — `/loop 10m` in Claude Code,
or plain cron:

```bash
*/10 * * * * /path/to/generic-coding-agents/ci-runner/scripts/ci-runner.sh >> ~/.cache/generic-coding-agents/ci-runner/sweep.log 2>&1
```

For push-driven runs instead of polling (`gh webhook forward`, Events-API
ETag polling) and a fully local mirror-based architecture, see
[README.md](README.md) in this directory.

After each sweep, relay the script's summary table (printed at the end: PR,
result, duration) to the user. Zero-work sweeps are normal.

## Judgment calls (the only non-deterministic part)

- The interpreter logs a `WARN` for every workflow feature it degrades
  (skipped third-party action, unresolved expression, reduced matrix). If a
  failure looks caused by a degradation rather than the PR, say so in the
  report instead of letting the red status stand unexplained.
- Jobs needing `container:`/`services:` are skipped without Docker — if those
  repos matter, suggest installing Docker + `act`.
- If the same PR fails repeatedly on the same infrastructure error (missing
  system dep, disk full), fix the environment or tell the user — don't let the
  loop re-fail silently forever.
- Never "fix" a failing PR from this skill. This agent reports; the repair work
  belongs to a human or a different session.

## Tuning

Env vars: `OWNERS` (space-separated users/orgs; default: the authenticated `gh` user plus their orgs), `DAYS` (repo-activity
window, default 30), `STATUS_CONTEXT` (default `local-ci`), `KEEP_WORK=1` to
keep work directories for debugging. Secrets a workflow needs (e.g.
`SOME_API_TEST_CREDS`) can be exported in the sweep's environment.
