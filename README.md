# generic-coding-agents

Twelve Claude Code skills, in four groups:

1. **[Background agents](#1-background-agents)** — long-running agents that watch your pull
   requests while you keep working: review them, run their CI, demo them.
2. **[Development skills](#2-development-skills)** — run on demand while you build, and
   change code on a branch.
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
twice for the same commit.

**None of them runs on a timer** — there is no cadence to pick. `pr-watcher` is the one entry
point: it catches up once on the PRs that are open now, then reacts to GitHub webhook
deliveries (one `gh webhook forward` per repo, no public endpoint) and dispatches whichever
skills it was started with, one subagent per changed PR.

```bash
/pr-watcher run /ci-runner /auto-reviewer /pr-demo-media
```

Polling is the fallback, not the design. The watcher drops to it only when a repo won't grant
a webhook or every forwarder has died, and it says `MODE=polling` with the reason when it
does. Each skill is still a single sweep you can run on its own — that is what cron and
`/loop` get, and it is the right answer only when there is no session for a webhook to wake.

| Skill | What it does |
| --- | --- |
| [auto-reviewer](skills/auto-reviewer/SKILL.md) | Posts a thermo-nuclear code-quality review on any open, non-draft PR (active in the last week) that has had no feedback since its latest commit. Each review carries 🔴/🟡/🟢 status circles, a 1–5 risk score (blast radius if the PR is wrong), and — for repos with a `visions/<owner>/<repo>.md` on file — a check of whether the PR moves the product toward its stated 6-month/1-year direction. Every batch of PR events also runs `git merge-tree` across every open PR pair in the touched repos and posts a conflict note on both sides. A 🔴 finding that reaches `main` because its PR merged unaddressed becomes a GitHub issue assigned to the PR's author — triggered by the merge event itself, not by a sweep. Per-PR, where [code-quality-audit](skills/code-quality-audit/SKILL.md) is per-repo |
| [ci-runner](skills/ci-runner/SKILL.md) | Runs each PR's own `.github/workflows` YAML on this machine (for when GitHub Actions credits are out), several PRs at a time, and posts commit statuses + failure logs. Fully deterministic and stateless — the `local-ci` status on the head SHA is the dedup ledger, so a webhook, a subagent and a cron fallback can all drive the same `--run-one` executor. Design notes in [ci-runner/README.md](skills/ci-runner/README.md) |
| [pr-demo-media](skills/pr-demo-media/SKILL.md) | Demos frontend PRs: spins up each PR's app and records a Playwright video or captures before/after screenshots — whichever fits the change — then posts it with `gh pr comment --attach` |
| [pr-watcher](skills/pr-watcher/SKILL.md) | Runs any of the above on the PRs that qualify (yours, opened in the last 7 days, by default): `/pr-watcher run /auto-reviewer /ci-runner`. Catches up on every qualifying open PR once, then handles each one the moment it changes or merges — one `gh webhook forward` per repo (polling only if the repo won't grant a webhook) feeds a queue, drained by a capped number of subagents, one per PR. The watcher itself writes nothing to GitHub |

## 2. Development skills

Hands-on skills you invoke while working on a repo, rather than leaving running. They change
code — on a branch, in a PR, never merged. `enable-more-lint-or-ts-checks` is the one you run
on an audit's findings: [code-quality-audit](skills/code-quality-audit/SKILL.md) reports which of
its 105-rule ESLint baseline (Q16) and its 23-check TypeScript compiler baseline (Q21) are off,
and this skill measures those rules and flags and turns the affordable ones on, one PR at a time.
Both baselines live once, in
[code-quality-audit/references/](skills/code-quality-audit/references/) — the hardening skill
reads them from there rather than keeping a copy.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [dependency-updater](skills/dependency-updater/SKILL.md) | Bumps dependencies (npm/bun, Python requirements/pyproject, Cargo, Go modules) in the current repo — or, with `OWNERS`, every repo active in the last month — verifies each one still builds, launches, and passes its full test suite after the bump, and opens one PR per repo | on demand / weekly |
| [enable-more-lint-or-ts-checks](skills/enable-more-lint-or-ts-checks/SKILL.md) | Finds TypeScript compiler options and ESLint rules the repo is leaving on the table — candidates come from diffing the repo's *effective* config (`tsc --showConfig`, `eslint --print-config`) against the same two vendored baselines code-quality-audit scores against — **measures each one before enabling it**, and lands the ones that earn their keep as PRs. Every candidate gets a canary — a planted violation it must be watched catching, because a check that cannot fail is indistinguishable from a passing one. Batching is by code changes, not violation count: config-only enablements batch into one PR, **anything needing even a one-line code change gets its own PR** so the per-fix behavior-neutrality analysis stays checkable. Deferred checks are recorded with counts and reasons so the next round re-measures instead of re-litigating. Never force-pushes, never deletes a branch, never stacks PRs | on demand / each hardening round |

## 3. Audit skills

Different in kind from everything above: they **never write to any provider or any server**.
Inventory is read-only, the on-box collectors only read (the SSH sweep runner refuses to send a
script containing a write/delete/package/service command), and every change is a recommendation
with a snapshot-first, two-confirmation gate for anything irreversible (for sec-ops: transfer
before removing a person, replace a token before revoking it, rotate after switching
consumers). Each one answers a fixed list of concrete questions, each with a recommended
answer, and delivers a scorecard with evidence — the kind of document a founder can hand to an
investor, a new engineering lead, or a buyer's technical diligence. The three infra/ops audits
share one [`ec2-ssh-sweep.sh`](skills/shared/README.md), so there is nothing to keep in sync,
and they hand findings to each other: sec-ops sends AWS configuration findings (CloudTrail, MFA
enforcement, ports) to infra-audit and cites it, and infra-cost-audit hands its security and
reliability findings there too. code-security-audit does the same in the other direction: the
bug classes a SAST scan structurally cannot see go to code-quality-audit (authorization and
IDORs), sec-ops-audit (secrets in git history) and infra-audit (the running estate, as opposed
to the IaC in the repo).

| Skill | What it does | Cadence |
| --- | --- | --- |
| [code-quality-audit](skills/code-quality-audit/SKILL.md) | Twenty-two questions about a whole repository — linter + type checker enabled *and enforced*, dead code, endpoint authentication **and authorization** (IDORs, not just missing guards), dead endpoints, duplicate code, unit tests, integration tests (required to run in CI, not just exist), whether the module graph is a DAG, types, whether CI **exists** and gates every PR on lint + types + unit + integration + a coverage threshold and is *required* by branch protection, **test coverage ≥ 80% on lines and branches with a threshold enforcing it**, **force-push blocked on every branch** (the anti-`--force` check, with the default branch as the floor: reads `allow_force_pushes`, `allow_deletions`, `enforce_admins`, ruleset `non_fast_forward` and its ref patterns and `bypass_actors`, and is honest about the rebase workflow it costs), **whether tests wait on real-world time or fake the clock** (fixed sleeps counted and totalled in seconds-per-run; a poll with a deadline is not a finding), **change-detector tests** (oversized snapshots, mock-call-only assertions, and test/source lockstep churn from the git history), committed secrets, lockfile + dependency audit, oversized files, swallowed errors, README, what percent of a vendored 105-rule ESLint baseline ([references/eslint-baseline.config.mjs](skills/code-quality-audit/references/eslint-baseline.config.mjs), recommended 100%) is enabled, and **what percent of a vendored 23-check TypeScript compiler baseline** ([references/tsconfig-baseline.json](skills/code-quality-audit/references/tsconfig-baseline.json), 15 options, recommended 100%) is enabled — scored per tsconfig off `tsc --showConfig`, so `extends` and the nine checks `strict` expands to are resolved rather than grepped, headlined by the *lowest* project, and read against how much of the repo that project's `include` actually covers, and **whether the codebase is re-implementing what a maintained library already solves** — eighteen domains where hand-rolling is the wrong trade (crypto, password hashing, JWT verification, HTML sanitization, date/timezone arithmetic, money, CSV, retry/backoff, caching, …) scored on *edge cases rather than line count*, each paired against the dependency manifest so the strongest shape falls out mechanically: **the library is already installed and the hand-rolled copy exists anyway**. The same question covers vendored `third_party/` trees and “adapted from ‹url›” forks that no `npm audit` will ever flag, and the inverse — a dependency bought for one expression. Every row is a lead, with a false-positive list (thin wrappers, stdlib equivalents, written no-dependency policies, libraries they tried and removed) that has to be worked before it becomes a finding. `scripts/repo-inventory.sh` builds a `DIGEST.md` in one read-only pass — import cycles, every endpoint with its visible auth and reference count, duplicate blocks, test/CI/secret/lockfile signals — and runs whichever analyzers are installed (eslint/tsc/mypy/ruff/knip/vulture/jscpd/madge), never `--fix`. Changes no code | on demand / when inheriting a codebase |
| [code-security-audit](skills/code-security-audit/SKILL.md) | [Semgrep](https://github.com/semgrep/semgrep) over the whole repository, plus the three things that make its output worth reading. **The packs are chosen from the languages actually present** — a verified registry table ([references/semgrep-packs.md](skills/code-security-audit/references/semgrep-packs.md)) with rule counts, the aliases that are the same pack twice, and the six plausible-looking names (`p/express`, `p/rails`, `p/html`, `p/bash`, `p/gitlab-ci`, `p/nodejs-scan`) that 404 and fail the run with exit 7. **The scan's coverage is proved before any finding is written**: three independent defaults silently drop files — gitignored paths, the built-in `.semgrepignore` (`tests/`, `vendor/`, `node_modules/`), and anything over 1 MB — so a repo with the same bug in four directories gets scanned in one of them, and Semgrep still **exits 0 with findings** unless `--error` is passed. Where tests and vendored code matter (they do, for credentials and disabled TLS) the second pass runs over a `git archive` copy with an empty `.semgrepignore`, which replaces the defaults rather than adding to them — nothing is ever written into the working tree. **Every finding is triaged by rule group to confirmed / refuted / needs-context** with the file open, a reachability argument from an untrusted input to the sink, and severity re-ranked against what this app exposes rather than against the rule author's `ERROR` — forty sites of one rule are one finding, and the refuted list ships with its reasons so the next audit is a re-run. A blind-spot table then names what no pack can see and who covers it: authorization/IDOR → code-quality-audit, secrets in git history → sec-ops-audit, vulnerable dependencies → `npm audit`/`osv-scanner` (`p/supply-chain` is a one-rule stub), cloud config → infra-audit, and cross-file taint on the OSS engine, which is intrafile only. Never `--autofix`, never `semgrep login` or `semgrep ci` unprompted, never `--config auto` on a private codebase without saying it sends the project URL, and never a live host — static analysis only | on demand / before a launch, pen test, or security questionnaire |
| [infra-audit](skills/infra-audit/SKILL.md) | Thirteen questions about a startup's infrastructure — **append-only CloudTrail** (Object Lock COMPLIANCE, a 14-rule PASS/FAIL table modelled on a verified reference trail), what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA enforced everywhere, RDS password rotation, crash/OOM resilience, observability, mainstream vs budget hosting, containerized code — plus the security hygiene found on the way. Read-only `scripts/aws-audit-inventory.sh` plus the SSH sweep with an audit collector (patching, ports, users, secret *names* only, backups, startup config) | on demand |
| [infra-cost-audit](skills/infra-cost-audit/SKILL.md) | One question asked of every resource: is this costing money it shouldn't? Waste, wrong-sized resources, and billing-model traps (stopped Lightsail instances billing full price, idle public IPv4). Read-only `scripts/aws-cost-inventory.sh` sweeps AWS; `ec2-ssh-sweep.sh` runs a read-only collector on every running EC2 box (memory, I/O, real traffic, logins, deploys) so nothing is called "idle" from CPU alone. Tiered A/B/C report with exact commands and how to undo each one | on demand |
| [sec-ops-audit](skills/sec-ops-audit/SKILL.md) | Thirteen operational-security questions for a 2–10 person startup — **all code in the company repo**, **no ex-contractor/ex-engineer access anywhere**, **CEO has admin on everything and every account and server is in the company's name** (live hosts and the API hosts the frontend calls are resolved to IP owner → provider → is that account in the inventory; residential IPs and tunnels flagged), plus no secrets in repo history, no shared logins, prod access by named person, company-owned domains, billing in the company's name, company-owned app-store/registry accounts, a company password manager, prod secrets in a store and rotated after departures, working SPF/DKIM/DMARC with no external forwards, and per-identity 2FA (overlaps infra-audit on purpose). Inventories every system through API/CLI/MCP where you can grant access (`saas-access-inventory.sh` covers ~20 vendors, guarded by whatever token/CLI is present) and transcribed screenshots where you can't. Q1 is the heavy one: `live-vs-repo.sh` fetches every live hostname's pages and JS bundles, fingerprints the stack, pulls API hosts/paths/env names and greps them in the repo, lists every place code runs in AWS (Lambda, ECS, EventBridge schedules, Glue, Step Functions, …) and produces `CODE-RECONCILIATION.md` with MATCH/NO MATCH per host and unit plus structural gaps; `dependency-provenance.sh` flags low-volume npm/PyPI packages maintained by current or former employees. Delivers a people × systems **access matrix** (former people first), an ownership table, and a filled-in removal-and-rotation runbook — removes nobody, rotates nothing, and recommends no enterprise controls (SSO/MDM) | on demand / after every departure |

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
- **Write surfaces**: pr-demo-media posts comments only; auto-reviewer posts
  comments and, for a blocking finding that merged unaddressed, one issue per PR;
  ci-runner posts statuses + one upserted comment; dependency-updater and
  enable-more-lint-or-ts-checks push branches and open PRs; create-skill pushes
  one branch and opens one PR on this repo only; code-quality-audit and code-security-audit each write one
  report file, and open an issue only when asked. Nothing merges, force-pushes,
  or deletes.
