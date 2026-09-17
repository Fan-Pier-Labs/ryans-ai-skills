# generic-coding-agents

Ten Claude Code skills, in four groups:

1. **[Background agents](#1-background-agents)** — long-running agents that watch your pull
   requests while you keep working: review them, run their CI, demo them.
2. **[Development skills](#2-development-skills)** — run on demand while you build.
3. **[Audit skills](#3-audit-skills)** — read-only scorecards on a codebase, a cloud
   account, or a company's operational security.
4. **[Meta skills](#4-meta-skills)** — skills that build skills.

All PR/repo/cloud discovery is done by deterministic bash scripts (`scripts/` in each skill,
or [`skills/shared/`](skills/shared/README.md) where several skills run the same one); the
model does the judgment work on top.

## 1. Background agents

These are the ones you start and leave running. They operate on GitHub pull requests — by
default the repo of the current working directory, or the repos/orgs you name via
`REPOS`/`OWNERS`. They compose: dependency-updater opens PRs → ci-runner runs them →
auto-reviewer reviews them → pr-demo-media demos the frontend ones. Each posts only where it
is supposed to, and each dedups on the PR's head SHA, so nothing gets reviewed, run, or demoed
twice for the same commit. `pr-watcher` is how the other three run *on change* rather than on
a timer: one watcher, one webhook, and it dispatches whichever skills it was started with per
changed PR.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [auto-reviewer](skills/auto-reviewer/SKILL.md) | Posts a thermo-nuclear code-quality review on any open, non-draft PR (active in the last week) that has had no feedback since its latest commit. Per-PR, where [code-quality-audit](skills/code-quality-audit/SKILL.md) is per-repo | continuous loop, ~20–30 min |
| [ci-runner](skills/ci-runner/SKILL.md) | Runs each PR's own `.github/workflows` YAML on this machine (for when GitHub Actions credits are out), several PRs at a time, and posts commit statuses + failure logs. Fully deterministic and stateless — the `local-ci` status on the head SHA is the dedup ledger, and `scripts/ci-runner.sh` is cron-able on its own. Design notes in [ci-runner/README.md](skills/ci-runner/README.md) | every ~15 min, or on PR events via pr-watcher |
| [pr-demo-media](skills/pr-demo-media/SKILL.md) | Demos frontend PRs: spins up each PR's app and records a Playwright video or captures before/after screenshots — whichever fits the change — then posts it with `gh pr comment --attach` | continuous loop, ~20–30 min |
| [pr-watcher](skills/pr-watcher/SKILL.md) | Runs any of the above on the PRs that qualify (yours, opened in the last 7 days, by default): `/pr-watcher run /auto-reviewer /ci-runner`. Sweeps every qualifying open PR first, then handles each one the moment it changes — one `gh webhook forward` per repo (polling if the repo won't grant a webhook) feeds a queue, drained by a capped number of subagents, one per PR. The watcher itself writes nothing to GitHub | while the session runs |

## 2. Development skills

Hands-on skills you invoke while working on a repo, rather than leaving running. They change
code — on a branch, in a PR, never merged.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [dependency-updater](skills/dependency-updater/SKILL.md) | Bumps dependencies (npm/bun, Python requirements/pyproject, Cargo, Go modules) in the current repo — or, with `OWNERS`, every repo active in the last month — verifies each one still builds, launches, and passes its full test suite after the bump, and opens one PR per repo | on demand / weekly |

*(An ESLint setup skill is planned for this group; until it lands, the vendored 105-rule
baseline lives inside [code-quality-audit](skills/code-quality-audit/references/eslint-baseline.config.mjs).)*

## 3. Audit skills

Different in kind from everything above: they **never write to any provider or any server**.
Inventory is read-only, the on-box collectors only read (the SSH sweep runner refuses to send a
script containing a write/delete/package/service command), and every change is a recommendation
with a snapshot-first, two-confirmation gate for anything irreversible. Each one answers a
fixed list of concrete questions, each with a recommended answer, and delivers a scorecard with
evidence — the kind of document a founder can hand to an investor, a new engineering lead, or a
buyer's technical diligence. The three infra/ops audits share one
[`ec2-ssh-sweep.sh`](skills/shared/README.md), so there is nothing to keep in sync, and they
hand findings to each other: sec-ops sends AWS configuration issues to infra-audit,
infra-cost-audit sends security and reliability issues there too.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [code-quality-audit](skills/code-quality-audit/SKILL.md) | Sixteen questions about a whole repository — linter + type checker enabled *and enforced*, dead code, endpoint authentication **and authorization** (IDORs, not just missing guards), dead endpoints, duplicate code, unit tests, integration tests, whether the module graph is a DAG, types, CI gating every PR, committed secrets, lockfile + dependency audit, oversized files, swallowed errors, README, and what percent of a vendored 105-rule ESLint baseline is enabled. `scripts/repo-inventory.sh` builds a `DIGEST.md` in one read-only pass — import cycles, every endpoint with its visible auth and reference count, duplicate blocks, test/CI/secret/lockfile signals — and runs whichever analyzers are installed (eslint/tsc/mypy/ruff/knip/vulture/jscpd/madge), never `--fix`. Changes no code | on demand / when inheriting a codebase |
| [infra-audit](skills/infra-audit/SKILL.md) | Thirteen questions about a startup's infrastructure — **append-only CloudTrail** (Object Lock COMPLIANCE, a 14-rule PASS/FAIL table modelled on a verified reference trail), what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA enforced everywhere, RDS password rotation, crash/OOM resilience, observability, mainstream vs budget hosting, containerized code — plus the security hygiene found on the way. Read-only `scripts/aws-audit-inventory.sh` plus the SSH sweep with an audit collector (patching, ports, users, secret *names* only, backups, startup config) | on demand |
| [infra-cost-audit](skills/infra-cost-audit/SKILL.md) | One question asked of every resource: is this costing money it shouldn't? Waste, wrong-sized resources, and billing-model traps (stopped Lightsail instances billing full price, idle public IPv4). Read-only `scripts/aws-cost-inventory.sh` sweeps AWS; `ec2-ssh-sweep.sh` runs a read-only collector on every running EC2 box (memory, I/O, real traffic, logins, deploys) so nothing is called "idle" from CPU alone. Tiered A/B/C report with exact commands and how to undo each one | on demand |
| [sec-ops-audit](skills/sec-ops-audit/SKILL.md) | Thirteen operational-security questions for a 2–10 person startup — **all code in the company repo**, **no ex-contractor/ex-engineer access anywhere**, **CEO has admin on everything and every account and server is in the company's name**, plus no secrets in repo history, no shared logins, prod access by named person, company-owned domains, billing in the company's name, company-owned app-store/registry accounts, a company password manager, prod secrets in a store and rotated after departures, working SPF/DKIM/DMARC with no external forwards, and per-identity 2FA. Inventories every system through API/CLI/MCP where you can grant access (`saas-access-inventory.sh` covers ~20 vendors) and transcribed screenshots where you can't. Q1 is the heavy one: `live-vs-repo.sh` fetches every live hostname's pages and JS bundles, fingerprints the stack, pulls API hosts/paths/env names and greps them in the repo, lists every place code runs in AWS, and produces `CODE-RECONCILIATION.md` with MATCH/NO MATCH per host and unit. Delivers a people × systems **access matrix** (former people first), an ownership table, and a filled-in removal-and-rotation runbook — removes nobody, rotates nothing | on demand / after every departure |

## 4. Meta skills

| Skill | What it does | Cadence |
| --- | --- | --- |
| [create-skill](skills/create-skill/SKILL.md) | Adds a new skill to **this repo** from a child repo that vendors it: clones this repo fresh, writes the skill in the house style ([conventions](skills/create-skill/references/skill-conventions.md)), wires the README, pushes a branch and opens the PR here — never edits the vendored copy, which the next `npm run update` would overwrite. Reports the PR link and the one follow-up: once merged, run `npm run update` in the child repo | on demand |

## Install

Every skill lives under `skills/`, and `.claude/skills` is a committed symlink to that
folder, so a session opened at this repo's root sees them all with no install step.
`skills/shared/` sits among them and is not a skill — it has no `SKILL.md`, so nothing
loads it as one.

To have them in every session on the machine instead, link the folder into the user
skills directory:

```bash
ln -sfn "$PWD/skills" ~/.claude/skills
```

(or link individual skills: `ln -sfn "$PWD/skills/<name>" ~/.claude/skills/<name>` —
link `skills/shared` alongside, since the scripts reach it at `../../shared/`).
Repos that vendor this one copy `skills/*` into their own `.claude/skills/`, which
brings `shared/` with them.

## Conventions shared by the GitHub skills

- **Idempotency via markers**: every posted comment starts with an HTML marker
  (`<!-- generic-coding-agents:<skill> ... -->`). Discovery scripts compare the
  marker's timestamp against the PR's latest commit, so nothing is ever posted
  twice for the same head SHA.
- **Read-only discovery**: the `find-*-candidates.sh` scripts never write
  anything to GitHub — safe to run any time.
- **Target repos**: by default the repo of the current working directory, from
  `git remote get-url origin`. `REPOS='owner/repo ...'` names repos explicitly;
  `OWNERS='org user ...'` expands users/orgs to their repos pushed within `DAYS`.
  The scripts never enumerate the user's GitHub account; if the current repo can't
  be resolved they exit 2 and the agent asks the user what to target.
- **Env tuning**: `REPOS`, `OWNERS`, `DAYS`, `MARKER` on every script.
- **One copy of shared code**: [`skills/shared/`](skills/shared/README.md) is not
  a skill (no `SKILL.md`); it holds what several skills need — `repo-targets.sh`
  (the `resolve_repos` / `$CUTOFF` library behind the paragraph above),
  `find-pr-candidates.sh` (the open-PR sweep auto-reviewer and pr-demo-media
  both run, given a marker and optionally `--touching <regex>` /
  `--reviews-are-feedback`), and `ec2-ssh-sweep.sh`. Skills reach it by a
  relative symlink, by sourcing it, or through a wrapper that holds only the
  arguments that skill passes. It ships next to the skills, so
  `../../shared/<file>` resolves in a vendored copy too.
- **Write surfaces**: auto-reviewer and pr-demo-media post comments only;
  ci-runner posts statuses + one upserted comment; dependency-updater pushes
  branches and opens PRs; create-skill pushes one branch and opens one PR on
  this repo only; code-quality-audit writes one report file, and opens an
  issue only when asked. Nothing merges, force-pushes, or deletes.
