# Audit checklist — the twelve questions, how to answer each, and what "good" looks like

Answer every question with **Yes / No / Partial / Unknown**, the evidence, and the recommended
state. "Unknown, could not verify" is an honest answer and better than a guess; say what would
have let you verify it. The order below is also roughly the order of importance for a startup.

Sources, by trust: AWS inventory (`DIGEST.md` + the JSON) → the SSH sweep (`box-*.txt`) → the
repo (IaC, `docker-compose*.yml`, `.env.example`, CI config, `package.json` deps) → DNS
(`dig`, `whois` on app hostnames tells you who hosts what) → what the user tells you → names
and guesses (label these).

Contents: Q0 Append-only CloudTrail · Q1 Scaling roadblocks · Q2 DB backups · Q3 Self-hosted DB
· Q4 Right infra for the use case · Q5 Split-brain hosting · Q6 Too many tools · Q7 2FA
everywhere · Q8 RDS rotating password · Q9 Crash resilience · Q10 Observability · Q11
Hosting-provider tier · S. Security hygiene found on the way

---

## Q0. Is there an append-only CloudTrail? (recommended: yes — required)

The full rule set, reference implementation, and fix are in `cloudtrail-append-only.md`; the
inventory prints the PASS/FAIL table. Quote the table. This question is first because an audit
whose own evidence base can be deleted is not an audit; it is also the cheapest fix on the list.

## Q1. If the app scales, what breaks first? (looking for: no immediate roadblocks)

You are not doing capacity planning; you are looking for the one thing that falls over at 10×
current traffic and takes a week to fix under pressure. Usual suspects, in order of how often
they are the answer:

- **A single instance holding state** — sessions in process memory, uploads on local disk,
  SQLite on the root volume, a cron that assumes one box. Detect: SSH sweep `listening-ports`,
  `disk`, `scheduled-work`; repo for `express-session` without a store, `multer` to disk,
  `sqlite`. Fix: S3 for files, Redis/DB for sessions, then you *can* add a second instance.
- **The database on the app box** (Q3) — cannot scale independently of the app.
- **Vertical-only scaling with no headroom**: a `t3.large` at 60% memory with no ASG. Detect:
  `ec2_instances` (ASG column), SSH `memory`. Burstable `t` family with credits exhausted is a
  common silent roadblock — check `CPUCreditBalance` if the box is a `t*`.
- **Connection limits**: Postgres `max_connections` (RDS default ~ `{DBInstanceClassMemory/9531392}`,
  a `db.t3.micro` has ~85) with a Lambda or a pool-per-worker app in front. Detect: RDS class +
  Lambda count + no RDS Proxy. This is the classic "worked until launch day" failure.
- **Lambda concurrency / API Gateway limits** for bursty traffic; DynamoDB provisioned capacity
  with no autoscaling (`dynamodb_detail.billing`).
- **No CDN in front of static assets** served by the app server (CloudFront/Vercel absent,
  `nginx` serving `/static` from disk).
- **Single AZ** for anything stateful (`rds MultiAZ=false` is acceptable for a startup; a
  self-managed DB on one EBS volume is not).
- **Hard-coded limits**: one worker process (`pm2` with `instances: 1` on a 4-vCPU box),
  `ulimit` defaults, a 1 GB Node heap.

Say which one and what the trigger would be ("at ~300 concurrent users the DB connection pool
saturates"). Do not list all eight for every account.

## Q2. Are database backups set up? (recommended: yes)

- **Managed** (RDS/Aurora/DocumentDB/Lightsail DB/Atlas/Neon/Supabase/PlanetScale): automated
  backups are on by default — check they were not turned off (`BackupDays = 0` is the finding)
  and that retention is ≥ 7 days. Point-in-time restore comes with it. DynamoDB: PITR is **off**
  by default (`dynamodb_detail.pitr`), which is the common miss. ElastiCache: snapshots default
  to 0 days; fine if it is only a cache, a finding if sessions or queues live there.
- **Self-hosted**: look for evidence of a *working* backup: a cron with `pg_dump`/`mongodump`,
  `restic`/`rclone` to S3, recent `*.dump`/`*.sql.gz` files (SSH `databases on this box` section
  prints all three). EBS snapshots of the volume count only if they are scheduled (Data
  Lifecycle Manager / AWS Backup plan) and the DB is crash-consistent; say that.
- **Restore has been tested**: ask. Nobody has; the recommendation is a quarterly restore into
  a scratch instance. A backup that has never been restored is a hypothesis.

## Q3. Are they self-hosting their own DB? (recommended: no)

The lead finding whenever it is true. Detect: security group with 27017/5432/3306/6379 open;
SSH `listening-ports` + `databases on this box`; repo `DATABASE_URL=...@localhost` or
`mongodb://172.31.x.x`; `postgres:` service in the production compose file.

Why it matters is not cost: no automated backups or PITR unless someone built them (Q2), no
failover, patching nobody does, the data on the same disk as the app, a port that was opened
"once, for Compass". The cost of doing it right is $15–60/month; the cost of doing it wrong is
the company. Recommend the managed equivalent sized small, with the migration shape (dump →
restore in a window → old process read-only for a week → remove and close the port):

| Engine | Managed options |
|---|---|
| Postgres | RDS / Aurora Serverless v2, Neon, Supabase |
| MySQL | RDS, PlanetScale, Lightsail managed MySQL for a tiny fixed price |
| MongoDB | Atlas (M0 free / M10 ~$57), DocumentDB only if already deep in AWS |
| Redis | ElastiCache Serverless, Upstash; if it is only a cache, self-hosted is tolerable — say so |
| SQLite | Acceptable on one box **only** with Litestream/Turso replicating it off-box |

## Q4. Is it the right infra for the use case? (looking for: fit, not fashion)

Match the workload to the primitive. The pattern to catch is a tool chosen because it was
familiar or trendy, now fighting the problem:

| Workload | Wrong-shaped choice you will see | Fit |
|---|---|---|
| BI / analytics / dashboards over historical data | DynamoDB + Lambda scans; Postgres OLTP instance doing 30-second aggregate queries | Redshift (or Redshift Serverless), BigQuery, Snowflake, ClickHouse; at small scale, Postgres read replica + materialized views |
| Transactional web app | DynamoDB with 6 GSIs emulating joins | Postgres/MySQL (RDS) |
| Simple key/value at scale, known access patterns | Postgres table with 500M rows and no partitioning | DynamoDB |
| Background jobs / queues | Cron on the web box; polling a DB table | SQS + worker (Fargate/Lambda), or a job library with Redis (BullMQ/Sidekiq) |
| Bursty API, low baseline | Always-on `m5.large` | Lambda / Fargate with scaling, or a PaaS |
| Steady high-throughput API | Lambda with 5,000 invocations/s and a VPC cold-start problem | Containers on Fargate/ECS, or EC2 in an ASG |
| Static frontend / Next.js | Apache on a Bitnami box | Vercel / Netlify / S3 + CloudFront |
| Full-text search | `LIKE '%x%'` on Postgres at scale | Postgres FTS first; OpenSearch/Meilisearch/Typesense when that runs out |
| ML inference | GPU box on 24/7 for 200 requests/day | Batch/scheduled, SageMaker Serverless, or an API provider |

Detect from the inventory (what exists) and the repo (what it is used for). Ask what the
product does if the repo does not tell you; a wrong answer here is expensive.

## Q5. Same purpose, different providers? (recommended: no — one home per layer)

Half the backend on Render, half on AWS; the API on Fly and the workers on EC2; Postgres on
Supabase *and* RDS. Detect: DNS for each hostname (`dig +short api.example.com` → who owns the
IP/CNAME), the repo's deploy configs (`render.yaml`, `fly.toml`, `vercel.json`, `Procfile`,
`serverless.yml`, `.github/workflows/*deploy*`), env vars pointing at external hosts, and the
billing email list. Why it is a red flag: two IAM models, two secret stores, two log systems,
two on-call runbooks, cross-provider egress bills, and network paths that go over the public
internet between halves of one app. Recommend consolidating to the provider that holds the
data; the other half is usually a weekend to move. Legitimate exceptions: a CDN/frontend host
(Vercel) in front of an AWS backend is normal; a separate provider for **background/batch
work** is fine (see Q11).

## Q6. Too many software tools? (recommended: 1 infra provider, at most 2)

Count distinct infrastructure/platform vendors with a bill: cloud (AWS/GCP/Azure), PaaS
(Render/Fly/Railway/Heroku), frontend hosts (Vercel/Netlify), DBaaS (Atlas/Supabase/Neon/
PlanetScale/Upstash), auth (Clerk/Auth0/Cognito), queues, search, email, observability, CDN,
secrets. A five-person startup on AWS + Render + Vercel + Azure + Clerk + Atlas has six control
planes to secure (Q7), six invoices, and no one who knows all of them. Rule of thumb: one cloud
plus at most one specialist platform (a frontend host or a DBaaS) is healthy; three or more
compute/hosting providers is the flag. SaaS *services* (Stripe, SendGrid, Datadog) are not
"infra" for this count, but list them so Q7 covers them. Recommend which to consolidate into
which, with the migration order (cheapest and least risky first).

## Q7. 2FA set up and enforced on every infra piece? (recommended: yes)

"Every" means: AWS root (`AccountMFAEnabled`), every IAM user with a console password
(credential report `mfa_active`), and — via an IAM policy that denies everything without
`aws:MultiFactorAuthPresent` — *enforced*, not just available. Then GitHub org (require 2FA
setting), the PaaS/DBaaS accounts from Q5/Q6, the domain registrar and DNS provider (the one
everyone forgets; losing the domain loses everything), the email provider, Stripe, and the
password manager itself. Prefer SSO/IAM Identity Center with MFA over IAM users where the team
is > 3. You can verify AWS from the inventory; for the rest, ask, and record the answer as
"reported by user" rather than verified.

## Q8. RDS with a rotating password in Secrets Manager? (recommended: yes)

`rds_instances.ManagedPassword` — RDS-managed master passwords (`--manage-master-user-password`)
store the secret in Secrets Manager and rotate it every 7 days by default, and the app reads it
at connect time. The failure mode you are checking for: `DATABASE_URL=postgres://app:hunter2@…`
in an `.env` on the box (SSH `secrets-on-disk` will show `DATABASE_URL(len 63)` in a file with
`644` permissions) that has been the same string since 2023 and is in three people's shell
history. Recommend: managed master password for the master user, a separate least-privilege
app user whose credential is a Secrets Manager secret with rotation (the RDS single-user
rotation Lambda is one click), IAM database auth for Lambda/ECS callers. Same principle for
Atlas/Supabase/Neon: their dashboards have rotation; check when the app password last changed.

## Q9. Is the app server resilient to crashes and OOMs? (recommended: yes)

The test: kill the process, or let it leak memory to the limit — does traffic recover without a
human? Answer from the inventory's compute section:

| Setup | Verdict |
|---|---|
| Containers on Fargate/ECS with a service (`desired ≥ 1`), a health check, and the deployment circuit breaker; or Kubernetes with a Deployment | **Yes.** ECS restarts the task; the ALB stops routing to it meanwhile. |
| App Runner, Lambda, a PaaS (Render/Fly/Railway/Vercel serverless) | **Yes**, by construction. |
| EC2 in an ASG with an ELB health check | **Partial** — the instance is replaced (minutes of downtime, and only if the health check hits the app, not just port 22). |
| Bare EC2 with `pm2`/`systemd` `Restart=always` | **Partial** — the process restarts; an OOM-killed kernel, a full disk, or a hung box does not. Check `pm2 startup` is configured (SSH `web-server-and-app`); without it, a reboot leaves the app down. |
| Bare EC2 running `node server.js` in a `screen`/`nohup`, or Docker without `--restart` | **No.** |

Also check memory limits exist at all (ECS task `memory`, Docker `--memory`, Node
`--max-old-space-size`): without a limit the OOM killer chooses, and it often chooses the
database. Recommend the smallest step up: `Restart=always` + `pm2 startup` today; Fargate or a
PaaS as the real fix.

## Q10. Analytics and observability? (recommended: yes)

Three layers; a startup needs at least the first two:

1. **Errors** — Sentry/Bugsnag/Rollbar in the app (`@sentry/*` in `package.json`, `SENTRY_DSN`
   in env).
2. **Logs and metrics off the box** — CloudWatch agent, Datadog, New Relic, Grafana Cloud,
   Better Stack, Axiom; ECS `awslogs` driver counts. SSH `disk-and-logs` lists agents; "(none
   listed = logs live only on this disk)" means the logs die with the instance. Uptime check
   from outside (Better Uptime, Pingdom, a CloudWatch Synthetics canary) with a page/alert.
3. **Product analytics** — PostHog, Amplitude, Mixpanel, GA4. Absent is a business finding, not
   an infra one; note it in one line.

Alarms that page someone: `cloudwatch_alarms` with actions, or the vendor's monitors. Ten
dashboards and zero alerts is "not set up".

## Q11. A mainstream hosting provider for critical pieces? (recommended: yes)

App servers, the database, and anything customer-facing belong on a tier-one provider — AWS,
GCP, Azure, or a mainstream PaaS/frontend host on top of them (Vercel, Render, Fly, Railway,
Heroku, Netlify). Budget providers (Hetzner, OVH, Contabo, DigitalOcean's cheapest droplets, a
VPS from a reseller, a box under someone's desk) are a finding for **critical path** workloads:
weaker SLAs, thinner managed services (no equivalent of RDS/Object Lock/IAM), slower incident
response, and a harder story for customers' security questionnaires. They are a *good* choice
for **background processing, batch jobs, CI runners, scrapers, and dev environments** where an
hour of downtime costs nothing and the compute is 3–5× cheaper; say so rather than blanket-
recommending against them. Detect from DNS and IP ownership (`whois` on the app's IPs), the
repo's deploy targets, and the billing list. Recommend: move the critical path, keep the batch
work where it is if it is already cheap and isolated.

---

## S. Security hygiene you will find on the way (report under "Security findings")

Not one of the twelve questions, but the inventory and sweep surface them and a reader will
expect them. Severity in brackets.

- **[Critical] Secrets in cleartext on a public host** — SSH `secrets-on-disk` (names, files,
  perms; values are never printed). Move to Secrets Manager/SSM/the PaaS env store and
  **rotate**; relocating a leaked secret does not un-leak it. Cloud provider keys
  (`AKIA…` in `.aws/credentials` on an instance that has an IAM role) are the worst case.
- **[Critical] Database port or all-traffic open to 0.0.0.0/0** — `Security groups` section.
- **[High] Root account without MFA, root access keys, IAM users without MFA, access keys > 90
  days, no password policy** — identity section.
- **[High] Public S3 bucket / public AMI / public RDS** — storage and data sections.
- **[High] The never-rebooted box** — SSH `patching`: reboot-required, dozens of security
  updates pending, kernel from two years ago, EOL runtime (`runtimes-eol`). Rebuild from an
  image/IaC on a current base, or move to a PaaS where the OS is not your problem.
- **[Medium] IMDSv1 allowed** (`Imds=optional`) — SSRF-to-credential-theft path; set
  `HttpTokens=required`.
- **[Medium] SSH password auth on, `PermitRootLogin yes`, 22 open to the world with no
  fail2ban, stale `authorized_keys` for people who left** — SSH `ssh-and-users`.
- **[Medium] No GuardDuty / no Access Analyzer** — both are near-free and take one call.
- **[Medium] Unencrypted EBS / RDS; EBS encryption-by-default off.**
- **[Low] CloudFront without WAF; certificates renewing by a cron nobody watches; log groups
  that never expire; no cost-allocation tags.**
