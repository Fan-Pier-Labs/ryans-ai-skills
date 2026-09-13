# Cost smells — detection, why it matters, what to do, how reversible

Organized by the kind of mistake, not by AWS service, because the same mistake shows up under
different names on every provider. Each entry: **Detect** (read-only), **Why**, **Recommend**,
**Reversibility**. Apply against the inventory; report only what you actually found.

Contents: §1 Billing-model traps · §2 Waste · §3 Wrong shape · §4 Hand-offs to infra-audit ·
§5 Missing guardrails · §6 Non-AWS equivalents · §7 What the SSH sweep adds

---

## 1. Billing-model traps (invisible in a resource listing)

### 1.1 Lightsail bills stopped instances at full bundle price
- **Detect:** `lightsail get-instances` → any `state.name != running`. Cross-check Cost Explorer
  usage type `*-BundleUsage:*` against the count of *running* instances: if it bills for 7 and 3
  are running, there's your $130/month.
- **Why:** Opposite of EC2. Stopping a Lightsail instance to "save money" saves nothing. Real
  account: four stopped 8 GB bundles, $176/month, for years.
- **Recommend:** `create-instance-snapshot` (an 8 GB snapshot is ~$2–8/mo vs $44), wait for
  `available`, then `delete-instance`. Static IPs attached to deleted instances become
  `UnusedStaticIP` — release or reattach.
- **Reversibility:** Snapshot → delete is fully recoverable (restore creates a new instance; the
  public IP changes unless a static IP was attached).

### 1.2 Every public IPv4 address costs money (since Feb 2024)
- **Detect:** Cost Explorer usage types `PublicIPv4:InUseAddress` and `PublicIPv4:IdleAddress`;
  `ec2 describe-addresses` with no `AssociationId`; EIPs whose `InstanceId` is a *stopped*
  instance; Lightsail `UnusedStaticIP`.
- **Why:** ~$3.65/address/month, in use or not. It quietly becomes a top-5 line item (12% of one
  reviewed account) because nothing "owns" it.
- **Recommend:** Release unassociated EIPs and those on long-stopped instances. Keep any address a
  third party has allowlisted — tag it `DoNotRelease=true` and say why.
- **Reversibility:** **Irreversible** — a released IP cannot be recovered. Two-confirmation action.

### 1.3 Load balancers grow one billed IP per availability zone
- **Detect:** `elbv2 describe-load-balancers` → `len(AvailabilityZones)`. Anything > 2.
- **Why:** An ALB in 6 AZs has 6 ENIs = 6 public IPv4 = ~$22/month per ALB, for no HA benefit
  beyond 2–3 AZs. Elastic Beanstalk and the console default to "all subnets".
- **Recommend:** Trim to 2 AZs where target groups have healthy instances. Online operation.
- **Reversibility:** Fully reversible (add the subnets back).

### 1.4 NAT gateways bill hourly regardless of traffic
- **Detect:** `ec2 describe-nat-gateways` + CloudWatch `BytesOutToDestination`.
- **Why:** ~$33/month each before data processing. Common in dev VPCs where a single instance's
  egress is the only reason it exists.
- **Recommend:** For low-volume egress that just needs a stable IP, a `t4g.nano` NAT instance
  (~$3–4/mo) or putting the EIP directly on the one instance. Keep the managed NAT when
  patching a NAT instance is a real burden or throughput matters.
- **Reversibility:** Reversible (route table change).

### 1.5 Log storage without lifecycle grows forever
- **Detect:** `s3api get-bucket-lifecycle-configuration` → `NoSuchLifecycleConfiguration` on
  access-log/CloudTrail buckets; `logs describe-log-groups` with no `retentionInDays`.
- **Why:** Cheap today, unbounded tomorrow. 45 GB of ALB access logs nobody reads.
- **Recommend:** 90-day expiration on access logs; Glacier/IA transition then expiry on
  CloudTrail; 30–90 day retention on log groups.
- **Reversibility:** Setting retention is reversible; the expiry itself is destructive for the
  aged-out objects — pick windows deliberately.

### 1.6 Snapshots and AMIs of dead instances
- **Detect:** `describe-snapshots --owner-ids self`, `lightsail get-instance-snapshots`; match
  `fromInstanceName`/`Description` against instances that no longer exist; anything > 2 years old.
- **Why:** Small each, dozens together; often the *only* remaining trace of a retired app.
- **Recommend:** Keep the newest per source, delete the rest. If a snapshot is the last copy of
  something, that's a Tier C decision, not a Tier A deletion.
- **Reversibility:** **Irreversible.** Two-confirmation.

### 1.7 Stopped EC2 still bills for EBS and any attached EIP
- **Detect:** `State=stopped` + `StateTransitionReason` date; volumes and EIPs on those instances.
- **Why:** "Stopped since 2020" is a common finding; the volume and IP have billed every month.
- **Recommend:** Snapshot the volume, release the EIP, terminate.
- **Reversibility:** Snapshot makes the data recoverable; the IP is not.

### 1.8 Secrets Manager / KMS / Route 53 lines in a region "you don't use"
- **Detect:** Cost Explorer by region; a $2.50 line in ap-south-1 with no listed resources.
- **Why:** Usually a secret pending deletion (bills until the window closes) or a forgotten
  hosted zone. Small, but it's also how you discover the region sweep was incomplete.

---

## 2. Waste (clearly unused)

- **Unattached EBS** (`status=available`): snapshot, then delete. Check `VolumeReadOps` = 0 for
  30–90 days if you want to be sure nobody attaches it periodically.
- **Unattached Lightsail disks**, `available` state.
- **Empty target groups**, load balancers with ~0 requests over 14–30 days.
- **Elastic Beanstalk environments** with a stopped/terminated underlying instance but a live ALB.
- **WorkMail / SES / Chime seats** for people who left: `workmail list-users`.
- **Abandoned buckets** (112 bytes, empty) — no cost, but noise that hides the real ones.
- **Dev/staging environments with zero human traffic.** This is the biggest "waste" category and
  the hardest to see: the process is up, the load average is 0.00, and nobody has logged in for
  six weeks. The SSH sweep's `real-traffic` and `humans` sections are built for this: access-log
  requests with scanner noise (`/.env`, `/wp-login.php`) filtered out, last logins, newest
  deployed file, last git commit on the box. A month with zero business events and no deploy is
  a decommission candidate, and every resource behind it moves to Tier A.

---

## 3. Wrong shape (right idea, wrong size or primitive)

### 3.1 Oversized instances
- **Detect:** 14-day `CPUUtilization` avg/max per running instance (the inventory script does
  this). A `t3.xlarge` at 0.4% avg / 13% max is 30x oversized.
- **Why:** Instances are sized on launch day and never revisited.
- **Recommend:** Step down conservatively (`xlarge → large` first) unless you have memory
  metrics (CloudWatch agent) or can check `free -m` on the box. CPU alone does not prove a box
  is idle — it may be memory- or I/O-bound. Say what you checked.
- **Reversibility:** Resize is reversible; needs a stop/start (brief outage).

### 3.2 Dev boxes running 24/7
- **Detect:** Name/tag says dev/staging/test; CPU is spiky (high max, low avg) or flat zero.
- **Recommend:** Instance Scheduler / a cron'd `stop-instances` outside working hours (~70%
  saving at 12h × 5d), or downsize to burstable `t3`/`t4g`. Or decommission (§2).

### 3.3 Always-on for intermittent work
- **Detect:** A server whose only job is a scheduled task, a webhook receiver, a proxy, a cron.
- **Recommend:** Lambda / scheduled Fargate task / EventBridge Scheduler. If it needs a stable
  egress IP, that belongs on a NAT or a tiny instance — not on a fat always-on box.

### 3.4 Wrong compute family for the situation
- **Lightsail** is a fixed-price single box for people who never want to see a VPC. The moment a
  workload needs an Elastic IP in a VPC, a NAT gateway, an ALB, IAM roles, or private subnets,
  it has outgrown Lightsail — and Lightsail static IPs **cannot** be moved to EC2 (separate
  pools). Plan the migration; don't bolt VPC peering onto it forever.
- **Fargate always-on** (~$9/mo minimum for 0.25 vCPU) for a job that runs a few hours a week →
  scheduled task or Lambda.
- **x86 where Graviton works** (`t3` → `t4g`, ~20% cheaper) for anything you can rebuild.
- **Database class from years ago:** `db.t3.medium` DocumentDB for an app whose only other trace
  is a 2021 snapshot → Tier C: is the app alive?

### 3.5 On-demand for steady state
- **Detect:** Same instances running 24/7 for > 1 year, no Savings Plan (`ce
  get-savings-plans-coverage`). Only relevant once the account is *clean* — never buy commitments
  for instances you're about to delete or resize.
- **Reversibility:** Commitments are **irreversible** for the term. Recommendation only.

---

## 4. Not cost findings — hand these to infra-audit

The cost sweep will surface things that are not about money: a database process on the app box,
secrets in a config file on a public host, a box with 700 days of uptime, a "temporary" VPC
peering that became permanent. Do not drop them and do not bloat the cost report with them.
List each in the report's "Handed to infra-audit" section in one line with where you saw it,
then let the `infra-audit` skill do the security/reliability work. The one exception: if a
self-hosted database is the *reason* a box cannot be downsized or decommissioned, say so in
the cost finding, because the managed-DB migration is then a prerequisite for the saving.

---

## 5. Missing guardrails (cost nothing, prevent the next review being an afternoon)

- **No cost-allocation tags** (`Project`, `Owner`, `Environment`) on anything → you cannot
  attribute spend; the reviewer ends up reading CPU graphs and guessing from names. Detect:
  tag coverage in the digest. Recommend: tag everything now; enforce via SCP/Config rule later.
- **No AWS Budget** (`budgets describe-budgets` empty) → a single alert at ~110% of steady-state
  would have caught every stopped-Lightsail story before it ran for years.
- **No Cost Anomaly Detection monitor** (`ce get-anomaly-monitors` empty). Free.
- **No Compute Optimizer / Cost Optimization Hub enabled** — they pre-compute most of §3 for you.
- **Stale CLI profiles** everywhere (`~/.aws/config` with five expired identities) → verify with
  `sts get-caller-identity` before *every* review; record which profile is real in CLAUDE.md.

---

## 6. Non-AWS equivalents (same smells, different CLI)

| Smell | GCP | Azure | PaaS / DBaaS |
|---|---|---|---|
| Idle public IPs | `gcloud compute addresses list --filter=status=RESERVED` | `az network public-ip list` (unassociated) | n/a |
| Oversized VMs | `gcloud recommender recommendations list --recommender=google.compute.instance.MachineTypeRecommender` | Azure Advisor cost recommendations | Vercel/Netlify: check plan tier vs bandwidth/build minutes actually used |
| Stopped-but-billed | Stopped GCE VMs don't bill compute but do bill disks + static IPs | Deallocated (not just stopped) VMs stop billing; "Stopped" still bills | Render/Fly: suspended services still bill volumes |
| Orphaned disks/snapshots | `gcloud compute disks list --filter="-users:*"` | `az disk list --query "[?diskState=='Unattached']"` | Fly volumes with no app |
| Self-hosted DB on VM | Same detection; recommend Cloud SQL / Memorystore / Atlas | Azure Database for Postgres/MySQL, Cosmos, Cache for Redis | Neon, Supabase, PlanetScale, Upstash, Atlas |
| No budget | `gcloud billing budgets list` | `az consumption budget list` | Provider spend caps (Vercel spend management, Netlify usage alerts) |
| Logs forever | Cloud Logging retention per bucket | Log Analytics retention | n/a |

The method is identical: inventory read-only → attribute every dollar or say unknown → walk the
smells → tier → report with evidence and reversibility.

---

## 7. What the SSH sweep adds (per box, from `scripts/on-box-cost.sh`)

CloudWatch gives you CPU. The box gives you the rest. Section → what it settles:

| Section | Use it to decide |
|---|---|
| `memory` | Whether a low-CPU box is actually memory-bound (`MemAvailable` small, swap in use, one process holding most RSS). A `t3.xlarge` at 1% CPU with 14 GB of 16 GB in use is *not* oversized — it needs a memory-optimized smaller family (`r6g.large`), not `t3.large`. |
| `load-and-io` | `vmstat` `b`/`wa` columns and `iostat` utilisation: I/O-bound boxes need gp3 IOPS or a managed DB, not a bigger instance. `sar` history, when sysstat is installed, is the closest thing to a memory graph. |
| `disk` | Root volumes sized for a database that has since moved; 8 GB of logs on a 100 GB gp2 → shrink + gp3. |
| `network-bytes-since-boot` | Divide by uptime for GB/day; compare with the data-transfer line in Cost Explorer to find the box that is the egress bill. |
| `listening-services` / `process-managers-and-containers` | What the box is *for*. A box running only a cron and an idle nginx is a Lambda; a box running six containers is not going to `t4g.nano`. |
| `scheduled-work` | The always-on-for-a-cron pattern (§3.3). |
| `real-traffic` | Requests from real clients in the current access log, scanner-filtered. Zero or single-digit real requests with no deploy in a month → decommission candidate (§2). |
| `humans` | Last logins, last deploy, last commit. "Nobody has touched it since March" is the second signal you need before calling something waste. |
| `runtimes` | Not a cost item; hand EOL runtimes to infra-audit. |

Treat one sample as one sample. `free -m` at 3pm on a Tuesday is a point, not a trend; say so,
and prefer `sar` history or a week of CloudWatch-agent memory metrics when a downsizing decision
is worth more than an hour of someone's time.
