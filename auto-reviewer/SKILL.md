---
name: auto-reviewer
description: Continuously scan every open, non-draft pull request across the configured GitHub accounts (OWNERS; defaults to the authenticated gh user and their orgs) and post a deep thermo-nuclear code-quality review on any PR whose latest commits have not yet been reviewed. Use whenever the user asks to start the auto reviewer, review open PRs, babysit PRs, "run the review agent", "review anything that needs it", or wants continuous/automatic PR review coverage — even if they don't name the skill explicitly.
---

# Auto Reviewer Agent

A long-running review agent. Each pass it finds open, non-draft PRs in the
configured owners (`OWNERS`) that have had commits in the last 7 days and
have received **no feedback since their latest commit**, then runs a
thermo-nuclear code-quality review on each and posts the findings as a PR
comment.

Two files do the work:

- `scripts/find-review-candidates.sh` — deterministic candidate discovery.
  Emits one JSON object per PR that needs a review. No AI judgment involved;
  trust its output.
- `references/thermo-nuclear-review.md` — the full review standard (vendored
  from cursor/plugins' thermo-nuclear-code-quality-review skill). **Read it in
  full before reviewing the first PR of a session.** It defines the review
  rules, the tone, what to flag, and the output priorities. It is deliberately
  harsh; do not soften it.

## The loop

This is a continuous agent, not a one-shot. Run it as a loop:

1. Run `scripts/find-review-candidates.sh`. Each output line is
   `{repo, number, title, url, head_sha, last_commit}`.
2. Review each candidate (below), one at a time.
3. Sleep / schedule the next pass ~20–30 minutes out and repeat. In Claude Code,
   prefer the `/loop` skill or `ScheduleWakeup` over a foreground `sleep`. A
   pass with zero candidates is a normal no-op — just note it and wait.

The script is idempotent: once a review comment is posted, that PR won't
reappear until it gets new commits, because the marker comment's timestamp is
newer than the last commit. Never review the same head SHA twice.

## Reviewing one PR

1. **Check out the real code.** The diff alone is not enough for a structural
   review — you need the surrounding files to judge abstractions, file sizes,
   and canonical helpers. Clone shallow into the scratchpad:

   ```bash
   dir=$(mktemp -d "${TMPDIR:-/tmp}/auto-review.XXXXXX")
   gh repo clone <repo> "$dir" -- --depth 50 --quiet
   cd "$dir" && git fetch --depth 50 origin "pull/<N>/head:pr-<N>" && git checkout "pr-<N>"
   gh pr diff <N> -R <repo> > /tmp/pr-<N>.diff
   ```

2. **Apply the standard** in `references/thermo-nuclear-review.md`. Read the
   full diff, then read every touched file in full (and the files they lean
   on). Hunt for the "code judo" moves the standard demands: restructurings
   that delete complexity, not rearrange it. Also check the mechanical
   tripwires: files pushed past 1000 lines, new ad-hoc conditionals in shared
   paths, thin wrappers, cast/optionality churn, duplicated helpers.

3. **Post the review as a PR comment** (not a formal GitHub review — most of
   these PRs are authored by the same account this agent runs as, and GitHub
   forbids reviewing your own PR):

   ```bash
   gh pr comment <N> -R <repo> --body-file /tmp/review-body.md
   ```

   The body must start with the marker line — the discovery script keys on it:

   ```markdown
   <!-- generic-coding-agents:auto-reviewer sha:<head_sha> -->
   ## ☢️ Thermo-nuclear review — `<head_sha short>`

   **Verdict:** <would-approve | needs restructuring | blocking issues>

   ### Findings
   1. **<file:line — one-line claim>** — <why it matters, what the cleaner
      structure looks like. Quote the standard's priorities: structural
      regressions first, code-judo opportunities second, spaghetti growth
      third...>

   ### What's good
   <one or two lines — earned praise only, never filler>
   ```

   Follow the standard's output rules: a small number of high-conviction
   findings beats a long list of nits; findings ordered by the priority list in
   the reference; direct tone, no softening, no rudeness. If the PR is genuinely
   clean, say so in two sentences and stop — do not invent findings to justify
   the comment.

4. **Clean up**: `rm -rf "$dir"` and kill anything you started.

## Guardrails

- **Comment only.** Never push commits, never merge, never close PRs, never
  request changes formally. The agent's entire write surface is one comment per
  head SHA per PR.
- One comment per pass per PR. If a PR gets new commits later, the next pass
  posts a fresh comment (the old one stays as history).
- Skip PRs whose diff is pure lockfile/generated churn — post nothing rather
  than review noise. (Vendored deps, `bun.lock`, build output.)
- If a repo fails to clone or a `gh` call 404s (deleted repo, permissions),
  skip it and move on; report failures in the pass summary, don't retry in a
  tight loop.
- Keep a short per-pass summary for the user: how many candidates, which PRs
  got reviewed, links to the posted comments.

## Tuning

The script reads env vars: `DAYS` (activity window, default 7), `OWNERS`
(space-separated GitHub users/orgs; default: the authenticated `gh` user plus their orgs), `MARKER` (comment marker).
