# Dependency preflight

**Not a skill.** The one copy of the rule every skill that needs third-party tooling follows
before it does any work: `code-quality-audit`, `sec-ops-audit`, `pr-demo-media`,
`dependency-updater`, `enable-more-lint-or-ts-checks`.

## The rule

A skill that needs tools it cannot run without resolves that **first**, in one exchange, before
step 1 of its own procedure:

1. **Detect** what is missing, with a command — never from memory of what is usually installed.
2. **Ask once.** One message, listing every missing tool, what each one answers, and the exact
   install command for each. Not one question per tool.
3. **Two paths, and only these two:**
   - **Yes** → install exactly what was listed, confirm each one now resolves, then run the skill.
   - **No** → **stop. Do not run the skill.** Say which parts would have been unanswerable and
     that the offer stands. Do not start anyway and degrade, do not substitute a grep for a
     tool, do not run half the procedure and report the other half as Unknown.

The third path — starting without the tools and discovering mid-run that the answer cannot be
produced — is the one this exists to remove. A skill that gets halfway and stalls has spent the
user's time and produced a report they cannot trust.

## What goes in the ask

One block, copyable, in this shape:

```
This audit needs 3 tools that aren't installed here:

  knip      → which files and exports are dead (Q2 — no substitute)   npm i -D knip
  vulture   → dead Python code (Q2)                                   pipx install vulture
  gitleaks  → secrets in git history (Q11)                            brew install gitleaks

Install these and run the audit? (yes / no)
```

Rules for the block:

- **Name what each tool buys.** "Install knip" is a chore; "knip answers which files are dead,
  and nothing else can" is a decision the user can make.
- **Say when there is no substitute**, and when there is one. A missing `jscpd` costs nothing —
  `dup-blocks.py` covers it. A missing `knip` means Q2 has no answer at all. These are different
  asks and the user should be able to tell them apart.
- **Show the exact command**, the one you will run, including the flag that decides where it
  lands.
- **Say where it lands** (below), because that is the part a user says no to.

## Where it lands

Two kinds of install, and the difference matters more than the tool does:

| | What it touches | Use it for |
| --- | --- | --- |
| **Ephemeral** — `npx --yes <tool>`, `uvx <tool>`, `pipx run <tool>` | A cache outside the repo. Repo unchanged. | **The default for every audit skill.** Read-only is the promise those skills make; keep it. |
| **Project** — `npm i -D <tool>`, `pip install`, `bun add -d` | `package.json` and the lockfile — a diff in the user's tree. | Only when the tool must resolve the repo's own dependencies to work (type-aware ESLint, `tsc` on the project's TS version, Playwright inside the checkout it drives), or when the user wants it kept. |

Default to ephemeral and say so in the ask. When a tool genuinely needs the project install, say
which files that changes and that it is a revertable diff (`git checkout -- package.json
package-lock.json`). A skill working inside a **throwaway clone** (`pr-demo-media`,
`ci-runner`, `dependency-updater`) installs into that clone freely — nothing there is the user's
tree — and needs no separate ask for it.

Never `sudo`. Never a global install (`npm i -g`, `pip install --user` into the system Python)
without naming it as global in the ask — that is a change to the machine, not to a project.

## After a yes

- Install, then **verify each one runs** (`<tool> --version`). An install that resolved but does
  not execute is the same failure this preflight exists to prevent, one step later.
- If an install **fails** — no network, no permission, a package that no longer exists — report
  that tool as unavailable, say what it would have answered, and ask whether to continue without
  it or stop. Do not retry silently and do not swap in a different package than the one the user
  approved.
- Record what was installed in the report's method section, and whether it was ephemeral or left
  in the tree. An ephemeral run is a fact about the evidence: name it.

## After a no

Stop, in one short message:

> Not running the audit. Without knip there is no answer to "is there dead code" (Q2), and Q16
> would be nominal only. Say the word and I'll install them and start.

A no is durable for this run, not for the session — if the user later asks for the same skill,
ask again, because the machine may have changed. Never re-ask inside the same run to get a
different answer.

## What is not in scope

The preflight covers **third-party analyzers and libraries the skill runs**. It does not cover:

- **The repo's own dependencies.** `npm ci` in a checkout the skill made is part of the
  procedure, not a preflight question.
- **CLIs and credentials** — `gh`, `aws`, `docker`, an SSH key, a cloud profile. Those are access,
  not packages: a skill checks them in its own scope step and asks for the specific access it is
  missing. `infra-audit`, `infra-cost-audit` and the PR agents work this way.
- **Anything with a real fallback the skill is happy with.** `act` for `ci-runner` is optional by
  design — the workflow interpreter is the supported path — so it is a note in the report, not a
  gate.
