# generic-coding-agents

Ten Claude Code skills. Seven operate on GitHub — five standalone coding agents plus a
watcher that runs them and a skill that grows this repo — working on the repo you are
currently in (or the repos/orgs you name via `REPOS`/`OWNERS`); three audit cloud
infrastructure and operations (cost, reliability/security/fitness, sec-ops). All PR/repo discovery is done
by deterministic bash scripts (`scripts/` in each skill, or
[`skills/shared/`](skills/shared/README.md) where several skills run the same one);
the model does the judgment work on top.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [auto-reviewer](skills/auto-reviewer/SKILL.md) | Posts a thermo-nuclear code-quality review on any open, non-draft PR (active in the last week) with no feedback since its latest commit | continuous loop, ~20–30 min |
| [ci-runner](skills/ci-runner/SKILL.md) | Runs each PR's own `.github/workflows` YAML locally (GitHub Actions credits are out), several PRs at a time, and posts commit statuses + failure logs. Fully deterministic and stateless — the `local-ci` status on the head SHA is the dedup ledger; `scripts/ci-runner.sh` is cron-able on its own. Design notes + all-local alternative in [ci-runner/README.md](skills/ci-runner/README.md) | every ~15 min, or on PR events via pr-watcher |
| [code-quality-audit](skills/code-quality-audit/SKILL.md) | Reviews the code quality of a whole repository against sixteen questions — linter + type checker enabled *and enforced*, dead code, endpoint authentication **and authorization** (IDORs, not just missing guards), dead endpoints, duplicate code, unit tests, integration tests, whether the module graph is a DAG, types, CI gates on every PR, committed secrets, lockfile + dependency audit, oversized files, swallowed errors, README, and what percent of a vendored 105-rule ESLint baseline ([references/eslint-baseline.config.mjs](skills/code-quality-audit/references/eslint-baseline.config.mjs), recommended 100%) is enabled. `scripts/repo-inventory.sh` builds a `DIGEST.md` in one read-only pass — import cycles, every endpoint with its visible auth and reference count, duplicate blocks, test/CI/secret/lockfile signals — and runs whichever analyzers are installed (eslint/tsc/mypy/ruff/knip/vulture/jscpd/madge), never `--fix`. Scorecard report; changes no code. Per-repo, where [auto-reviewer](skills/auto-reviewer/SKILL.md) is per-PR | on demand / when inheriting a codebase |
| [dependency-updater](skills/dependency-updater/SKILL.md) | Bumps deps in every repo active in the last month, verifies by launching the app and running all tests, opens one PR per repo | on demand / weekly |
| [infra-cost-review](skills/infra-cost-review/SKILL.md) | Finds where a cloud account's money goes and what can safely be cut: waste, wrong-sized resources, billing-model traps (stopped Lightsail instances billing full price, idle public IPv4). Read-only `scripts/aws-cost-inventory.sh` does the AWS sweep; `scripts/ec2-ssh-sweep.sh` asks for SSH/SSM access to every running EC2 box and runs a read-only collector (memory, I/O, real traffic, logins, deploys) so nothing is called "idle" from CPU alone. Tiered A/B/C report with exact commands; non-cost findings are handed to infra-audit | on demand |
| [infra-audit](skills/infra-audit/SKILL.md) | Audits a startup's infra against thirteen questions — **append-only CloudTrail** (Object Lock COMPLIANCE, 14-rule PASS/FAIL table modelled on a verified reference trail), what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA enforced everywhere, RDS rotating password, crash/OOM resilience, observability, mainstream vs budget hosting, containerized code — plus security hygiene found on the way. Read-only `scripts/aws-audit-inventory.sh` + the same SSH sweep with an audit collector (patching, ports, users, secret *names* only, backups, startup config). Scorecard report | on demand |
| [sec-ops](skills/sec-ops/SKILL.md) | Operational-security audit for 2–10 person startups — thirteen questions: **all code in the company repo**, **no ex-contractor/ex-engineer access anywhere**, **CEO has admin on everything and every account and every server is in the company's name** (live hosts and the API hosts the frontend calls are resolved to IP owner → provider → is that account in the inventory; residential IPs and tunnels flagged), plus no secrets in repo history, no shared logins, prod access by named person, domains company-owned, billing in the company's name, app-store/registry accounts company-owned, a company password manager, prod secrets in a store and rotated after departures, SPF/DKIM/DMARC working with no external forwards, per-identity 2FA (overlaps infra-audit on purpose). Needs wide access: API/CLI/MCP per system preferred (`scripts/saas-access-inventory.sh` covers ~20 vendors, guarded by whatever token/CLI is present), screenshots transcribed to JSON as the fallback. Q1 is the heavy one: `live-vs-repo.sh` fetches every live hostname's page and JS bundles, fingerprints the stack, pulls API hosts/paths/env names and greps them in the repo, lists every place code runs in AWS (Lambda, ECS, EventBridge schedules, Glue, Step Functions, …) and produces `CODE-RECONCILIATION.md` with MATCH/NO MATCH per host and unit plus structural gaps (backend with no frontend; pipelines with no source); `dependency-provenance.sh` flags low-volume npm/PyPI packages maintained by current or former employees (company code living in one person's registry account). Read-only `github-access-inventory.sh`, `repo-scan.sh` (history secret scan, committers, personal-repo deps, CI secret exposure), `domain-inventory.sh` (whois/DNS/DMARC/who-hosts-what), the same SSH sweep with a people-and-code collector (`on-box-secops.sh`: authorized_keys fingerprints, logins, AKIA ids, git repos on disk with uncommitted/unpushed counts, app dirs with no repo). `secops-digest.py` merges everything into a people × systems **access matrix** (former people first) and an ownership table. Scorecard report + filled-in removal-and-rotation runbook; removes nobody, rotates nothing; recommends no enterprise controls (SSO/MDM) | on demand / after every departure |
| [pr-demo-media](skills/pr-demo-media/SKILL.md) | Demos frontend PRs: records a Playwright video or captures before/after screenshots — whichever fits the change — and posts it on the PR with `gh pr comment --attach` | continuous loop, ~20–30 min |
| [pr-watcher](skills/pr-watcher/SKILL.md) | Runs any of the PR-reactive skills on the PRs that qualify — yours, opened in the last 7 days, by default: `/pr-watcher run /auto-reviewer /ci-runner`. Sweeps every qualifying open PR first, then handles each one the moment it changes: one `gh webhook forward` per repo (polling if the repo won't grant a webhook) feeds a queue; the agent drains it with a capped number of subagents, one per PR. The watcher itself writes nothing to GitHub | while the session runs |
| [create-skill](skills/create-skill/SKILL.md) | Adds a new skill to **this repo** from a child repo that vendors it: clones this repo fresh, writes the skill in the house style ([conventions](skills/create-skill/references/skill-conventions.md)), wires the README, pushes a branch and opens the PR here — never edits the vendored copy. Reports the PR link and the one follow-up: once merged, run `npm run update` in the child repo | on demand |

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

## Conventions shared by the four GitHub agents

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
- Write surfaces: auto-reviewer and pr-demo-media post comments only;
  ci-runner posts statuses + one upserted comment; dependency-updater pushes
  branches and opens PRs; create-skill pushes one branch and opens one PR on
  this repo only; code-quality-audit writes one report file, and opens an
  issue only when asked. Nothing merges, force-pushes, or deletes.

The three audit skills are different in kind: they never write to any provider or to any server —
inventory is read-only, the on-box collectors only read (the sweep runner refuses to send a script
containing a write/delete/package/service command), and every change is a recommendation with a
snapshot-first, two-confirmation gate for anything irreversible (for sec-ops: transfer before
removing a person, replace a token before revoking it, rotate after switching consumers).
`scripts/ec2-ssh-sweep.sh` is one file — [`skills/shared/ec2-ssh-sweep.sh`](skills/shared/README.md),
symlinked into all three skills — so there is nothing to keep in sync. sec-ops
hands AWS configuration findings (CloudTrail, MFA enforcement, ports) to infra-audit and cites it.

The GitHub agents compose: dependency-updater opens PRs → ci-runner runs them →
auto-reviewer reviews them → pr-demo-media demos the frontend ones.
code-quality-audit is the whole-repo counterpart to auto-reviewer's per-PR review:
run it once when taking over a codebase, then let auto-reviewer hold the line PR by PR. pr-watcher
is how the last three run *on change* rather than on a timer: one watcher, one
webhook, and it invokes whichever of them it was started with per changed PR
(a shell process can't invoke a skill, so the agent running pr-watcher does
the dispatching — the watcher only queues).
