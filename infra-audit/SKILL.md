---
name: infra-audit
description: Audit a startup's infrastructure for reliability, security, and fitness — answer thirteen concrete questions (append-only CloudTrail, what breaks first at scale, DB backups, self-hosted DB, right infra for the use case, split hosting, too many providers, 2FA everywhere, RDS password rotation, crash/OOM resilience, observability, mainstream vs budget hosting, containerized code) using read-only AWS inventory plus an SSH look inside every running EC2 box, and deliver a scorecard report with evidence and exact fixes. Use whenever the user asks to audit, review, assess, harden, or sanity-check their infrastructure, cloud setup, AWS account, or deployment; asks "is our setup dumb", "are we ready to scale", "what would a CTO/investor/SOC 2 auditor flag", "do we have backups", "is our database safe"; mentions due diligence, security posture, CloudTrail, MFA/2FA on AWS, or is about to add a database, a second hosting provider, or a self-hosted service — even if they don't say "audit". For pure cost reduction, use infra-cost-review instead.
---

# Infra Audit

The question is not "what does this cost" (that is `infra-cost-review`). It is: **would a
careful senior engineer let this company run on this?** Thirteen concrete questions, each with
a recommended answer, plus the security hygiene you find on the way. The report is a scorecard
with evidence a founder can hand to an investor or a new engineering lead.

| # | Question | Recommended |
|---|---|---|
| 0 | Is there an **append-only CloudTrail** (Object Lock, COMPLIANCE mode)? | Yes — required |
| 1 | If the app scales, what breaks first? | No immediate roadblock |
| 2 | Are database backups set up? | Yes (managed DBs do this by default; DynamoDB PITR does not) |
| 3 | Are they self-hosting their own DB on their own server? | No |
| 4 | Is it the right infra for the use case? (BI on DynamoDB + Lambda is not; Redshift is) | Fit |
| 5 | Same purpose on different providers? (half the backend on Render, half on AWS) | No |
| 6 | Too many infra providers? (Clerk + AWS + Render + Vercel + Azure) | 1, at most 2 |
| 7 | 2FA set up **and enforced** on every infra piece? | Yes |
| 8 | RDS with a rotating password in Secrets Manager? | Yes |
| 9 | App server resilient to crashes/OOMs? (Fargate: yes; bare EC2: no) | Yes |
| 10 | Analytics and observability (e.g. Datadog)? | Yes |
| 11 | Mainstream provider (AWS/GCP/Azure/Vercel) for critical pieces, not budget hosts (Hetzner)? | Yes — budget hosts are fine for background jobs |
| 12 | Is the code containerized (a Dockerfile that builds the thing that runs in prod)? | Yes |

`references/audit-checklist.md` has, for each: how to detect it, why it matters, what good
looks like, and the fix. Q0 has its own reference because it has a precise rule set.

**Read-only by default, always.** Inventory, log in, look, recommend. The only things this
skill ever changes are the ones the user names after reading the report, and the ones that
create things (a locked bucket, a trail, MFA enforcement) — never anything that deletes or
rotates without a second explicit confirmation, because rotation breaks whatever still uses
the old secret.

## Why this skill exists

A model auditing infrastructure from the AWS API alone will say "one t3.large, RDS Postgres,
looks fine" and miss that the RDS instance is empty and the real Postgres is on the t3.large
with port 5432 open, that `.env` on that box holds the Stripe live key with `644` permissions,
that `pm2` was started by hand and will not survive a reboot, and that half the API lives on
Render. It will also say "CloudTrail is enabled" when the trail delivers to a bucket any admin
can empty. The API tells you what exists; the box tells you what is true; the repo and DNS tell
you where the rest of the company lives. This skill makes you look at all three and forces an
explicit Yes/No/Partial/Unknown on every question so nothing is skipped quietly.

## Workflow

Run in order. Load a reference only when you reach the step that needs it.

### 1. Establish access and scope (read-only)

- Confirm identity: `aws sts get-caller-identity --profile <p>`. Never assume a profile works
  because it is in `~/.aws/config`; never run against an account you have not confirmed.
- Ask (or read from CLAUDE.md / the README) what the product does and what the workloads are.
  Q1, Q4 and Q11 are unanswerable without knowing whether this is a BI dashboard, a consumer
  app, or a batch pipeline.
- Ask for the **list of every provider with a bill** — cloud, PaaS, frontend host, DBaaS,
  auth, observability, registrar, DNS, email. The user's list is the starting point for Q5–Q7
  and Q11; you will verify what you can from DNS and the repo.

### 2. Inventory the AWS account

```bash
scripts/aws-audit-inventory.sh --profile <profile> --region <region> [--out <dir>]
```

Read-only (the one non-`get`/`list` call is `iam generate-credential-report`, which rebuilds
IAM's own report). Writes JSON per probe and `DIGEST.md`, which contains the **CloudTrail
append-only PASS/FAIL table** — the trail, its status and selectors, and the log bucket's
Object Lock, retention mode, a sample object's retention, versioning, public-access block,
policy denies, encryption, lifecycle, and tamper alerting — plus the identity picture (root
MFA, root keys, per-user MFA and key age from the credential report, password policy, Access
Analyzer), detective controls (GuardDuty, Security Hub, Config, alarms with actions), EC2 with
IMDSv2/IAM-profile/ASG columns, sensitive ports open to the world, EBS encryption, public AMIs,
ECS services with their task definitions (circuit breaker, health checks, secrets vs plain
env, log driver), Lambda runtimes past EOL, RDS/Aurora with backup days, public flag, managed
password and deletion protection, DynamoDB PITR per table, ElastiCache/Redshift/DocumentDB,
AWS Backup plans, Secrets Manager rotation, S3 per-bucket exposure, CloudFront/WAF, ACM
expiry, log retention, and an instance/RDS/Lambda sweep of every other region.

Read the digest first. Every claim in the report should point at a JSON file or a sweep
section.

### 3. Request SSH access to every running EC2 instance

The AWS API cannot see patch state, what listens on which port, who can log in, where secrets
sit on disk, whether the database is on the box, whether backups actually run, or whether the
app comes back after a reboot. Questions 2, 3, 8 and 9 and most of the security findings are
answered on the box. So ask for access to all running instances, once, up front:

```bash
scripts/ec2-ssh-sweep.sh discover --profile <p> --region <r> --out <dir>
```

That prints the running instances (id, Name, IPs, key pair, platform, whether SSM Session
Manager can reach it) and writes `<dir>/hosts.tsv`. Show the user the table and ask for, per
host: the login user, the key (or "use my agent"), and any bastion — or "use SSM" for instances
showing `ssm: yes`, which need no key. Say what will run: a read-only collector that reads
patch state, listening ports, database processes and config bind/auth settings, backup
artifacts, containers, sshd settings, users and keys, sudoers, firewall, secret *names* and
file permissions (values are never printed — only the variable name, file, and value length),
TLS certificates, process manager and startup configuration, monitoring agents, and cron. It
writes nothing. Fill in `hosts.tsv` (method `skip` for any excluded), then:

```bash
scripts/ec2-ssh-sweep.sh run --profile <p> --region <r> --hosts <dir>/hosts.tsv \
  --script scripts/on-box-audit.sh --out <dir> --sudo
```

`--sudo` prefixes `sudo -n` (never prompts) so `auth.log`, `sudoers`, root-owned `.env` files
and `sshd -T` are readable where passwordless sudo exists; without it those sections say so.
The runner refuses to send any script containing a write, delete, package, or service-control
command. Output is one `box-<instance-id>.txt` per host. Lightsail boxes are not discovered
automatically — `lightsail get-instance-access-details` returns a temporary key; add them to
`hosts.tsv` by hand.

If access is refused or a box is unreachable, the on-box questions for that host are
**Unknown** in the report, with a sentence saying what access would have resolved. Never
downgrade an Unknown to a Yes because the API side looked fine.

### 4. Look outside AWS

For Q4–Q7 and Q10–Q12 the account is half the picture. Read the repo: `Dockerfile`s, deploy configs
(`render.yaml`, `fly.toml`, `vercel.json`, `Procfile`, `serverless.yml`, `.github/workflows`),
`docker-compose*.yml` for the production shape, `package.json`/`requirements.txt` for Sentry,
Datadog, PostHog, Clerk, Auth0; `.env.example` for which external services exist. Resolve the
app's hostnames (`dig +short`, `whois` on the IPs) to see who actually hosts what. Anything you
cannot verify — GitHub 2FA enforcement, the registrar's MFA, Atlas backups — ask the user and
record the answer as "reported by user".

### 5. Answer the thirteen questions

Work through `references/audit-checklist.md`. For each question write the answer
(Yes / No / Partial / Unknown), the evidence with its source, why it matters *for this company*,
the recommended state, and the exact step. Q0 uses the PASS/FAIL table verbatim and
`references/cloudtrail-append-only.md` for the fix. Q1 names *the one thing* that breaks
first, not every scaling concept. Q3, when Yes, is the lead finding regardless of anything
else on the list. Then collect the security hygiene items (checklist §S) with severities.

### 6. Write the report

Use `references/report-template.md`: summary → scorecard (all thirteen rows, always) → one
section per question → security findings by severity → per-instance table → "this week / next
/ decisions" sequence → method and caveats. Lead with the worst thing. A "Yes, verified" is one
line; do not pad it. A "No" without a fix, or a fix without the command, is not finished.

## Gating: what may run

```
recommend  ← default for everything
   ↓ user reads the report and names a specific finding
creates something new and touches nothing existing
  (locked bucket + trail, GuardDuty, Access Analyzer, PITR on, a budget)  ──→ may run, then re-verify
   ↓ otherwise
changes an existing resource reversibly
  (IMDSv2 required, close a port, RDS backup days, deletion protection)   ──→ may run, then verify
   ↓ otherwise
rotates a secret, enforces MFA-deny, migrates a database, deletes anything
  ──→ ask again, explicitly, naming what breaks if something still uses the old value. Never batch.
```

Special case: **Object Lock COMPLIANCE is irrevocable for the retention period.** Confirm the
number of years with the user in so many words before creating the bucket.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "CloudTrail is enabled, Q0 is a Yes." | Enabled ≠ append-only. Run the rule table; COMPLIANCE-mode Object Lock on the bucket or it's a No. |
| "There's an RDS instance, so the DB is managed." | Check what the app's `DATABASE_URL` actually points at. The RDS instance may be a leftover. |
| "Backups are on by default for RDS." | `BackupRetentionPeriod` can be 0. DynamoDB PITR is off by default. Look. |
| "It's Dockerized, so it's crash-resilient." | Docker without `--restart` on a bare EC2 is not. Fargate with a service is. Q12 (containerized) and Q9 (resilient) are different questions. |
| "There's a Dockerfile in the repo, Q12 is a Yes." | Only if prod runs *that image*. A Dockerfile for local dev while prod is `git pull && pm2 restart` on a box is a No. |
| "They use Datadog, observability is done." | Does anything page a human? Ten dashboards and zero monitors is a No. |
| "Vercel plus AWS is two providers, that's a flag." | A frontend host in front of a cloud backend is the normal shape. The flag is the *same layer* split, or three-plus compute providers. |
| "Hetzner for the workers is a red flag." | Budget hosts for background/batch work are a good trade. Critical path is the concern. |
| "I couldn't SSH in, but the API looks fine, so Yes." | Unknown. Say what access would have resolved. |
| "Rotate the secret now, it's leaked." | Rotation breaks everything still using it. Recommend, name the consumers, confirm, then rotate. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or where
CLAUDE.md says such analyses live), plus a chat summary that leads with the worst finding and
the scorecard's No count. Record durable facts (profile, account id, trail and bucket names,
which boxes have SSM, the provider list) in the project's CLAUDE.md so the next audit is a
re-run, not a rediscovery.

## Reference files

- `references/audit-checklist.md` — the thirteen questions: detection, why, what good looks like, the fix; plus security hygiene with severities. Read during §5.
- `references/cloudtrail-append-only.md` — the 14 required rules and 5 recommendations, a verified reference implementation, hand-check commands, and the fix script. Read for Q0.
- `references/report-template.md` — scorecard report skeleton and per-question contract. Read during §6.
- `scripts/aws-audit-inventory.sh` — read-only AWS inventory → JSON + `DIGEST.md` (with the CloudTrail verdict); run during §2. `--help` for flags.
- `scripts/audit-digest.py` — builds the digest from the JSON; re-run alone if you edit the rules.
- `scripts/ec2-ssh-sweep.sh` — `discover` running instances, then `run` the collector on each over SSH or SSM; §3.
- `scripts/on-box-audit.sh` — the read-only collector; secret values are never printed.
