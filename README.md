# generic-coding-agents

Seven Claude Code skills. Four are standalone coding agents operating on
the repo you are currently in (or the repos/orgs you name via `REPOS`/`OWNERS`); one reviews
the quality of a whole codebase; two review cloud infrastructure (cost, and
reliability/security/fitness). All PR/repo discovery is done by deterministic bash scripts
(`scripts/`, in the skills that need it); the model does the judgment work on top.

| Skill | What it does | Cadence |
| --- | --- | --- |
| [auto-reviewer](auto-reviewer/SKILL.md) | Posts a thermo-nuclear code-quality review on any open, non-draft PR (active in the last week) with no feedback since its latest commit | continuous loop, ~20–30 min |
| [ci-runner](ci-runner/SKILL.md) | Runs each PR's own `.github/workflows` YAML locally (GitHub Actions credits are out) and posts commit statuses + failure logs. Fully deterministic and stateless — the `local-ci` status on the head SHA is the dedup ledger; `scripts/ci-runner.sh` is cron-able on its own. Design notes + all-local alternative in [ci-runner/README.md](ci-runner/README.md) | every ~10 min |
| [dependency-updater](dependency-updater/SKILL.md) | Bumps deps in every repo active in the last month, verifies by launching the app and running all tests, opens one PR per repo | on demand / weekly |
| [code-quality-audit](code-quality-audit/SKILL.md) | Reviews the code quality of a whole repository against sixteen questions — linter + type checker enabled *and enforced*, dead code, endpoint authentication **and authorization** (IDORs, not just missing guards), dead endpoints, duplicate code, unit tests, integration tests, whether the module graph is a DAG, types, CI gates on every PR, committed secrets, lockfile + dependency audit, oversized files, swallowed errors, README, and what percent of a vendored 105-rule ESLint baseline ([references/eslint-baseline.config.mjs](code-quality-audit/references/eslint-baseline.config.mjs), recommended 100%) is enabled. `scripts/repo-inventory.sh` builds a `DIGEST.md` in one read-only pass — import cycles, every endpoint with its visible auth and reference count, duplicate blocks, test/CI/secret/lockfile signals — and runs whichever analyzers are installed (eslint/tsc/mypy/ruff/knip/vulture/jscpd/madge), never `--fix`. Scorecard report; changes no code. Per-repo, where [auto-reviewer](auto-reviewer/SKILL.md) is per-PR | on demand / when inheriting a codebase |
| [infra-cost-review](infra-cost-review/SKILL.md) | Finds where a cloud account's money goes and what can safely be cut: waste, wrong-sized resources, billing-model traps (stopped Lightsail instances billing full price, idle public IPv4). Read-only `scripts/aws-cost-inventory.sh` does the AWS sweep; `scripts/ec2-ssh-sweep.sh` asks for SSH/SSM access to every running EC2 box and runs a read-only collector (memory, I/O, real traffic, logins, deploys) so nothing is called "idle" from CPU alone. Tiered A/B/C report with exact commands; non-cost findings are handed to infra-audit | on demand |
| [infra-audit](infra-audit/SKILL.md) | Audits a startup's infra against twelve questions — **append-only CloudTrail** (Object Lock COMPLIANCE, 14-rule PASS/FAIL table modelled on a verified reference trail), what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA enforced everywhere, RDS rotating password, crash/OOM resilience, observability, mainstream vs budget hosting — plus security hygiene found on the way. Read-only `scripts/aws-audit-inventory.sh` + the same SSH sweep with an audit collector (patching, ports, users, secret *names* only, backups, startup config). Scorecard report | on demand |
| [pr-demo-media](pr-demo-media/SKILL.md) | Demos frontend PRs: records a Playwright video or captures before/after screenshots — whichever fits the change — and posts it on the PR with `gh pr comment --attach` | continuous loop, ~20–30 min |

## Install

Symlink into the user skills directory so they're available in every session:

```bash
for s in auto-reviewer ci-runner dependency-updater code-quality-audit infra-cost-review infra-audit pr-demo-media; do
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

The two infra skills are different in kind: they never write to any provider or to any server —
inventory is read-only, the on-box collectors only read (the sweep runner refuses to send a script
containing a write/delete/package/service command), and every change is a recommendation with a
snapshot-first, two-confirmation gate for anything irreversible. `scripts/ec2-ssh-sweep.sh` is
identical in both skills; keep the copies in sync.

The GitHub agents compose: dependency-updater opens PRs → ci-runner runs them →
auto-reviewer reviews them → pr-demo-media demos the frontend ones.

code-quality-audit is the whole-repo counterpart to auto-reviewer's per-PR review, and like the
two infra skills it is read-only: it runs analyzers and the test suite, writes one report, and
changes no code. Run it when you inherit or acquire a codebase, then let auto-reviewer hold the
line on each PR after that.
