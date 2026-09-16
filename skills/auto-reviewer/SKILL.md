---
name: auto-reviewer
description: Continuously scan every open, non-draft pull request in the current repo (or the repos/orgs given via REPOS/OWNERS) and post a deep thermo-nuclear code-quality review — with 🔴/🟡/🟢 status circles, a 1–5 risk score, and an opt-in product-direction check — on any PR whose latest commits have not yet been reviewed; also posts cross-PR merge-conflict notes and opens an issue when a blocking finding merges unaddressed. Use whenever the user asks to start the auto reviewer, review open PRs, babysit PRs, "run the review agent", "review anything that needs it", or wants continuous/automatic PR review coverage — even if they don't name the skill explicitly.
---

# Auto Reviewer Agent

A long-running review agent. Each pass it finds open, non-draft PRs in the
target repos (the current repo by default) that have had commits in the last 7 days and
have received **no feedback since their latest commit**, then runs a
thermo-nuclear code-quality review on each and posts the findings as a PR
comment. Every comment also carries a **risk score** (how much could break if
the PR is wrong) and, when the repo has a product vision on file, a
**direction check** (does this PR move the product toward where it is meant to
be in 6–12 months).

Three things do the work:

- `scripts/find-review-candidates.sh` — deterministic candidate discovery.
  Emits one JSON object per PR that needs a review. No AI judgment involved;
  trust its output. (It is a wrapper that calls
  `skills/shared/find-pr-candidates.sh`, the sweep every PR skill runs, with
  this skill's marker — call the wrapper, not the shared script.)
- `references/thermo-nuclear-review.md` — the full review standard (vendored
  from cursor/plugins' thermo-nuclear-code-quality-review skill). **Read it in
  full before reviewing the first PR of a session.** It defines the review
  rules, the tone, what to flag, and the output priorities. It is deliberately
  harsh; do not soften it.
- `visions/<owner>/<repo>.md` — optional, per repo. The product owner's
  written vision for where the product/feature should be in 6 months and a
  year. When present, the review judges every PR against it. See
  [Product vision](#product-vision-opt-in-per-repo) below.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

## The loop

This is a continuous agent, not a one-shot. Run it as a loop:

1. Run `scripts/find-review-candidates.sh`. Each output line is
   `{repo, number, title, url, head_sha, last_commit}`.
2. Review each candidate (below), one at a time.
3. **Check the open PRs in each touched repo against each other** for merge
   conflicts, and post a note on every PR involved. See
   [Cross-PR conflicts](#cross-pr-conflicts).
4. **Check what merged since the last pass.** A PR that merged while a 🔴
   finding on it was still unaddressed becomes a GitHub issue assigned to the
   PR's author. See [Merged with a blocking finding](#merged-with-a-blocking-finding).
5. Sleep / schedule the next pass ~20–30 minutes out and repeat. In Claude Code,
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

   Then, separately from the quality review:

   - **Score the risk** using the rubric in [Risk score](#risk-score). Risk is
     about blast radius if the PR is wrong, not about whether it is wrong.
   - **Check direction** if `visions/<owner>/<repo>.md` exists: read it in
     full, then decide whether the PR moves the product toward the stated
     6-month / 1-year picture, is orthogonal to it, or pulls against it. If
     there is no vision file, skip this entirely — do not guess the product's
     goals from the README.

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

   **Verdict:** <🔴 blocking issues | 🟡 needs restructuring | 🟢 would-approve>

   **Risk:** <🟢 1 | 🟢 2 | 🟡 3 | 🔴 4 | 🔴 5>/5 — <one line: what breaks if this is wrong>

   **Direction:** <🟢 toward the vision | 🟡 orthogonal | 🔴 against the vision> — <one line>

   ### Findings
   1. 🔴 **<file:line — one-line claim>** — <why it matters, what the cleaner
      structure looks like. Quote the standard's priorities: structural
      regressions first, code-judo opportunities second, spaghetti growth
      third...>
   2. 🟡 **<file:line — one-line claim>** — <...>

   ### Risk
   <2–4 lines: which touched areas drive the score (sensitive paths, blast
   radius, reversibility, coverage), and what the author could do to lower it
   — e.g. split the migration out, add a test around X, put it behind a flag.>

   ### Direction
   <Only when a vision file exists. 2–4 lines: which part of the vision this
   PR serves or undermines, quoting the vision where useful. If 🔴, name the
   specific goal or non-goal it collides with.>

   ### What's good
   🟢 <one or two lines — earned praise only, never filler>
   ```

   Omit the **Direction** line and section entirely when the repo has no
   vision file. Never omit **Risk**.

   **Status circles.** Every finding and the verdict carry a colored circle so
   the severity is readable at a glance without parsing the prose:

   | Circle | Meaning | When to use |
   | --- | --- | --- |
   | 🔴 | Block this PR | One of the standard's presumptive blockers (file crosses 1k lines, spaghetti branching in a shared path, missed code-judo move that would delete real complexity, boundary leak, duplicated canonical helper). Should not merge as-is. |
   | 🟡 | Warn | A real maintainability cost worth fixing, but not on its own a reason to hold the PR. |
   | 🟢 | Good | Used for the "What's good" section and for a would-approve verdict. Never attach 🟢 to a finding — a finding is by definition something to change. |

   The verdict circle is the worst circle among the findings: any 🔴 finding
   → 🔴 blocking issues; only 🟡 findings → 🟡 needs restructuring; no findings
   → 🟢 would-approve. Do not downgrade a verdict below its worst finding.

   A 🔴 **Direction** counts as a finding for this purpose (add it to the list:
   "builds toward a stated non-goal" is a blocker). A 🟡 direction does not —
   maintenance and orthogonal work are normal. **Risk never moves the
   verdict**: a clean, high-risk PR is still would-approve, and a messy,
   docs-only PR is still needs-restructuring. The two are reported side by
   side precisely so a reader can tell them apart.

   Follow the standard's output rules: a small number of high-conviction
   findings beats a long list of nits; findings ordered by the priority list in
   the reference (so 🔴 items naturally sort first); direct tone, no softening,
   no rudeness. If the PR is genuinely clean, say so in two sentences under a
   🟢 verdict and stop — do not invent findings to justify the comment.

4. **Clean up**: `rm -rf "$dir"` and kill anything you started.

## Single-PR invocation

When handed one PR — by `/pr-watcher`, or by a user naming a PR — do not run
the loop. The contract:

1. **Skip discovery.** `find-review-candidates.sh` is for sweeps.
2. **Idempotency first.** A marker comment for this exact head means it is
   already reviewed — stop and say so:

   ```bash
   gh api "repos/<repo>/issues/<N>/comments" --paginate      --jq '.[] | select(.body | contains("generic-coding-agents:auto-reviewer sha:<head_sha>")) | .id'
   ```
3. **Confirm the head.** `gh pr view <N> -R <repo> --json headRefOid,isDraft`.
   Draft → skip. Head moved since you were handed the SHA → review the
   *current* head and put its SHA in the marker; the stale SHA is nobody's
   business now.
4. Run **Reviewing one PR** as written. One comment, then clean up.

## Cross-PR conflicts

Two open PRs in the same repo can each merge cleanly into `main` and still not
merge with each other. Nobody sees that until the second one is rebased, so the
loop checks for it on every pass and says so on both PRs while the authors can
still coordinate.

**Scope.** Every repo that had at least one review candidate this pass, and
within it every open PR (drafts included — a draft still conflicts). Repos with
no recent activity are left alone.

**Mechanical check.** Fetch every open PR head into one shallow clone. First
check each PR against current `main` — a PR that merged cleanly yesterday can
stop merging today because something else landed (a file move is the usual
cause), and that is worth saying on the PR before its author finds out at
rebase time. Then run `git merge-tree` over each pair. `--write-tree` exits
non-zero on a conflict and `--name-only` lists the files:

```bash
git fetch -q origin main
for n in $PRS; do git fetch -q --depth 200 origin "pull/$n/head:pr-$n"; done
for n in $PRS; do
  out=$(git merge-tree --write-tree --name-only origin/main "pr-$n" 2>&1); rc=$?
  behind=$(git rev-list --count "$(git merge-base origin/main pr-$n)..origin/main")
  [ $rc -ne 0 ] && echo "#$n vs main ($behind behind): $(echo "$out" | sed -n '2,30p' | grep -v '^$' | grep -v Auto-merging | tr '\n' ' ')"
done
for a in $PRS; do for b in $PRS; do [ "$a" -lt "$b" ] || continue
  out=$(git merge-tree --write-tree --name-only "pr-$a" "pr-$b" 2>&1); rc=$?
  [ $rc -ne 0 ] && echo "#$a x #$b: $(echo "$out" | sed -n '2,30p' | grep -v '^$' | tr '\n' ' ')"
done; done
# Files touched by more than one PR — semantic overlap even without a textual conflict.
for n in $PRS; do git diff --name-only "$(git merge-base origin/main pr-$n)" "pr-$n" | sed "s|^|$n |"; done \
  | awk '{f[$2]=f[$2]" #"$1; c[$2]++} END {for (k in c) if (c[k]>1) print f[k], k}' | sort
```

Look for the semantic pair git cannot see at all: one PR deletes a symbol as
unused while another gives it a caller (`flushLog` in #105/#116 was the first
one caught). Whichever lands second fails typecheck in a file it did not
touch. Grep the deletions of one against the additions of the others.

A pairwise conflict between two PRs that are *both* behind `main` is often
the same stale base showing through twice — check whether the file either PR
"conflicts" on is one that only `main` moved. Say so rather than reporting a
phantom pair. When a PR in scope has just merged, drop it from the review list
and treat it as part of `main`.

**Judgment.** The textual list is the floor, not the finding. Read the
overlapping files for the conflicts git cannot see: the same helper moved to
two different homes, one PR deleting a duplicate that another PR re-adds, two
PRs adding the same enum member under different names. Those are the ones
worth a sentence each — and they are usually the reviewer's own findings from
the individual reviews, seen side by side.

**Stacks.** When a PR body says it is stacked on another open PR, every
member's diff includes the base's, and every pairwise conflict between two
stacks over `package.json`, a lockfile, or a config file is the stacks
meeting — inherent, not a finding. Post one note on each stack's *base* with a
suggested merge order (the base first, then members rebased to one-line diffs),
and on members only where something specific to that member conflicts. A PR
with pure stacking conflicts and nothing of its own gets no note.

**Post one note per PR per pass**, listing every other PR it conflicts with,
the conflicting files, the semantic overlap if any, and the one-line
resolution ("keep both lines", "agree on one home for `baseDomain` before the
second merges"). Say explicitly which PRs it does *not* conflict with, so a
clean bill is visible too. Start the body with its own marker — **not** the
review marker, or the discovery script would count it as a review and stop
re-reviewing that PR:

```markdown
<!-- generic-coding-agents:pr-conflicts self:<own head short> main:<main head short> pairs:<n>@<their head short>,... -->
## ⚠️ Merge conflicts with other open PRs
```

The marker is the dedup key: if a comment with the identical marker already
exists, the situation has not changed and nothing is posted. Any head moving —
the PR's own, a partner's, or `main`'s — changes the marker, so the note
refreshes exactly when it could be stale. That makes the marker a *ceiling*,
not a trigger: when the marker differs, recompute, and post only if the
substance changed — the set of conflicting PRs, the files involved, or whether
the PR merges into `main`. A rebase that moves every head by a few commits
while the same two PRs still collide on the same file is not news; posting it
again every pass is noise on a busy repo. A PR with no conflicts at all gets
no note, with one exception: when an earlier note on it named conflicts that
have since cleared, post a short "clean now" note so the stale one is not
read as current. Otherwise the clean bill appears in the other PRs' "no
conflict with" lines.
Conflict notes are comments, like reviews — never a formal review, never a
label, never a push.

## Merged with a blocking finding

A 🔴 finding is "block this PR". Once the PR has merged, the comment on it is
history nobody reopens, but the problem is now on `main`. So a 🔴 that reaches
`main` becomes an issue, assigned to the person who merged it in — the PR's
author — because they have the context to fix it and the standing to say it
was deliberate.

Once per pass, after the conflicts step, list what merged since the previous
pass in each touched repo:

```bash
since=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d '1 day ago' +%Y-%m-%d)
gh pr list -R <repo> --state merged --search "merged:>=$since" \
  --json number,headRefOid,mergeCommit,author,title
```

For each merged PR that carries a review comment whose `**Verdict:**` line is
🔴, decide whether the finding was addressed before the merge:

- **Addressed** — a later review on a newer head came back 🟡 or 🟢, or the
  commits between the 🔴-reviewed SHA and the merged head rewrite the files the
  finding named (read them; a merge-from-main commit does not count). Nothing
  to do.
- **Unaddressed** — the merged head *is* the 🔴-reviewed SHA, or the commits
  after it do not touch what the finding named. Open the issue.

The same applies when a review you are writing lands on a PR that merged
between discovery and posting: post the review anyway (the marker still
matters), and if its verdict is 🔴, open the issue in the same pass. And when a
follow-up or the whole-codebase audit finds a 🔴 that traces to a specific
merged PR, that is an issue too — the trigger is "a 🔴 is on `main` and has a
PR to point at", not the timing.

**The issue.** One per PR, however many 🔴 findings it carried — bundle them.
Title: `🔴 <the finding's headline, as a sentence>`. Body, in order:

```markdown
<!-- generic-coding-agents:auto-reviewer issue pr:<N> sha:<merged head sha> -->
Opened because #<N> merged with this finding unaddressed
(review: <link to the 🔴 comment>).

## What
<the finding, with permalinks to the lines at the merge commit>

## Why it blocks
<one paragraph: what breaks, or what it costs every reader from now on>

## Fix
<the concrete restructuring the review asked for>
```

Create it with `gh issue create -R <repo> --title … --body-file … --assignee
<PR author login> --label code-quality` (drop `--label` if the repo has no such
label; do not create labels). If the author cannot be assigned — a bot, an
outside contributor, or `gh` refuses — create it unassigned and say so in the
first line of the body. Before creating, search for the marker
(`gh issue list --state all --search "auto-reviewer issue pr:<N>"`): one issue
per PR, ever. If an audit issue already covers the same problem (the audit
marker), do not open a second — comment the PR link on the existing issue
instead.

Never open an issue for a 🟡, and never for a PR that is still open: the review
comment is the channel while the PR can still change. Never open one from a
risk score alone — risk is not a finding.

## Risk score

Answer one question: **if this PR is wrong, how bad is it and how hard is it
to undo?** Score 1–5. This is independent of code quality — a beautifully
structured migration is still a 5.

| Score | Circle | Profile |
| --- | --- | --- |
| 1 | 🟢 | Nothing at runtime changes. Docs, comments, test-only changes, lint/format config, CI config that only affects test runs. |
| 2 | 🟢 | Leaf code with few callers, purely additive, or behind a flag that is off. Existing behavior untouched. Covered by tests. |
| 3 | 🟡 | Changes existing behavior in a module with several callers, touches a shared utility or a hot path, or alters a public UI flow. Tests exist but the change is not fully exercised by them, or the diff is large enough that review alone can't vouch for it. |
| 4 | 🔴 | Touches a sensitive area: auth/permissions, billing/payments, data persistence, external API or webhook contracts, concurrency/locking, deploy or prod configuration, secrets handling. Or a wide blast radius (core shared module, framework glue) with thin coverage. |
| 5 | 🔴 | Hard or impossible to roll back: destructive/irreversible migrations, data backfills or deletions, key/credential rotation, changes to the release/deploy pipeline itself, security-boundary code. Or a 4 that is also large and under-tested. |

Weigh these factors, in roughly this order:

1. **Reversibility** — can a revert fully restore the previous state? Schema
   and data changes usually can't.
2. **Sensitivity of touched paths** — the list under 4 above, plus anything
   the repo's vision file names under `## Sensitive areas`.
3. **Blast radius** — how many callers / users / systems see the change. Grep
   the checkout for callers; don't guess from the diff.
4. **Coverage** — do the tests in the PR (or existing tests) actually execute
   the changed lines? A PR that changes logic and touches no tests is at least
   a 3.
5. **Size** — a 2,000-line diff is riskier than a 20-line one doing the same
   thing, because it is harder to review correctly.

Take the highest-scoring factor as the floor and adjust up by one if two or
more factors independently land there. Mixed PRs (a risky core change plus
docs) score on the riskiest part — and the **Risk** section should say the PR
would be lower-risk if split.

## Product vision (opt-in, per repo)

The direction check is off until the product owner writes a vision file. This
is deliberate: guessing a product's goals from its README produces confident
nonsense, and a direction verdict is only useful when it is measured against
something the owner actually said.

**To enable it for a repo**, copy `visions/TEMPLATE.md` to
`visions/<owner>/<repo>.md` and fill it in. The template asks for a lengthy,
concrete description — where the product is today, what it should look like
in 6 months, what it should look like in a year, what it is explicitly *not*
going to become, and which areas of the code are sensitive. Bullet-point
slogans are not enough for the agent to reason about; the template explains
what "enough" looks like.

**When reviewing with a vision on file:**

- Read the whole vision file before reading the diff, so the PR is judged
  against the destination rather than the destination reinterpreted to fit
  the PR.
- 🟢 **toward** — the PR builds a piece of the 6-month or 1-year picture, or
  removes something the vision says should go. Say which piece.
- 🟡 **orthogonal** — maintenance, refactors, bug fixes, dependency bumps,
  small features that neither advance nor contradict the vision. Most PRs
  land here; that is fine and not a criticism.
- 🔴 **against** — the PR builds toward a stated non-goal, entrenches an
  architecture the vision says must change, or spends significant effort on a
  direction the vision has ruled out. Quote the line of the vision it
  collides with. This becomes a blocking finding.
- If the vision file is thin (well under the length the template asks for, or
  missing the 6-month / 1-year sections), do not run the direction check.
  Post the review without a Direction line and tell the user in the pass
  summary that the vision for `<owner>/<repo>` is too thin to review against.
- Never edit a vision file yourself. If a PR makes it obvious the vision is
  stale, say so in the pass summary and let the owner update it.

## Guardrails

- **Comments and issues only.** Never push commits, never merge, never close
  PRs, never request changes formally. The agent's write surface is one comment
  per head SHA per PR, one conflict note per PR per change in the conflict
  picture, and one issue per merged PR that carried an unaddressed 🔴 (see
  [Merged with a blocking finding](#merged-with-a-blocking-finding)).
- One comment per pass per PR. If a PR gets new commits later, the next pass
  posts a fresh comment (the old one stays as history).
- Skip PRs whose diff is pure lockfile/generated churn — post nothing rather
  than review noise. (Vendored deps, `bun.lock`, build output.)
- If a repo fails to clone or a `gh` call 404s (deleted repo, permissions),
  skip it and move on; report failures in the pass summary, don't retry in a
  tight loop.
- Keep a short per-pass summary for the user: how many candidates, which PRs
  got reviewed (with verdict, risk score, and direction circle for each),
  which PR pairs conflict, which merged PRs got an issue (or were checked and
  did not need one), links to the posted comments and issues, and any repos
  whose vision file is missing or too thin.

## Tuning

The script reads env vars: `DAYS` (activity window, default 7), `REPOS`
(space-separated `owner/repo`), `OWNERS` (space-separated GitHub users/orgs), `MARKER`
(comment marker). With neither `REPOS` nor `OWNERS` set it targets the current repo.
