# generic-coding-agents

Six Claude Code skills. Four are standalone coding agents operating on
the repo you are currently in (or the repos/orgs you name via `REPOS`/`OWNERS`); two review
cloud infrastructure (cost, and reliability/security/fitness). All PR/repo discovery is done
by deterministic bash scripts (`scripts/` in each skill); the model does the
judgment work on top.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [auto-reviewer](auto-reviewer/SKILL.md) | Posts a thermo-nuclear code-quality review on any open, non-draft PR (active in the last week) with no feedback since its latest commit | continuous loop, ~20–30 min |
| [ci-runner](ci-runner/SKILL.md) | Runs each PR's own `.github/workflows` YAML locally (GitHub Actions credits are out), several PRs at a time, and posts commit statuses + failure logs. Fully deterministic and stateless — the `local-ci` status on the head SHA is the dedup ledger; `scripts/ci-runner.sh` is cron-able on its own. Design notes + all-local alternative in [ci-runner/README.md](ci-runner/README.md) | every ~15 min, or on PR events via pr-watcher |
| [dependency-updater](dependency-updater/SKILL.md) | Bumps deps in every repo active in the last month, verifies by launching the app and running all tests, opens one PR per repo | on demand / weekly |
| [infra-cost-review](infra-cost-review/SKILL.md) | Finds where a cloud account's money goes and what can safely be cut: waste, wrong-sized resources, billing-model traps (stopped Lightsail instances billing full price, idle public IPv4). Read-only `scripts/aws-cost-inventory.sh` does the AWS sweep; `scripts/ec2-ssh-sweep.sh` asks for SSH/SSM access to every running EC2 box and runs a read-only collector (memory, I/O, real traffic, logins, deploys) so nothing is called "idle" from CPU alone. Tiered A/B/C report with exact commands; non-cost findings are handed to infra-audit | on demand |
| [infra-audit](infra-audit/SKILL.md) | Audits a startup's infra against thirteen questions — **append-only CloudTrail** (Object Lock COMPLIANCE, 14-rule PASS/FAIL table modelled on a verified reference trail), what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA enforced everywhere, RDS rotating password, crash/OOM resilience, observability, mainstream vs budget hosting, containerized code — plus security hygiene found on the way. Read-only `scripts/aws-audit-inventory.sh` + the same SSH sweep with an audit collector (patching, ports, users, secret *names* only, backups, startup config). Scorecard report | on demand |
| [sec-ops](sec-ops/SKILL.md) | Operational-security audit for 2–10 person startups — thirteen questions: **all code in the company repo**, **no ex-contractor/ex-engineer access anywhere**, **CEO has admin on everything and every account and every server is in the company's name** (live hosts and the API hosts the frontend calls are resolved to IP owner → provider → is that account in the inventory; residential IPs and tunnels flagged), plus no secrets in repo history, no shared logins, prod access by named person, domains company-owned, billing in the company's name, app-store/registry accounts company-owned, a company password manager, prod secrets in a store and rotated after departures, SPF/DKIM/DMARC working with no external forwards, per-identity 2FA (overlaps infra-audit on purpose). Needs wide access: API/CLI/MCP per system preferred (`scripts/saas-access-inventory.sh` covers ~20 vendors, guarded by whatever token/CLI is present), screenshots transcribed to JSON as the fallback. Q1 is the heavy one: `live-vs-repo.sh` fetches every live hostname's page and JS bundles, fingerprints the stack, pulls API hosts/paths/env names and greps them in the repo, lists every place code runs in AWS (Lambda, ECS, EventBridge schedules, Glue, Step Functions, …) and produces `CODE-RECONCILIATION.md` with MATCH/NO MATCH per host and unit plus structural gaps (backend with no frontend; pipelines with no source); `dependency-provenance.sh` flags low-volume npm/PyPI packages maintained by current or former employees (company code living in one person's registry account). Read-only `github-access-inventory.sh`, `repo-scan.sh` (history secret scan, committers, personal-repo deps, CI secret exposure), `domain-inventory.sh` (whois/DNS/DMARC/who-hosts-what), the same SSH sweep with a people-and-code collector (`on-box-secops.sh`: authorized_keys fingerprints, logins, AKIA ids, git repos on disk with uncommitted/unpushed counts, app dirs with no repo). `secops-digest.py` merges everything into a people × systems **access matrix** (former people first) and an ownership table. Scorecard report + filled-in removal-and-rotation runbook; removes nobody, rotates nothing; recommends no enterprise controls (SSO/MDM) | on demand / after every departure |
| [pr-demo-media](pr-demo-media/SKILL.md) | Demos frontend PRs: records a Playwright video or captures before/after screenshots — whichever fits the change — and posts it on the PR with `gh pr comment --attach` | continuous loop, ~20–30 min |
| [pr-watcher](pr-watcher/SKILL.md) | Runs any of the PR-reactive skills on the PRs that qualify — yours, opened in the last 7 days, by default: `/pr-watcher run /auto-reviewer /ci-runner`. Sweeps every qualifying open PR first, then handles each one the moment it changes: one `gh webhook forward` per repo (polling if the repo won't grant a webhook) feeds a queue; the agent drains it with a capped number of subagents, one per PR. The watcher itself writes nothing to GitHub | while the session runs |

## Install

Symlink into the user skills directory so they're available in every session:

```bash
for s in auto-reviewer ci-runner dependency-updater infra-cost-review infra-audit sec-ops pr-demo-media; do
  ln -sfn "$PWD/$s" ~/.claude/skills/$s
done
```

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
- Write surfaces: auto-reviewer and pr-demo-media post comments only;
  ci-runner posts statuses + one upserted comment; dependency-updater pushes
  branches and opens PRs. Nothing merges, force-pushes, or deletes.

The three audit skills are different in kind: they never write to any provider or to any server —
inventory is read-only, the on-box collectors only read (the sweep runner refuses to send a script
containing a write/delete/package/service command), and every change is a recommendation with a
snapshot-first, two-confirmation gate for anything irreversible (for sec-ops: transfer before
removing a person, replace a token before revoking it, rotate after switching consumers).
`scripts/ec2-ssh-sweep.sh` is identical in all three skills; keep the copies in sync. sec-ops
hands AWS configuration findings (CloudTrail, MFA enforcement, ports) to infra-audit and cites it.

The GitHub agents compose: dependency-updater opens PRs → ci-runner runs them →
auto-reviewer reviews them → pr-demo-media demos the frontend ones. pr-watcher
is how the last three run *on change* rather than on a timer: one watcher, one
webhook, and it invokes whichever of them it was started with per changed PR
(a shell process can't invoke a skill, so the agent running pr-watcher does
the dispatching — the watcher only queues).
