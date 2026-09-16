---
name: infra-cost-review
description: Find where a cloud account's money is going and what can safely be cut — waste, wrong-sized resources, billing-model traps like Lightsail charging full price for stopped instances — using read-only AWS inventory plus an SSH look inside every running EC2 box, then deliver a tiered (waste / rightsizing / needs-a-decision) report with exact commands and reversible steps. Use whenever the user wants to cut, understand, or explain a cloud bill: "why is AWS so expensive", "what is this costing me", "reduce our infra spend", mentions FinOps, Cost Explorer, Savings Plans, rightsizing, idle instances, or asks whether to use Lightsail/EC2/Lambda/Fargate/a PaaS for cost reasons — even if they don't say "audit" or "review". AWS first-class (bundled scripts); the method applies to GCP, Azure, and PaaS bills. For security, reliability, backups, or architecture fitness, use infra-audit instead (this skill hands those findings off).
---

# Infra Cost Review

One question, asked of every resource in an account: **is this costing money it shouldn't?**
Waste (nothing depends on it), oversizing (same workload, smaller shape), and wrong pricing
model (on-demand for steady state, a NAT gateway for 50 requests a day, a stopped Lightsail box
billing at full price). The output is a report a non-engineer owner can act on: what it is,
what it costs, what you recommend, how sure you are, how to undo it.

This skill is *only* about money. Security, backups, self-hosted databases, and architecture
fitness are `infra-audit`'s job; when you see them here, list them in the report's hand-off
section and move on.

**Read-only by default, always.** Inventory and recommend. Run no `delete`/`terminate`/
`release`/`modify` unless the user explicitly asks for a specific finding after reading the
report, and even then snapshot first and refuse the irreversible ones (release an IP, delete a
snapshot) without a second confirmation. See "Gating".

## Why this skill exists

Left alone, a model reviewing a bill will quote prices from memory (wrong region, wrong year),
call a box "idle" from one CPU sample, guess an owner from a hostname, recommend deleting
things it hasn't proven unused, and miss the billing-model gotchas that never appear in a
resource listing. The canonical example: **Lightsail bills stopped instances at full bundle
price** — four stopped servers "saving money" at $176/month for years. Nothing in
`describe-instances` tells you that; `references/cost-smells.md` is the list of things you have
to know. The second failure is calling something oversized from CPU alone: a box at 1% CPU can
be memory-bound. That is why this skill logs into the boxes.

## Workflow

Run in order. Load a reference only when you reach the step that needs it.

### 1. Establish access and scope (read-only)

- Confirm identity: `aws sts get-caller-identity --profile <p>`. Never assume a profile works
  because it is listed in `~/.aws/config`; several are usually stale. Never run against an
  account you have not confirmed is the intended one.
- Ask, or read from the project's CLAUDE.md, what the workloads *are*. "Dormant dev box" vs
  "production checkout" changes every tier. If nobody can say, that is itself a finding.
- Check the other regions. `describe-regions` then a light sweep; "everything is in us-east-1"
  is an assumption until verified. The inventory script does an EC2/EIP sweep and a Cost
  Explorer by-region breakdown for the rest.

### 2. Inventory the account

```bash
scripts/aws-cost-inventory.sh --profile <profile> --region <region> [--days 14] [--out <dir>]
```

Read-only; writes JSON per probe plus `DIGEST.md`. It pulls Cost Explorer by service (3 months),
by usage type and by region (last month), EC2 with 14-day CPU avg/max, Elastic IPs and their
association state, unattached EBS, snapshot ages, Lightsail instances/IPs/snapshots/disks/DBs,
load balancers with AZ counts and request volume, RDS/DocumentDB/ElastiCache, S3 lifecycle
presence, log-group retention, Budgets and anomaly monitors, DB ports open to the world, tag
coverage, and instance counts in every other region. A missing permission becomes an `"error"`
field, not a crash. Read the digest first, then the JSON for anything you are about to claim.

For non-AWS providers there is no script — do the same inventory by hand (`gcloud`, `az`,
`vercel`, `fly`, the billing page) with the checklist in `references/cost-smells.md` §6.

### 3. Request SSH access to every running EC2 instance

CloudWatch gives you CPU. It does not give you memory, I/O wait, what processes are running,
whether real humans hit the box, or when it was last deployed to — and those are the numbers
that decide whether a box is oversized, idle, or the wrong primitive. So ask for access to all
of them, once, up front:

```bash
scripts/ec2-ssh-sweep.sh discover --profile <p> --region <r> --out <dir>
```

That prints a table of running instances (id, Name, IPs, key pair, platform, whether SSM
Session Manager can reach it) and writes `<dir>/hosts.tsv`. Show the user the table and ask
for, per host: the login user, the key (or "use my agent"), and any bastion — or "use SSM" for
the instances that show `ssm: yes`, which need no key at all. Explain in one sentence what will
run: a read-only script that samples memory, load, disk, network, listening services, cron,
access-log traffic, last logins and last deploy; it writes nothing, and secret values are never
printed. Fill in `hosts.tsv` (method `skip` for any the user excludes), then:

```bash
scripts/ec2-ssh-sweep.sh run --profile <p> --region <r> --hosts <dir>/hosts.tsv \
  --script scripts/on-box-cost.sh --out <dir> [--sudo]
```

`--sudo` prefixes `sudo -n` so root-readable logs are included when passwordless sudo exists;
it never prompts. The runner refuses to send any script containing a write, delete, package,
or service-control command, so a modified collector cannot quietly become a mutation. Output is
one `box-<instance-id>.txt` per host, sectioned; `references/cost-smells.md` §7 says what each
section settles. Lightsail boxes are not discovered automatically — `lightsail
get-instance-access-details` gives a temporary key; add them to `hosts.tsv` by hand if the
user wants them included.

If access is refused or a box is unreachable, say so in the report and downgrade every
utilisation claim for that box to "CPU only" with lower confidence. Do not skip the step
silently.

### 4. Attribute every dollar, or say "unknown"

For each meaningful line item: what it is, what it serves, who owns it, when it was created,
when it was last used. Sources, in order of trust: tags → CloudTrail create events → CloudWatch
metrics → the on-box sweep (traffic, logins, deploys) → resource names. **If you cannot
determine something, write "unknown, could not verify."** Never infer an owner from a hostname
like `418_backup_fromnov`; note that the name *suggests* a one-off copy and say the owner is
unknown. Guessed attribution is how the wrong thing gets deleted.

### 5. Walk the cost smells

Work through `references/cost-smells.md` against the inventory and the sweep output. It covers
billing-model traps you cannot see in a listing, waste, wrong shape, the hand-off list for
non-cost findings, missing guardrails (tags, budget, anomaly monitor), non-AWS equivalents, and
what each on-box section tells you. Each smell has detection, why, recommendation, and
reversibility. Do not recite the list; apply it and report only what you found.

### 6. Tier and write the report

Use `references/report-template.md`. The tiers are the report's spine:

| Tier | Meaning | Test |
|---|---|---|
| **A — Waste** | Cut it; nothing depends on it | Proven unused by ≥ 2 signals over 30–90 days (metrics + on-box traffic/logins), or structurally idle (unattached, unassociated, stopped for years) |
| **B — Rightsizing / configuration** | Same workload, cheaper shape | Metrics *and* the on-box memory/I/O sample support it; rollback is trivial |
| **C — Needs a human decision** | Might be load-bearing; only the owner knows | You cannot prove it unused from infrastructure alone |
| **Handed to infra-audit** | Not cost items | Self-hosted DB, secrets on disk, EOL runtime, never-rebooted box — one line each |

Every finding carries: **current $/mo → after $/mo → saved → confidence → evidence →
reversibility → the exact command(s)**. Give a "this week / next / decisions" sequence and a
landing-point range. Lead with the single biggest number.

### 7. Prices: verify, don't remember

Current spend is Cost Explorer — actual. **Target** prices (what a `t4g.medium` costs, what a
NAT gateway costs) must come from a primary source for the user's region — `aws pricing
get-products`, the service pricing page, or the user's own bill for an identical resource —
and be labelled estimates. Memorised prices are region-wrong and year-wrong; two runs of the
same review will disagree.

## Gating: what may run

```
recommend  ← default for everything
   ↓ user reads report and names a specific finding
snapshot/backup exists? ──no──→ create it first (or recommend only)
   ↓ yes
reversible (stop, resize, detach, remove subnet, add lifecycle)? ──yes──→ may run, then verify
   ↓ no  (release IP, delete snapshot/AMI/instance/DB, buy RI/Savings Plan)
ask again, explicitly, naming the resource and what is lost. Never batch these.
```

Anything that loses an identifier (an IP) or the last copy of data is a two-confirmation action.
Commitments (RIs, Savings Plans) are recommendation-only, and only once the account is clean —
never buy coverage for instances you are about to delete.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "It's stopped, so it's not costing anything." | True for EC2 compute. False for Lightsail (full price), the EBS volumes, and the EIP still attached. Check all three. |
| "I know gp3 is about $0.08/GB." | Region- and time-specific. Pull the live price or the bill; label it an estimate. |
| "0.4% CPU, it's idle, downsize it." | CPU is one signal. The sweep's `memory` and `load-and-io` sections are the second; if you couldn't get on the box, say so and recommend the conservative step. |
| "`free -m` shows 2 GB used, it fits in a `t3.small`." | One sample at one moment. Check `sar` history if present; otherwise say it's a point, not a trend. |
| "The name says backup, it's safe to delete." | The name is a hint, the owner is unknown. Snapshot, recommend, let the owner decide. |
| "Zero requests in the access log, kill it." | The current log file may be hours old after rotation; check `first/last line dates` and the rotated files before calling a box unused. |
| "Everything's in us-east-1." | Verified or assumed? A $2.50 Secrets Manager line in Mumbai is how you find out. |
| "That database on the box should be RDS." | Probably — but that's infra-audit's finding. Here it's one line in the hand-off list, unless it blocks a saving. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or where
the user's CLAUDE.md says such analyses live), plus a short chat summary that leads with the
total reducible spend and the single biggest finding. Record durable facts (profile names,
account IDs, "Lightsail bills stopped instances", the region everything lives in, which boxes
have SSM) in the project's CLAUDE.md so the next review takes minutes.

## Reference files

- `references/cost-smells.md` — the catalog: detection, why, recommendation, reversibility, plus what each SSH-sweep section settles. Read during §5.
- `references/report-template.md` — the tiered report skeleton and per-finding contract. Read during §6.
- `scripts/aws-cost-inventory.sh` — read-only AWS inventory; run during §2. `--help` for flags.
- `scripts/ec2-ssh-sweep.sh` — `discover` running instances, then `run` a collector on each over SSH or SSM; §3.
- `scripts/on-box-cost.sh` — the read-only collector the sweep sends to each box; memory, I/O, traffic, logins, deploys.
