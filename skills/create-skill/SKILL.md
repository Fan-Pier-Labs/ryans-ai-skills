---
name: create-skill
description: Add a new Claude Code skill to the shared skills repo this project depends on (the repo that ships auto-reviewer, ci-runner, pr-watcher, …) by opening a pull request there — never by editing the vendored copy in the current repo. Clones the skills repo fresh, writes the skill in the house style (SKILL.md + references, scripts only for deterministic discovery), updates the README, pushes a branch, opens the PR, and tells the user to run `npm run update` in this repo once it is merged. Use whenever the user says "/create-skill", "make a new skill", "add a skill for X", "turn this into a skill", or wants to change a skill that lives in the shared skills repo.
---

# Create Skill

You are running inside a **child repo** that pulls the shared skills repo in
as a dependency (`npm run update` refreshes the vendored copy). The vendored
copy is read-only in practice: anything written there is overwritten on the
next update and is not on a branch anyone can review. So a new skill goes
**upstream, via a pull request on the skills repo**, and reaches this repo
only after that PR is merged and the user runs `npm run update`.

The deliverable is that PR. The report is its link plus the one instruction
the user needs: merge it, then `npm run update` here.

## 1. Pin down the skill before writing anything

From the request, settle these — ask for whatever is missing, in one
message, not one question at a time:

- **Name**: kebab-case, becomes the directory and the `/slash-command`.
  Check it does not already exist upstream (step 3 lists the directories).
- **What it does**, in one sentence, and **what it must never do** (its
  guardrails — what it writes, where, and the idempotency rule if it
  posts anything).
- **Triggers**: the phrases a user would say. These go into the
  `description` verbatim; that field is what makes the skill fire.
- **Inputs**: does it target the current repo, named repos (`REPOS` /
  `OWNERS`), a cloud account, a PR? Reuse the existing conventions (see
  `references/skill-conventions.md`) rather than inventing new flags.
- **Is it PR-reactive?** If pr-watcher should be able to run it per PR, it
  needs a "Single-PR invocation" section (the conventions file has the
  contract).

If the user handed you a working procedure from this session ("turn what
you just did into a skill"), that procedure *is* the spec — transcribe it,
generalize the repo-specific parts into inputs, and keep every guardrail
you actually applied.

## 2. Resolve the skills repo

Never hardcode a path. Start from the directory this `SKILL.md` was loaded
from (the harness shows it; otherwise locate it from the child repo root)
and walk up until you hit a git checkout whose `origin` is **not** the
child repo's own — that is the vendored skills checkout:

```bash
skill_dir="$(dirname "$(find "$(git rev-parse --show-toplevel)" -path '*/create-skill/SKILL.md' -not -path '*/node_modules/*' | head -1)")"
child_origin="$(git remote get-url origin)"
d="$skill_dir"; SKILLS_REPO=""
while [ "$d" != "/" ]; do
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ] && [ "$url" != "$child_origin" ]; then SKILLS_REPO="$url"; break; fi
  [ -n "$top" ] && d="$(dirname "$top")" || d="$(dirname "$d")"
done
echo "SKILLS_REPO=${SKILLS_REPO:-unresolved}"
```

If that resolves nothing (the copy was vendored as plain files, not a
checkout), use the `SKILLS_REPO` environment variable if set, then the
child repo's `package.json` `repository`/`config.skillsRepo` fields or its
update script (`npm run update` — read what it clones), and finally the
default upstream, **`Fan-Pier-Labs/ryans-ai-skills`**. Confirm the slug in
your report so a wrong guess is caught before the PR is opened on it.
`gh repo view "$SKILLS_REPO" --json nameWithOwner,defaultBranchRef` must
succeed before you continue.

## 3. Fresh clone, branch, check for an existing PR

```bash
dir=$(mktemp -d "${TMPDIR:-/tmp}/create-skill.XXXXXX")
gh repo clone "$SKILLS_REPO" "$dir" -- --quiet && cd "$dir"
default="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
ls -d */ | tr -d /                                            # existing skills — name must not collide
gh pr list --state open --search "head:create-skill/<name>" --json number,url,headRefName
```

If an open PR already exists for this skill name, **check out its branch
and push to it** — don't open a second PR. Otherwise:

```bash
git checkout -b "create-skill/<name>"
```

Work only in `$dir`. Do not touch the vendored copy in the child repo; do
not `cd` back into it to edit anything.

## 4. Write the skill in the house style

Read `references/skill-conventions.md` first and follow it — it is the
style every other skill in the repo is written in, and a PR that ignores it
gets reviewed back into shape. The short version:

- `skills/<name>/SKILL.md` with frontmatter `name:` (matches the directory) and a
  `description:` that says what it does *and* lists the trigger phrases.
- Long material (checklists, report templates, recipes) goes in
  `skills/<name>/references/*.md`, not inline. Markdown first: **do not write
  helper scripts unless the skill needs deterministic discovery** (finding
  candidate PRs, inventorying an account). If it does, `scripts/*.sh`, read-only,
  `set -euo pipefail`, honouring `REPOS` / `OWNERS` / `DAYS` / `MARKER` like the others.
- A **Guardrails** section that names what the skill writes and what it
  never does. Anything that posts to GitHub uses a
  `<!-- generic-coding-agents:<name> ... -->` marker for idempotency.
- **No personal, org, or account references** — no names, logins, account
  ids, or company-specific hostnames. The repo is meant to be reusable;
  a previous PR exists only to strip such references out.

Then wire it into the README:

- add a row to the skills table (skill, what it does, cadence);
- add the name to the `for s in …` install loop;
- fix the count in the first sentence ("Six Claude Code skills" → whatever
  it now is) and, if the skill composes with the others, the composition
  paragraph at the end.

## 5. Check it before pushing

```bash
head -5 skills/<name>/SKILL.md                                           # frontmatter present, name matches dir
grep -rnE -i 'fan.?pier|ryan|@[a-z0-9-]+\.com|[0-9]{12}' skills/<name> README.md | grep -v generic-coding-agents || true   # personal refs → fix
find skills/<name>/scripts -name '*.sh' -exec bash -n {} \; -exec test -x {} \; -print 2>/dev/null   # scripts parse and are executable
git status --short
```

A reference file the SKILL.md never points at is dead weight — link every
one. Re-read the description once more as a user would type it: would the
trigger phrases you were given make it fire?

## 6. Commit, push, open the PR

```bash
git add -A
git commit -m "<name>: <one line, what the skill does>"
git push -u origin HEAD
gh pr create --base "$default" --title "<name>: <one line>" --body-file body.md
```

`body.md`, in order: the marker `<!-- generic-coding-agents:create-skill -->`,
what the skill does (two or three sentences), its triggers, its guardrails
(what it writes and never does), the files added, and the README changes.
End with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Then `rm -rf "$dir"`.

## 7. Report — the two things the user needs

Say, in this order, nothing padded:

1. **The PR link**, on which repo, and the skill's name and one-line purpose.
2. **What to do next, verbatim:**

   > Once that PR is merged, run `npm run update` in this repo to pull the
   > latest skills. `/<name>` is not available here until then.

If the auto-reviewer / ci-runner agents watch the skills repo, mention that
the PR will get their review; the human merges.

## Guardrails

- **Never edit the vendored skills copy in the child repo.** It is not a
  branch, it is not reviewed, and `npm run update` erases it.
- **Never push to the skills repo's default branch, never merge.** One
  branch, one PR, the human merges.
- **One PR per skill name.** An existing open PR for the same name is
  updated, not duplicated.
- **Never commit secrets, personal names, account ids, or company
  hostnames** into the skills repo — step 5's grep is the floor, not the
  ceiling.
- **Confirm the target repo slug in the report.** Opening a PR on the
  wrong repo is the one mistake this skill can make that is visible to
  other people.
