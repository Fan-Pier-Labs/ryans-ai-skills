---
name: enable-more-lint-or-ts-checks
description: Find TypeScript compiler options or ESLint rules worth enabling in the current repo, measure their real cost, prove each one can actually fail, and land them in pull requests — one PR per check that needs real code changes, trivial no-op enablements batched — with the repo's full verification matrix green on every PR. Use whenever the user asks to tighten lint or type checking, "turn on stricter TypeScript", "enable more eslint rules", "harden the linter", "why isn't noUncheckedIndexedAccess on", asks to enable a specific check or rule, wants another round of lint-hardening, or asks what strictness the project is leaving on the table. For grading a repo's existing quality without changing code, use code-quality-audit instead.
---

# Enable More Lint or TS Checks

Find checks worth enabling — TypeScript compiler options, typescript-eslint rules,
core ESLint rules, or lint plugins — measure their real cost, and land the ones that
earn their keep. The core discipline: **measure before enabling, prove a new check
can actually fail, one PR per check that needs real code changes, every PR verified
against the full matrix, and every skipped check skipped with a written reason.**

This skill changes code and opens pull requests. It never merges, never force-pushes,
and never deletes a branch.

## Which repo

By default this operates on **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. If the
current repo can't be resolved, **ask the user which repo to work in** — do not guess.

## First: locate the project's actual config and verify command

Nothing below works against assumed paths. Establish these four facts before anything
else, and use them everywhere the steps say "the config" or "the matrix":

```bash
# where lint and TS are configured (a repo may have several projects)
ls eslint.config.* .eslintrc.* 2>/dev/null; find . -name 'tsconfig*.json' -not -path '*/node_modules/*'
# what the project itself calls verification
cat CLAUDE.md 2>/dev/null | grep -iA5 'verify'; jq -r '.scripts' package.json
```

1. **The ESLint config file(s)** — or the fact that ESLint isn't set up yet, in which
   case the first round is adding it.
2. **The tsconfig project(s)**, and which directories each one actually covers.
   `src/`, `tests/`, and `scripts/` are often separate; a directory of plain `.js`/`.mjs`
   has no TypeScript to check and is not evidence of anything.
3. **The verification matrix** — the project's own "verify before you push" command if
   it documents one (usually in `CLAUDE.md`), otherwise assembled from `package.json`
   scripts. Something like:
   ```bash
   npx eslint . && npm run typecheck && npm test && npm run build && npm run test:e2e
   ```
   plus whatever project-specific check scripts exist. Drop the `eslint` step until
   ESLint is set up.
4. **The default branch**, from `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.

## Where to find candidates

- Diff the current ESLint config and tsconfig against what typescript-eslint's
  `strict`/`stylistic` type-checked presets and the TS compiler's full strictness
  surface offer. Anything not enabled is a candidate — but **read the files before
  assuming**; `strict` alone implies a long list of flags.
- Read the PR bodies of previous rounds (`gh pr list --state merged --search "Measured and deferred"`)
  — deferred checks are listed there with violation counts and skip reasons.
  Re-measure; counts drift and earlier sweeps sometimes make a check free.
- Look at what recent bugs would have been caught by — a check that would have
  prevented a real regression outranks any preset.
- Plugins earn their install only for a concrete invariant worth locking in
  (e.g. module-cycle detection after a de-cycling refactor).

## Ground rules (learned the hard way)

- **Never force-push, never delete branches.** A pushed branch is permanent; get
  it right before pushing, or add commits. If a branch must be rebuilt, it needs a
  new name and the old PR gets closed with a pointer.
- **Every PR bases on the default branch. Never stack.** A stacked PR "merges" into
  its base branch, not the default branch (this actually happened). Independent PRs
  conflict only in the shared `rules` block of the ESLint config (or in tsconfig) —
  resolve by keeping BOTH sides' rules, never drop one.
- **Run the full verification matrix before every push.** Install dependencies
  (`npm ci`) first — type-aware lint silently degrades imports to `any` when
  `node_modules` is missing, and rules stop seeing them. If a round adds ESLint, add
  the lint step to the project's documented verify command and to CI in the same PR.
  Note which suites rewrite generated directories (e2e screenshot/snapshot output is
  the usual one) and restore them before committing.
- **Behavior neutrality is a claim you must defend per fix, in the PR body.**
  Modifier and type-position changes are free; `void x` is free; added `await`s
  inside try blocks change the error path; fallback operators change behavior on
  falsy-but-present values. Say which category each fix is in.

## Process

### 1. Probe — measure every candidate before enabling anything

Add candidate rules to the ESLint config in the working tree (revert after), run
once, count violations per rule:

```bash
npx eslint . 2>&1 | grep -E "  error" | awk '{print $NF}' | sort | uniq -c | sort -rn
```

For TS compiler options, pass the flag directly and count:

```bash
npx tsc --noEmit -p <tsconfig> --<flag> 2>&1 | grep -cE 'error TS'
```

**First check whether the flag is already set**: `grep -n '"<flag>"' <tsconfig>`, and
remember that `"strict": true` turns on a whole family of them. A flag that is already
on reports 0 errors because it is already on, and that zero says nothing about the flag
— it is the compiler-option version of a check that cannot fail. Enabling on the
strength of it adds a duplicate key that reads as new coverage while changing nothing
(JSON takes the last one, so it is silent rather than an error). Candidates are only
the flags the project does NOT already set.

### 2. Prove the check can fail (the canary step)

**A check that cannot fail is indistinguishable from a passing one.** Zero findings
is only good news after you've watched the check catch a planted violation. Write a
throwaway file that violates the check, confirm the error fires, delete the file.
This has caught a rule that ran and silently reported nothing because it couldn't
parse the imported files — resolution alone wasn't enough, it needed a parser
mapping. Config subtleties like that go in a comment next to the config, with the
canary method named.

**Check the canary file itself parsed.** When canarying many checks at once from
one file, a single syntax error in it makes the linter report a parse error and
nothing else — every other planted violation silently goes unreported, and the run
looks like the checks all fired clean. So assert on the *set of check names that
fired* against the set you planted, never on the exit code or a total count. Two
outcomes come out of that diff, and they mean opposite things:

- **A check stayed silent and the planted violation was wrong.** Fix the canary — a
  check can legitimately exempt the shape you planted (a rule that permits the
  parenthesized form of what it bans, say).
- **A check stayed silent because it cannot fire here at all.** Drop it rather than
  enabling it as decoration. A ban on syntax the compiler already rejects earlier in
  the pipeline can never trigger, and shipping it implies a guarantee that isn't
  real.

### 3. Triage by whether code changes at all

The batching line is code changes, not violation count:

- **Zero code changes** (the check passes as-is — config-only enablement) → batch
  freely with other zero-code-change enablements into one "no-op enablements" PR.
- **ANY code change required, even one line** → its own PR, one check per PR. A
  reviewer approving "turn on a rule that already passes" should never also be
  approving code edits riding along, and a single-rule PR is what makes the
  per-fix behavior analysis checkable.
- **False-positive-heavy** → scope the check (file-pattern override with a comment
  explaining why) rather than dropping it — a rule off in one directory with a
  reason beats a rule off everywhere silently.
- **Unsafe-to-sweep** → defer, and record count + reason in the PR body so the next
  round re-measures instead of re-litigating. Typical reasons: the fix operator
  changes runtime behavior on edge values, or the types the check trusts are
  casts of external data rather than validated shapes.

### 4. Land

- Auto-fixable checks: enable, `npx eslint . --fix`, verify, done. When rebasing,
  regenerate with `--fix` on the new base rather than cherry-picking — it's
  deterministic and conflict-free.
- Judgment checks: fix site by site, matching each module's existing failure style;
  hoist a recurring pattern into a helper when a reviewer would otherwise see the
  same wallpaper ten times.
- Every non-obvious config option gets a comment saying WHY, in the style of the
  existing rules block.
- PR body states: violation count, fix approach, per-fix behavior-change analysis,
  and what was measured-and-deferred with counts.
- Update the project's documented "verify before you push" command if the
  lint/typecheck contract changes. Keep CI in step: a release workflow that mirrors
  the CI workflow's check steps has to change with it. The install comes BEFORE the
  lint step, and there must be exactly ONE lint step; grep for it after any workflow
  edit (an edit like this once deleted the step and CI went green by linting nothing).

### 5. Shepherd

As each PR merges, siblings usually conflict in the shared rules block. Resolve by
keeping both sides, re-run the matrix, push. `gh pr update-branch <n>` handles the
no-conflict case. GitHub's mergeable status is computed lazily — an apparent DIRTY
right after a push is often stale; re-check after ~20 seconds.

For a check too large for one sitting, split the FIXES across parallel subagents by
disjoint file sets (no config changes in their branches), then merge their branches
into one integration branch, flip the flag everywhere, verify the matrix, and open a
single PR for the check.

## Report

At the end, in this order: each check landed and its PR link; each check
measured-and-deferred with its violation count and the one-line reason; each check
dropped at the canary step because it cannot fire here; and what the next round
should re-measure first.

## Guardrails

- Writes: branches and pull requests on the target repo, and code changes within them.
  Never merges, never force-pushes, never deletes a branch, never edits a pushed commit.
- Never enable a check that hasn't been measured, and never one that hasn't been
  watched failing on a planted violation.
- Never batch a code change with a config-only enablement.
- Never claim behavior neutrality without naming the category per fix.
