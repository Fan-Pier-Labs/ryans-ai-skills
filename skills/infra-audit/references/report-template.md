# Audit report template

Use this shape. Every one of the thirteen questions gets a row in the scorecard and a section,
even when the answer is "Yes, verified" in one line — a reader checking the audit against the
checklist should never wonder whether a question was skipped. Lead with the worst thing. Keep
the prose for someone who knows the domain but didn't watch you work: what it is, why it
matters, what to do, how sure you are.

---

```markdown
# Infrastructure Audit — <company / project name>

**Scope:** <AWS account id (identity you ran as)>, <other providers found: Vercel, Render, Atlas…>
**Region(s):** <where things are; "other regions swept: none found">
**Audit date:** <YYYY-MM-DD>
**Evidence:** AWS inventory (`infra-audit-<acct>-<date>/`), SSH sweep of <N>/<M> running
instances (`ssh-sweep-<date>/`) <or "SSH access not granted — on-box questions marked Unknown">,
repo <path/branch>, DNS, <what the user told you, labelled as such>

---

## Summary

<Three to five sentences. The single worst finding first, with its consequence. Then the
overall shape: "a two-provider setup (AWS + Render) with a self-hosted Postgres, no append-only
trail, and good observability." End with what fixing the top three costs in time.>

## Scorecard

| # | Question | Answer | Severity if No | One-line evidence |
|---|---|---|---|---|
| 0 | Append-only CloudTrail | Yes / **No** / Partial / Unknown | Critical | <n> of 14 rules pass |
| 1 | No immediate scaling roadblock | | High | <the thing that breaks first> |
| 2 | DB backups set up | | Critical | <RDS 7d + PITR / cron pg_dump last ran …> |
| 3 | Not self-hosting the DB | | Critical | <postgres on i-…, port 5432 …> |
| 4 | Right infra for the use case | | Medium | |
| 5 | One provider per purpose | | Medium | |
| 6 | ≤ 2 infra providers | | Medium | <count: AWS, Vercel, Clerk, Atlas = 4> |
| 7 | 2FA enforced everywhere | | High | <root MFA yes; 2/5 IAM users no MFA; GitHub reported yes> |
| 8 | RDS rotating password in Secrets Manager | | High | |
| 9 | Crash/OOM resilient | | High | <bare EC2 + pm2, no startup hook> |
| 10 | Observability set up | | Medium | |
| 11 | Mainstream provider for critical pieces | | Medium | |
| 12 | Code is containerized | | Medium | <Dockerfile + ECR image in ECS task def / pm2 on a checkout> |

**Security findings on the way:** <n> Critical, <n> High, <n> Medium — see the section below.

---

## Q0. Append-only CloudTrail — <Answer>

<Paste the PASS/FAIL table from DIGEST.md. If FAIL: which rules, what the exposure is, and the
fix from `cloudtrail-append-only.md` §4 with the retention period called out as a decision.>

## Q1. Scaling roadblocks — <Answer>

<The one thing that breaks first, the trigger, and the fix. Evidence: instance/ASG/DB class,
on-box memory, connection limits.>

## Q2. Database backups — <Answer>

## Q3. Self-hosted database — <Answer>

<If Yes: where, how exposed, what it holds, the managed target, the migration shape. This
section is longer than the others when the answer is Yes.>

## Q4. Right infra for the use case — <Answer>

## Q5. One provider per purpose — <Answer>

## Q6. Number of infra providers — <Answer>

<The list, with what each does, and the consolidation order.>

## Q7. 2FA — <Answer>

| Surface | MFA | Enforced | Verified how |
|---|---|---|---|
| AWS root | | | credential report |
| IAM users (n) | | | credential report / deny-without-MFA policy present? |
| GitHub org | | | reported by user |
| <PaaS / DBaaS / registrar / DNS / email / Stripe> | | | |

## Q8. RDS password rotation — <Answer>

## Q9. Crash / OOM resilience — <Answer>

## Q10. Observability — <Answer>

| Layer | Tool | Alerts a human? |
|---|---|---|
| Errors | | |
| Logs / metrics / uptime | | |
| Product analytics | | |

## Q11. Hosting-provider tier — <Answer>

## Q12. Containerized — <Answer>

<What builds the image, where it is pushed, what runs it in prod. Partial: which parts are not.>

---

## Security findings

### [Critical] <Title>
**Where:** <resource / host / file> · **Evidence:** <command or sweep section> · **Fix:** <exact,
reversible step; rotation if a secret>

### [High] …
### [Medium] …
### [Low] …

---

## Per-instance notes (from the SSH sweep)

| Instance | Role | OS / uptime | Patching | DB on box | Secrets on disk | Restart-safe | Notes |
|---|---|---|---|---|---|---|---|

<Instances that were not reachable: list them and what is therefore Unknown.>

---

## Recommended sequence

**This week (hours, no risk):** <append-only trail; MFA; GuardDuty; PITR on; IMDSv2; close ports>
**Next (a day or two, needs a window):** <managed DB migration; secrets to Secrets Manager + rotate; pm2 startup / Fargate>
**Then (decisions):** <consolidate providers; Redshift for BI; org trail>

## Method and caveats

- Inventory is read-only API calls on <date>; the JSON is next to the digest.
- On-box evidence is one sample per instance on <date>; secret values were never read.
- Not examined: <application code security, dependency CVEs, network flow logs, …>.
- Answers marked "reported by user" were not verified.
- Probes that failed (permissions): <list, or "none">.
```

---

## Per-question contract

`answer (Yes/No/Partial/Unknown) → evidence (source + what it showed) → why it matters for
this company → recommended state → the exact step, with reversibility → confidence`

## Tone

Plain language, short sentences, tables for facts. Say what you checked and what you couldn't.
A "No" without a fix, or a fix without the command, isn't finished. Do not pad "Yes" answers;
one line of evidence is the whole section.
