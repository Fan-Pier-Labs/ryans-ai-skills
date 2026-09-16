---
name: sec-ops
description: Operational-security audit of a small startup — who has access to what, who owns what, and where the code and secrets actually live. Answers thirteen concrete questions (all code in the company repo, no ex-contractor/ex-engineer access anywhere, CEO has admin on everything and everything is in the company's name, no secrets in repo history, no shared logins, prod access by named person, domains company-owned, billing in the company's name, app-store/registry accounts company-owned, a company password manager, prod secrets in a store and rotated after departures, SPF/DKIM/DMARC working with no external forwards, 2FA on every identity) by inventorying every system the company uses — GitHub, AWS/GCP, PaaS, DBaaS, Slack, Google Workspace, 1Password, registrar, app stores — through API/CLI/MCP access where the user can grant it and screenshots where they cannot, then delivers a people × systems access matrix, an ownership table, and a scorecard with exact fixes. Use whenever the user asks about operational security, opsec, access review, offboarding, "who has access to what", "does anyone who left still have access", "is everything in the company's name", "do I control all our accounts", contractor cleanup, key-person risk, leaked or shared credentials, or is preparing for due diligence / an acquisition / a co-founder or contractor departure — even if they don't say "audit". For AWS reliability/security configuration (CloudTrail, backups, ports) use infra-audit; for cost use infra-cost-review. Overlap on 2FA is intentional.
---

# Sec-Ops (operational security audit)

`infra-audit` asks whether the infrastructure is built right. This skill asks the questions a
founder is asked the week a contractor leaves badly, a laptop is stolen, or an acquirer's
lawyer opens the data room: **who can get in, who owns what, and where does the code and the
secret material actually live?** Thirteen questions, each with a recommended answer. The
deliverable is a scorecard, a **people × systems access matrix**, and an **ownership table**
a founder can act on in a day.

| # | Question | Recommended |
|---|---|---|
| 1 | Is **all** company code in the company's code host (GitHub org), and does everything that runs — every hostname, every backend the frontend calls, every scheduled job and data pipeline, every deployed function and container, every dependency the company effectively owns — trace back to that repo? | Yes — strongly; this is the heaviest question |
| 2 | Do ex-contractors or ex-engineers have **any** ongoing access — SaaS, hosting, DB, SSH, the product's admin panel, Slack? | No — strongly |
| 3 | Does the CEO / main point of contact have owner/admin on **every** resource, is every resource in the **company's** name, and does the company own **every server and piece of infra** the product runs on (no backend on an engineer's personal server, personal cloud account, or home box)? | Yes — strongly |
| 4 | Are there secrets in the repo history (any branch, any time)? | No |
| 5 | Are there shared accounts or shared credentials (one login used by several people, a `.pem` passed around, `admin@` logins)? | No |
| 6 | Who can reach production servers and databases, and is it by named individual (SSM, own key) rather than a shared key or open port? | Named individuals only |
| 7 | Domains: registered to the company, in a company-owned registrar account, auto-renew on, transfer lock on, DNS account company-owned? | Yes |
| 8 | Is every account billed to the company (company card/entity, invoices to a company address)? | Yes |
| 9 | App-store / publisher / package-registry accounts (Apple Developer, Google Play, npm, Docker Hub, PyPI, Chrome Web Store) owned by the company, not an individual? | Yes |
| 10 | Company password manager for all shared credentials; nothing living in Slack, Notion, email, or Docs? | Yes |
| 11 | Production secrets in a secret store, access limited, consumers known, **rotated after each departure**? | Yes |
| 12 | Email domain: SPF, DKIM, DMARC set up and actually working; no auto-forwards to external addresses? | Yes |
| 13 | 2FA on every identity found in the matrix, and required where the vendor can require it? | Yes |

`references/secops-checklist.md` has, for each: how to detect it, why it matters, what good
looks like, and the fix. `references/access-guide.md` says, per system, what access to ask for
and what to do when only screenshots are possible.

**Who this is for.** A 2–10 person startup: personal laptops, no identity provider, no MDM, a
Google Workspace and a handful of SaaS logins, the first engineer long gone. Do not recommend
enterprise controls (SSO, device management, SIEM, formal access reviews). Recommend the
cheapest thing that works: one owner account per system in the company's name, a password
manager, 2FA, named logins, and a list.

**Read-only, always.** This skill removes nobody and rotates nothing. Every change is a
recommendation in the report; the user runs the removals (or names them one at a time after
reading the report). Removing access and rotating secrets are the two things that break
production when done in the wrong order, so the report gives the order.

## Why this skill exists

Nobody at a startup knows who has access to what. The answer is spread over fifteen admin
consoles, a registrar account on a founder's personal Gmail, an Apple Developer account held
by the first iOS contractor, a `deploy.pem` that has been in four people's Downloads folders,
and a Retool app that is the real back office. Each console is a two-minute look; the finding
is only visible when they are all in one table with a column for "still works here?". This
skill makes you collect every system, key every identity to a person, and answer every
question with Yes/No/Partial/Unknown so nothing is skipped quietly.

## Access: what to ask for, in order of preference

This audit needs wide-ranging access. Ask for it once, up front, with the whole list, rather
than one system at a time.

1. **API / CLI / MCP** (preferred): a read-only token or an already-authenticated CLI per
   system — `gh` with org-admin read, an AWS profile, `vercel`/`fly`/`heroku` logged in,
   `op` signed in, a Slack admin token, `gam` for Workspace, an Atlas API key, a Cloudflare
   token with member read. The collectors in `scripts/` detect what is configured and skip the
   rest. An MCP server connected to a system counts as API access; use it and record it.
2. **Screenshots** (much less preferred, but real evidence): for systems with no API for team
   membership (Stripe team, Apple Developer "Users and Access", Google Play, most registrars,
   Railway, Clerk), ask for the exact page named in `references/access-guide.md`, transcribe it
   into a `members-<system>.json` with `"source": "screenshot"`, and say so in the report.
   Screenshots go stale the moment they are taken and cannot be re-run; say that too.
3. **User's word**: "I'm the only admin on Twilio" is recorded as "reported by user", never as
   verified.

## Workflow

Run in order. Load a reference only when you reach the step that needs it.

### 1. Scope: the roster and the system list

- Ask for **the roster**: everyone who has ever had access — founders, employees, contractors,
  agencies, advisors — with email, name, `current`/`former`, GitHub login, and any other
  identities (personal email, Slack handle). Write `roster.csv` (columns in
  `references/access-guide.md` §Roster). Without a roster Q2 can only list identities; with it
  the matrix flags the former ones automatically.
- Ask **who the main point of contact is** (`--ceo <email>`) and the **company email domain**
  (`--domain`). Personal-domain identities are flagged against it.
- Ask for **every system with a login**: cloud, PaaS, DBaaS, code host, CI, registrar, DNS,
  email/Workspace, Slack, password manager, error/log/analytics vendors, payments, email
  sending, app stores, package registries, design/docs/ticketing tools that hold company data.
  The user's list is a starting point; the repo (`.env.example`, deploy configs, `package.json`),
  DNS (`dig`, `whois`) and AWS (Secrets Manager names, IAM role trust policies, SES/SNS
  destinations) will add systems they forgot. Every system found later gets appended.

### 2. Code host and repos (Q1, Q4, Q5 — and half of Q2)

```bash
scripts/github-access-inventory.sh --org <org> [--out <dir>]
```

Read-only via `gh api`. Members with role, outside collaborators, 2FA-disabled members, per-repo
outside collaborators and deploy keys, installed GitHub Apps, org secrets (names), fine-grained
PATs with org access, branch protection on the default branch, secret-scanning/push-protection
state, forks of private repos, `billing_email`, and the audit log if the plan has one. Writes
`members-github.json` and `ownership-github.json`.

Then, in a checkout of each repo (or the monorepo):

```bash
scripts/repo-scan.sh --out <dir> [--since 2022-01-01]
```

Runs `gitleaks`/`trufflehog` over the full history when installed (grep fallback otherwise,
values masked), lists committers by email domain with last commit date (the personal-Gmail
committer from 2023 is a Q2 lead), git dependencies fetched from personal repos, `.env`-shaped
files that are tracked, submodule remotes, CI secrets that are really one person's token,
credential-shaped lines in docs, and every deploy target the repo names. Then §2b and §2c.

### 2b. Reconcile the live product against the repo (Q1 — the heavy part)

Q1 is not "is there a GitHub org". You read the code, find what it deploys and where, look at
what is actually live, and account for every piece. A repo with a backend and no frontend
while `app.company.com` serves a React bundle means the frontend lives somewhere else — a
contractor's laptop, a Webflow account, a personal repo — and that is a Critical finding. The
same for a nightly data pipeline that exists as a Glue job but has no source anywhere.

1. **Ingest the repo(s).** Read every `package.json`, `requirements.txt`, `Dockerfile`, deploy
   config, CI workflow and IaC file. Know what components exist (frontend / backend / mobile /
   workers / pipelines / infra) and what each deploys to. `live-vs-repo.sh` does the
   mechanical inventory; you do the reading.
2. **Find every hostname.** From the repo (env examples, CORS lists, `NEXT_PUBLIC_API_URL`),
   DNS (`domain-inventory.sh --host` on every subdomain the user knows plus the common ones:
   `www`, `app`, `api`, `admin`, `dashboard`, `docs`, `staging`, `status`), CloudFront aliases,
   Vercel/Render/Fly/Amplify custom domains, and the mobile app's API base URL.
3. **Run the reconciliation:**

```bash
scripts/live-vs-repo.sh --host app.company.com --host api.company.com --host www.company.com \
  --repo ../app --repo ../infra --aws-profile <p> --out <dir>
```

   For each live host it fetches the page and up to six first-party JS bundles (read, never
   executed), fingerprints the framework and host, and pulls out API hostnames, `/api/...`
   paths, `NEXT_PUBLIC_*`/`VITE_*` variable names and client-side SDKs — then `git grep`s each
   of those in the repos. For the AWS account it lists every place code runs (Lambda, ECS,
   EventBridge schedules, Glue, Step Functions, Batch, App Runner, Amplify, Beanstalk,
   CloudFront + S3 sites, MWAA, SageMaker pipelines, DMS, Firehose, AppFlow, CodeBuild) and
   greps each unit's name / handler / image / script name in the repos. `CODE-RECONCILIATION.md`
   gives a verdict per host and per unit: MATCH, WEAK, **NO MATCH**, SITE-BUILDER, and three
   structural gap checks (backend with no frontend; frontend calling an API with no backend;
   scheduled compute with no pipeline code). It also resolves every live host **and every API
   host the bundles call** to an IP owner and provider and checks that provider against the
   accounts in the ownership inventory (Q3): UNACCOUNTED PROVIDER, PERSONAL/HOME SERVER?, or
   TUNNEL/DYNAMIC-DNS means part of the product runs on infrastructure the company does not own;
   THIRD-PARTY SERVICE (a vendor API on another domain) is a system to add to the list, not infra.
   Run it again once `saas-access-inventory.sh` has written the `ownership-*.json` files — the
   provider check reads them. Vercel/Render/Fly/Heroku services whose linked
   repo is not in the org, or that have **no** git link (deployed from a laptop with the CLI),
   come from `saas-access-inventory.sh` and count as NO MATCH.
4. **Read the NO MATCH and WEAK rows yourself.** Open the bundle files in `<dir>/bundles/`,
   compare route names and component names against the repo, check the Lambda's
   `LastModified` against the last CI run, look at the EC2 sweep's `git-repos-on-disk` for
   boxes. Decide per item: in the repo (say where), in another repo the user can name, in a
   SaaS tool, or **not in the company's possession**. For anything in the last bucket say what
   it is, what would break without it, and how to recover the source (download the Lambda
   zip, pull the image, export from the SaaS tool, ask the person who has it — before they are
   unreachable).

### 2c. Dependency provenance (Q1e)

```bash
scripts/dependency-provenance.sh --repo ../app --roster roster.csv --gh-org <org> --out <dir> [--all]
```

For every npm and PyPI dependency: weekly downloads, maintainers, repository owner, last
publish, deprecated. The finding the user cares about most: a **low-volume package maintained
by a current or former employee** — effectively company code that lives in one person's npm
account, outside the repo, with nobody else watching it. When that person leaves or their
account is phished, production installs whatever comes next. `deps-provenance.md` ranks HIGH
(low-volume + roster maintainer), MEDIUM (roster maintainer at any volume; low-volume +
personal/single-maintainer/no repo; private packages that 404 on the public registry — where
is their source?), LOW (stale, deprecated, personal repo). Recommend vendoring into the
monorepo or moving the package under the company's npm org and GitHub org with publish 2FA
and two maintainers.

### 2d. When you cannot find something: ask, then flag

You will not find everything. A NO MATCH host, a pipeline with no source, an API host on a
provider nobody listed, a deploy target that is a bare IP, a package whose repo is gone — do
not guess and do not silently mark it Unknown. Ask the user directly, in plain words, naming
the thing:

> I was not able to find all of the infra or code. Do you know where **X** is?
> (X = "the code that serves app.company.com", "the source for the nightly Glue job
> `events-rollup`", "the server at 65.108.x.x that `api.company.com` points to",
> "the repo for `@dan-utils/validators`".)

Then act on the answer:

- **They name a place** (another repo, a contractor's account, a SaaS tool, a person): record
  it as "reported by user", go look if you can (ask for access), and if it is outside the
  company's control it is still a finding — now with a known location and a recovery path.
- **They don't know**: that *is* the finding. Write it up under Q1 or Q3 as Critical with what
  it is, what depends on it, and the first step to recover it (download the Lambda zip, pull
  the image, ask the last person who touched it — before they are unreachable).
- **They ask why it matters**: explain, briefly and concretely, in terms of this thing. The
  company cannot fix, redeploy, patch, back up, or shut down code or servers it does not hold;
  when the person who has it leaves, or their laptop dies, or their account is suspended for
  non-payment, that part of the product is gone and has to be rewritten from the running
  artifact; an acquirer or investor will ask for exactly this and a gap here reads as "the
  company does not own its product"; and anything you cannot see, you also cannot audit for
  the other twelve questions.

Ask once, with the whole list of missing things, not one question per item. Never turn an
unanswered question into a Yes.

### 3. Cloud accounts and every other system (Q2, Q3, Q5, Q6, Q8, Q11, Q13)

```bash
scripts/saas-access-inventory.sh --out <dir> [--aws-profile <p>] [--domain company.com]
```

One collector per system, each guarded by "is the CLI logged in / is the token in the env":
AWS (IAM users + credential report, Identity Center users, root contact and alternate
contacts, organization owner, key pairs, roles trusting external accounts, Secrets Manager
names + last rotation), GCP, Vercel, Fly, Heroku, Render, Cloudflare, MongoDB Atlas (org/project
users, API keys, database users, IP access list), Supabase, Slack (users, guests, deactivated,
2FA, integration log), 1Password (users, groups, vaults), Google Workspace via `gam` or an
admin token (users, admins, forwards), Sentry, Datadog, PagerDuty, Linear, Notion, SendGrid,
Tailscale (users and devices), npm org, Stripe account identity. Each writes a normalized
`members-<system>.json` / `ownership-<system>.json`. At the end it prints the systems it could
not reach and the screenshot each needs. Run it again after the user adds a token; it only
overwrites the systems it could reach.

For systems that are screenshot-only, transcribe into the same JSON shape by hand (§Access
guide) — never skip a system because it has no API; those are where the stale access lives.

### 4. Servers (Q1, Q2, Q6, Q11)

Request SSH/SSM access to every running instance, once, the same way infra-audit does:

```bash
scripts/ec2-ssh-sweep.sh discover --profile <p> --region <r> --out <dir>
# fill in hosts.tsv, then
scripts/ec2-ssh-sweep.sh run --profile <p> --region <r> --hosts <dir>/hosts.tsv \
  --script scripts/on-box-secops.sh --out <dir> --sudo
```

`on-box-secops.sh` is a people-and-code collector, not a hardening one: every
`authorized_keys` entry as fingerprint + comment (the comment is usually `name@laptop` — tie
it to the roster), last logins and source IPs, sudoers, `.aws/credentials` **key IDs** (not
secrets — the ID maps to an IAM user), git repos on disk with remote, branch, uncommitted and
unpushed change counts, app directories with no `.git` (code that exists only on this box),
crontab/systemd scripts outside any repo, running container images and their registry
namespaces, and the process manager's working directories. Never writes; the sweep runner
refuses any collector containing a write. Non-AWS boxes (Hetzner, DigitalOcean, a Mac mini):
add them to `hosts.tsv` by hand with `method=ssh`.

### 5. Domains, DNS, and email (Q3, Q7, Q12)

```bash
scripts/domain-inventory.sh --domain company.com [--domain other.com] [--host api.company.com ...] --out <dir>
```

`whois` (registrant org, registrar, expiry, `clientTransferProhibited`), NS/MX, SPF, DMARC
policy, DKIM selectors for the common senders, and for each app hostname who actually hosts it
(CNAME target / IP `whois` org) — which is also how you find the provider the user forgot to
list. Registrar-account ownership itself is a screenshot (account email, 2FA, auto-renew).
Whether email *works* (DKIM aligned, DMARC passing) is best confirmed by sending one message
to a checker such as a Gmail "show original" or an mail-tester address — ask the user to do it.

### 6. Build the matrix and the digest

```bash
scripts/secops-digest.py --dir <dir> --roster roster.csv --ceo ceo@company.com --domain company.com
```

Reads every `members-*.json` and `ownership-*.json` (API-collected and hand-transcribed alike)
and writes `ACCESS-MATRIX.md` (people × systems with role per cell) and `DIGEST.md` with the
automatic findings: **former** people with any access, identities **not in the roster**
(unknown — ask), **personal-domain** identities, systems where the **CEO is not owner/admin**,
owners/admins per system, the Q1 reconciliation and dependency-provenance summaries, identities with MFA off, guests/outside collaborators, bots and
service accounts, primary account emails not on the company domain, and the systems still
missing evidence. Read the digest first; every claim in the report should point at a JSON
file, a sweep section, or a named screenshot.

### 7. Answer the thirteen questions

Work through `references/secops-checklist.md`. For each: Yes / No / Partial / Unknown, the
evidence with its source, why it matters for this company, the recommended state, and the exact
step — in the order that does not break production (rotate *after* the new consumer is wired
up; remove a person's access *after* their tokens are replaced, not before). Q2 with any former
person still holding access is the lead finding regardless of anything else. Q1 with a live
host, a pipeline, or a deployed unit that no repo accounts for — or a component (the whole
frontend, the whole backend) missing from the repo — is second, and gets its own sub-scorecard
(1a–1f) in the report. Q3 with a resource in someone else's name is third.

### 8. Write the report

Use `references/report-template.md`: summary → scorecard (all 13 rows, always) → the access
matrix → the ownership table → one section per question → the removal-and-rotation runbook for
this company (from `references/offboarding-runbook.md`, filled in with the actual systems —
this is the Q2 fix, written down so the next departure is a checklist) → "today / this week /
decisions" → method and caveats. Lead with the worst thing. A "Yes, verified" is one line. A
"No" without the exact removal/transfer step is not finished.

## Gating: what may run

```
recommend  ← default for everything; this skill's collectors only read
   ↓ user reads the report and names a specific finding
remove one person's access from one system, invite the CEO as owner, turn on a setting
  (2FA requirement, push protection, DMARC record)             ──→ may run, then re-verify
   ↓ otherwise
rotate a secret, transfer an account/domain/repo, delete a user with owned resources
  ──→ ask again, explicitly, naming what breaks (the CI job using that PAT; the Lambda reading
      that key; the repos owned by that GitHub user; the apps under that Apple account). Never batch.
```

Deleting a GitHub user who owns repos, an Atlas user who owns a project, or a Slack user who
installed apps takes their resources with them: **transfer first, then remove.** Say this in the
report next to every such person.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "The contractor isn't in the GitHub org, so they're offboarded." | GitHub is one of fifteen systems. Check the matrix column by column: Vercel, Atlas, Slack guest, the product admin panel, `authorized_keys`, the Apple team. |
| "Their account is deactivated in Slack, that's done." | Deactivated users' tokens for installed apps may keep working; a personal PAT in CI still works after the person is gone. Check tokens, not just logins. |
| "The code is on GitHub." | Is *all* of it? Compare what is live to what is in the repo, host by host and unit by unit. The cron script on the box, the Lambda edited in the console, the Retool/Zapier logic, the repo still under the first engineer's personal account, the npm package under their namespace. |
| "The repo has a backend, looks complete." | What serves `app.company.com`? If the repo has no frontend component and the live site is a React bundle, the frontend is somewhere the company does not control. Same for the nightly pipeline. |
| "It's just a small npm package we use." | Who maintains it and who else uses it? A 200-downloads-a-week package maintained by a former engineer is company code outside the repo, with a publish button the company does not hold. |
| "The CEO can log in to AWS." | As what? An IAM user with ReadOnly is not owner. Root email on the CEO's personal Gmail is not "in the company's name". |
| "Everything's on AWS." | Is it? `api.company.com` resolves to a Hetzner IP and there is no Hetzner account on the list. The worker the frontend talks to is on an engineer's VPS. Resolve every host the bundles call, not just the ones the user named. |
| "The domain shows the company in whois." | Whois privacy shows the registrar's proxy for everyone. The question is whose *registrar account* holds it and whose email recovers it. |
| "We use 1Password." | Are the AWS root recovery codes in it? Is the CEO in the vault that holds them? |
| "No API for Stripe's team page, skip it." | Ask for the screenshot. Systems without APIs are exactly where stale access survives. |
| "They should have SSO / MDM / an access-review process." | Not at this size. Recommend a password manager, 2FA, named logins, one company-owned owner account per system, and a list. |
| "I can't find where this runs, I'll mark it Unknown and move on." | Ask: "I was not able to find all of the infra or code — do you know where X is?" If they don't know, that is the finding. If they ask why it matters, tell them (§2d). |
| "I'll remove the stale user now, it's obviously safe." | Not yours to do, and their PAT is in a GitHub Action. Recommend, name the consumers, let the user choose the order. |
| "They said they rotated everything when X left." | "Reported by user." Secrets Manager `LastRotatedDate` and key ages say when things actually changed. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or where
CLAUDE.md says such analyses live), with `ACCESS-MATRIX.md` next to it, plus a chat summary
that leads with the worst finding and the count of former people still holding access. Record
durable facts (org names, account ids, the system list, which systems are screenshot-only,
the roster file location) in the project's CLAUDE.md so the next audit is a re-run, not a
rediscovery. The matrix is the artifact to re-run after every departure.

## Reference files

- `references/secops-checklist.md` — the thirteen questions: detection, why, what good looks like, the fix. Read during §7.
- `references/access-guide.md` — per system: preferred access (API/CLI/MCP), the exact read-only scope to ask for, the screenshot fallback page, and the normalized JSON shape for hand transcription; the roster format. Read during §1–§3.
- `references/report-template.md` — scorecard report skeleton and per-question contract. Read during §8.
- `references/offboarding-runbook.md` — the removal-and-rotation checklist template you fill in with this company's systems (the Q2 and Q11 fix).
- `scripts/github-access-inventory.sh` — GitHub org read-only inventory → `members-github.json`, `ownership-github.json`, per-repo JSON; §2.
- `scripts/repo-scan.sh` — history secret scan, committer identities, personal-repo deps, CI tokens, deploy targets; §2.
- `scripts/live-vs-repo.sh` — live hosts (fingerprint, bundles → API hosts/paths/env names) + AWS deployed units (Lambda, ECS, schedules, Glue, Step Functions, …) + repo components → `CODE-RECONCILIATION.md` with MATCH / NO MATCH per host and unit and the structural-gap checks; §2b.
- `scripts/dependency-provenance.sh` — npm/PyPI downloads, maintainers, repo owner vs roster → `deps-provenance.md`, HIGH = low-volume + employee-maintained; §2c.
- `scripts/saas-access-inventory.sh` — every other system with a CLI/API, guarded by what is configured; prints the screenshot list for the rest; §3.
- `scripts/ec2-ssh-sweep.sh` — identical to the infra-audit/infra-cost-review copy; `discover` then `run`; §4.
- `scripts/on-box-secops.sh` — the read-only people-and-code collector; §4.
- `scripts/domain-inventory.sh` — whois, DNS, SPF/DKIM/DMARC, who hosts each hostname; §5.
- `scripts/secops-digest.py` — merges all `members-*.json` / `ownership-*.json` into `ACCESS-MATRIX.md` + `DIGEST.md`; §6.
