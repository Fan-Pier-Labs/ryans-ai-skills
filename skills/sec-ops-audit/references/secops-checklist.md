# Sec-ops checklist — the thirteen questions, how to answer each, and what "good" looks like

Answer every question with **Yes / No / Partial / Unknown**, the evidence, and the recommended
state. "Unknown, could not verify" is honest and better than a guess; say which access or
screenshot would have resolved it.

Sources, by trust: API/CLI/MCP output in `<dir>/*.json` → the SSH sweep (`box-*.txt`) → the
repo (`repo-scan/`) → DNS/whois (`domain-*.json`) → a screenshot transcribed to JSON (dated;
label it) → what the user tells you ("reported by user").

Everything below keys on two artifacts: `ACCESS-MATRIX.md` (people × systems) and the
ownership table in `DIGEST.md` (system → account identity, primary email, owner). Build them
before answering anything.

The audience is a 2–10 person startup on personal laptops with no identity provider. The fix
for every question is the cheapest thing that works, never an enterprise control.

Contents: A. Code (Q1, Q4) · B. People and access (Q2, Q5, Q6, Q13) · C. Ownership (Q3, Q7,
Q8, Q9) · D. Secrets and email (Q10, Q11, Q12)

---

## A. Code

### Q1. Is all company code in the company code host, and does everything that runs trace back to it? (recommended: yes — strongly; the heaviest question)

This is the question you spend the most time on. "All" is checked six ways, and each gets a
row in the Q1 sub-scorecard in the report. The mechanical inventory is `live-vs-repo.sh` +
`dependency-provenance.sh` + `repo-scan.sh` + the SSH sweep; the judgment — reading the code,
looking at the live product, deciding what is missing — is yours.

**1a. Every repo is org-owned.** `github-access-inventory.sh` lists the org's repos. Cross-check
against what runs: every deploy target the repo-scan found, every Vercel/Render/Fly/Heroku
service's linked repo (`vercel-projects.json`, `render-services.json` — a service with **no**
git link was deployed from someone's laptop with the CLI: the code is wherever that laptop
is), every Amplify/App Runner/CodeBuild source (`aws-deployed-units.json`). A service deploying
from `github.com/<person>/…` is the classic miss — the first engineer's personal repo, still
the source of truth. `github-forks.json` shows private code sitting in personal accounts.

**1b. Every live host is accounted for.** Enumerate hostnames (repo env/CORS/`NEXT_PUBLIC_*`,
DNS `--host` sweep of `www app api admin dashboard docs staging status` + whatever the user
names, CloudFront aliases, PaaS custom domains, the mobile app's API base). For each,
`CODE-RECONCILIATION.md` says MATCH / WEAK / NO MATCH / SITE-BUILDER with evidence: framework
fingerprint vs repo components, API hostnames and `/api` paths pulled from the live JS bundles
and `git grep`'d in the repo, `NEXT_PUBLIC_*`/`VITE_*` names present in both. Read the bundles
in `<dir>/bundles/` yourself for NO MATCH and WEAK rows — route names, component names, copy
strings are all greppable. **The structural check matters most:** the repo has a backend and
the live site is a React app → no frontend in the repo; the repo has a frontend that calls
`api.company.com` and there is no backend component → no backend in the repo. Either is
Critical: a whole tier of the product is somewhere the company does not control. SITE-BUILDER
(Webflow/Squarespace/Framer) is not a code finding but the account becomes a system for Q2/Q3.

**1c. Every scheduled job and data pipeline has source.** `aws-deployed-units.json`: every
EventBridge rule/schedule and its target, Glue job and its `ScriptLocation`, Step Function,
Batch job definition, MWAA environment, SageMaker pipeline, DMS task, Firehose, AppFlow — each
must map to a DAG, a script, a job definition, or IaC in a repo (`repo-components-*.json →
pipeline_files`, `schedules`). A Glue script that exists only in S3, an Airflow DAG that exists
only on the MWAA bucket, a cron on the EC2 box (SSH sweep `crontab scripts`) pointing at
`/home/ubuntu/nightly.py` with no repo — all NO MATCH. Pipelines are where this fails most
often because nobody considers them "the product". Also: Zapier/Make/n8n flows, Retool/Appsmith
apps, Google Apps Scripts, Airtable automations, Stripe webhook logic in a dashboard — ask,
list them as systems, and recommend an exported copy committed to the repo.

**1d. Production is the committed code.** Every Lambda: `LastModified` after the last CI deploy
means a console edit; download the zip (`aws lambda get-function` → `Code.Location`, read-only)
and diff against the repo build if in doubt. Every ECS image: tag/digest traceable to a CI run.
SSH sweep `git-repos-on-disk`: `uncommitted > 0` or `unpushed > 0` is code that exists only on
that box; `app-dirs-without-git` is code with no known source; `running-code` shows whether the
serving process's working directory is even inside a repo.

**1e. Dependencies the company effectively owns are in the company's hands.**
`deps-provenance.md`, from `dependency-provenance.sh --roster roster.csv --gh-org <org>`:

| Flag | Meaning | Severity |
|---|---|---|
| LOW-VOLUME + EMPLOYEE-MAINTAINED | A package with < 1,000 weekly downloads whose npm/PyPI maintainer or GitHub repo owner is someone on the roster (current or former). The company is its only real user; it is company code living in one person's registry account, outside the repo, with a publish button the company does not hold. The user's named case. | **HIGH** |
| EMPLOYEE-MAINTAINED (any volume) | Same control problem, mitigated by other users noticing a bad publish. | MEDIUM |
| NOT-ON-PUBLIC-REGISTRY | 404 on the public registry: a private or unpublished package. Where is its source, and who can publish it? | MEDIUM |
| LOW-VOLUME + PERSONAL-REPO / SINGLE-MAINTAINER / NO-REPO | Obscure package controlled by one stranger. | MEDIUM |
| PERSONAL-REPO, SINGLE-MAINTAINER, STALE (> 2 y), DEPRECATED | Hygiene; list, do not dwell. | LOW |

Also `repo-scan/personal-deps.txt`: git dependencies fetched straight from personal repos, and
Docker base images from `docker.io/<person>/…` (SSH sweep `containers`). Fix for HIGH/MEDIUM:
vendor the package into the monorepo (usually an afternoon), or transfer it to the company's
npm org and GitHub org with 2FA-required publishing and two maintainers; pin exact versions
and a lockfile meanwhile.

**1f. Mobile and desktop builds.** If there is an App Store / Play Store app, its source must
be a component in the repo (`kind: mobile`) and its API base URL must resolve to a host in 1b.
A shipped app whose source is not in the repo is the frontend case again.

**When a sub-check comes up short**, do not guess: ask the user "I was not able to find all of
the infra or code — do you know where X is?" naming each missing thing (SKILL.md §2d). A known
location outside the company is a finding with a recovery path; "I don't know" is the finding
itself; "why does it matter?" gets the concrete answer — the company cannot fix, redeploy, or
recover what it does not hold, and it disappears with the person who has it.

Fix for 1a–1d: transfer repos to the org (`gh repo transfer` keeps history and redirects),
link every PaaS service to an org repo, commit the on-box scripts and Glue/DAG files, and for
each NO MATCH decide: recover the source (download the Lambda zip / pull the image / export
from the SaaS tool / ask the person who has it — *before* they are unreachable) or rewrite.
Q1 No with a whole component or a production pipeline outside the repo is the second-worst
finding in the audit, behind only a former person with live access.

### Q4. Are there secrets in the repo history? (recommended: no)

`repo-scan/gitleaks.json` / `trufflehog.json` (full history, all branches) or the grep
fallback (`repo-scan/history-grep.txt`, values masked). A secret that was committed and then
removed is still in every clone that ever existed and in GitHub's cache of the commit; the fix
is **rotation**, not history rewriting (rewrite too if the repo is small, but rotate first).
Also check: tracked `.env` files (`repo-scan/tracked-env.txt`), and secret scanning + push
protection on for every repo (`repo-<name>.json → security_and_analysis`) — free for public
repos; where unavailable, a `gitleaks` pre-commit hook. Count findings by type, name the file
and commit, never print the value.

---

## B. People and access

### Q2. Do ex-contractors or ex-engineers have ongoing access anywhere? (recommended: no — strongly)

The lead finding whenever it is Yes. It is answered by the matrix, not by any one system:
every row whose roster status is `former` and has any non-empty cell. Then the identities the
matrix could not key to the roster (`unknown` section of `DIGEST.md`) — ask about each one;
"not sure who that is" is a former person until proven otherwise.

Systems people forget, in rough order of how often stale access survives there:

| Where | Why it survives | Evidence |
|---|---|---|
| Servers' `authorized_keys` | Nobody removes keys; the box outlives the person | SSH sweep `ssh-keys`: fingerprint + comment (`name@laptop`) per user |
| The product's own admin panel | Not a "system" anyone lists | Ask for the admin-users table or query it read-only |
| DBaaS (Atlas, Supabase), DB users | Shared `admin` DB user; personal Atlas invite | `members-atlas.json`, `atlas-dbusers.json`, `atlas-accesslist.json` (their home IP still allowed) |
| App stores (Apple, Google Play) | Contractor created the account (Q9) | Screenshot: Users and Access; Account Holder |
| Registrar / DNS | Set up on day one by whoever was there (Q7) | `domain-*.json` + registrar screenshot |
| PaaS teams (Vercel, Render, Fly, Heroku, Railway) | Invited by email, never removed | `members-vercel.json` … |
| Slack guests, shared channels, deactivated users' apps | Deactivation does not revoke app tokens they installed | `members-slack.json`, `slack-integration-log.json` |
| GitHub outside collaborators (per repo), deploy keys, PATs | Outside collaborators are invisible from the org People page | `github-outside-collaborators.json`, `repo-*-deploy-keys`, `github-pats.json` |
| Cloud IAM users, access keys, Identity Center | Key in a laptop's `~/.aws/credentials` still valid | `members-aws.json` (`last_active` from credential report), SSH sweep `aws-credentials-on-disk` key IDs |
| CI secrets that *are* a person's token | Their GitHub PAT / npm token / AWS key is the deploy credential | `repo-scan/ci-secret-exposure.txt`, org/repo secret names |
| Password manager | Vault sharing to a personal account | `members-1password.json` |
| Email/Workspace | Account suspended but mail forwarded; delegation | `members-google.json`, forwards |
| Observability / payments / support tools | Sentry, Datadog, Stripe, Intercom, HubSpot — customer data lives in these | per-system JSON or screenshot |
| VPN / Tailscale | Device still enrolled | `tailscale-devices.json` |

Fix, in this order per person: (1) list every cell in their row, (2) for each token or key
they created that something else depends on, provision the replacement (a token owned by the
company or a machine user) and switch consumers, (3) transfer any resources they own (GitHub
repos, Atlas projects, Slack apps, Apple apps, domains), (4) remove them from every system,
(5) rotate every secret they could have seen (Q11), (6) remove their device from the VPN if
there is one. Write it down as `references/offboarding-runbook.md` filled in for this company,
so the next departure is a checklist, not an audit.

### Q5. Shared accounts or shared credentials? (recommended: no)

Detect: identities in the matrix that are not a person — `admin@`, `dev@`, `ops@`,
`hello@` used as a login; one AWS IAM user with several access keys or a `PasswordLastUsed`
that never stops; one SSH key comment on many boxes for many people; one `.pem` referenced
in the repo's docs (`repo-scan/docs-credentials.txt`: "use deploy.pem in the shared drive");
Atlas/RDS database users named `admin`/`app` that humans connect with; the product admin
panel's `superadmin` login in the wiki; a Slack bot token in a shared doc. Why it matters: no
attribution (audit logs say "admin"), no per-person revocation (removing one person means
rotating for everyone), and the shared secret spreads to laptops and chat. Fix: named accounts
everywhere the vendor allows; where a shared login is unavoidable (a registrar with one seat,
an app-store account holder) keep it **only** in the password manager with the TOTP seed in
the same item, and list who can see the item.

### Q6. Production access by named individual? (recommended: named individuals only)

Who can SSH/SSM to prod boxes and who can read the prod database, and how. Evidence: SSH sweep
`ssh-keys` (one key per person with a comment that names them; no key that several people
hold), `logins` (usernames and source IPs — a shared `ubuntu` user with six source IPs is six
people on one identity), `sudoers`; AWS: `aws-keypairs.json` (names like `ryan-macbook` for
people who left), whether SSM is used instead of a key pair; Atlas/RDS: `atlas-dbusers.json`
and the IP access list (home IPs of former people). Infra-audit covers the open port and the
bastion; here the question is *attribution*. Fix at this size: SSM Session Manager (free, per
IAM identity) or one `authorized_keys` entry per current person with their name in the
comment; DB access through the app or a named DB user per person; delete key pairs named after
people who left.

### Q13. 2FA on every identity, required where possible (recommended: yes — overlaps infra-audit Q7 on purpose)

Per-user MFA state where the API exposes it: GitHub (`2fa_disabled` filter), AWS credential
report (`mfa_active`, root included), Slack (`has_2fa`), Google Workspace (`isEnrolledIn2Sv`),
Cloudflare, Supabase, Sentry, Heroku. `DIGEST.md → MFA off` lists them. Then whether the org
*requires* it: GitHub `two_factor_requirement_enabled`, Workspace 2SV enforcement, Slack
workspace setting, AWS via infra-audit's deny-without-MFA check. For systems with no API
(registrar, Apple, Stripe, Atlas org setting), ask or screenshot. The registrar, the email
provider, and the password manager are the three that matter most: each one recovers the
others. Fix: turn on the requirement where the vendor has one; for the rest, list the specific
identities with it off and ask the user to enrol them this week.

---

## C. Ownership

### Q3. CEO / main point of contact has owner/admin on everything; everything — every account, every server — in the company's name? (recommended: yes — strongly)

Three checks over the ownership table and the reconciliation:

1. **Owner/admin column for `--ceo`** in every system. Not "can log in": owner on GitHub,
   root-email holder on AWS, Owner on Vercel/Render/Fly, Org Owner on Atlas, Primary Owner on
   Slack, Super Admin on Workspace, Owner on 1Password, registrar account on the domain, account
   owner on Stripe, an Admin (at minimum) on the Apple and Google Play accounts. `DIGEST.md →
   ceo-missing` lists the systems where they are not.
2. **Primary identity of each account is the company's.** The AWS root email
   (`aws-account-contact.json`, or ask) is `aws-root@company.com` (an alias the CEO controls),
   not `founder@gmail.com` and not a former employee. GitHub org `billing_email`. Vercel team /
   Render workspace / Fly org name and owner. Apple Developer legal entity (Q9). Registrar
   account email and whois registrant organization (when privacy is off) or the registrar-
   account owner (when on). Stripe `business_profile.name`, account email. Slack primary owner.
   Cloudflare Super Administrator. `DIGEST.md → ownership` flags primary emails not on
   `--domain`.

3. **Every server and every piece of infrastructure is in a company-owned account.** No part of
   the backend, a worker, a database, a cron, or a "temporary" proxy may run on an engineer's
   personal server, personal cloud account, home machine, or a VPS nobody can name the bill for.
   Detect: `CODE-RECONCILIATION.md → Where each host physically runs` resolves every live host
   *and every API host the frontend bundles call* to an IP, the IP's owner, and a provider, then
   checks that provider against the accounts in the ownership inventory — verdicts
   **UNACCOUNTED PROVIDER** (the host runs on Hetzner / DigitalOcean / OVH / a cloud account and no
   such account is in the system list: whose account?), **PERSONAL/HOME SERVER?** (residential
   ISP address), **TUNNEL/DYNAMIC-DNS** (ngrok, Cloudflare tunnel, DuckDNS — a laptop or a home
   box). Then `repo-scan/infra-targets.txt`: hard-coded public IPs and `ssh`/`rsync`/`scp`
   deploy targets in CI, Makefiles and scripts — each is a server; ask whose. Then the SSH
   sweep on anything reachable: `identity` shows `instance-id: n/a` for a non-AWS box, and
   `ssh-keys` shows whose keys are on it. Then the provider accounts themselves: a Vercel
   "personal scope" (`saas-access-inventory.sh` says so), a Render workspace or Fly org whose
   owner email is a person's, a Heroku app owned by `dan@gmail.com` (`members-heroku.json`
   `owns app …`), Lightsail/EC2 in an AWS account the company does not hold (ask for the account
   id behind any IP in an `amazonaws.com` range that is not the company's account — the
   ownership table has the company's ids; EC2 public IPs reverse to `ec2-…compute.amazonaws.com`
   and `aws ec2 describe-addresses` / `describe-instances` in the company account will *not*
   list them if they are someone else's). Why it matters beyond ownership: the company cannot
   patch, back up, rotate, or even shut down what it does not own, and when the person leaves
   the server goes with them — or keeps running, unpaid and unpatched, with production traffic
   and customer data on it. When you cannot tell whose box a host is, ask ("do you know where
   the server behind api.company.com is / whose account it is?") and treat "I don't know" as
   the finding. Fix: move the workload into the company's account (the migration
   shape in infra-audit Q3/Q5), retire the personal box, and add the provider to the system
   list if the company keeps using it.

Why: an account in a person's name is that person's account. When they leave, are unreachable,
or dispute something, the company cannot recover it — Apple and Google in particular will not
transfer an individual enrolment to a company. Fix: transfer to company-owned identities now
(registrar: change account email + registrant; AWS: change root email to an alias and hand the
CEO the MFA; Apple: enrol the company and transfer apps; GitHub: add the CEO as owner, move the
billing email; Vercel/Atlas/Slack: transfer ownership). Every transfer has a vendor-specific
procedure — name it in the finding, and say what needs the current holder's cooperation.

### Q7. Domains (recommended: yes, all of it)

`domain-<name>.json`: registrar, registrant, expiry, `status` includes
`clientTransferProhibited` (lock on), DNSSEC; NS records → which DNS provider. Then the
screenshot of the registrar account: whose email, 2FA, auto-renew, payment method, other
domains in the same account. Include every domain the company uses (marketing, app, email,
short links, the one the first contractor bought). Losing the domain loses email, every
password reset, and customers; a domain on a personal account with a card that expired is the
most common way a small company disappears from the internet. Fix: a company registrar account
(Cloudflare Registrar or the incumbent) owned by the CEO's company identity, lock on,
auto-renew on, expiry ≥ 1 year, DNS provider account company-owned.

### Q8. Billing in the company's name (recommended: yes)

Company card or invoicing, company legal entity and address on the account, invoices to a
company address. Evidence: AWS `aws-account-contact.json` (company name/address), GitHub
`billing_email`, Stripe `stripe-account.json`, Vercel/Atlas/others via screenshot of the billing
page. A founder's personal card on AWS is a company-continuity finding (card expires →
account suspended → site down) and a bookkeeping one. Fix: company card everywhere; a
`billing@` alias the CEO reads; a calendar reminder for card expiry.

### Q9. App-store, publisher, and registry accounts company-owned (recommended: yes)

Apple Developer Program (the enrolment must be the company's — Organization, with a D-U-N-S —
not an Individual enrolment in someone's name; the Account Holder can be any officer or
founder but must be a current person on the roster — screenshot of Membership + Users and
Access), Google Play Console (account owner — screenshot), Chrome Web Store, Slack App
Directory / Shopify Partners / Zapier developer, npm (`members-npm.json`), Docker Hub, PyPI,
GitHub Marketplace. Individual enrolments cannot be transferred to a company at Apple; the
fix is a new company enrolment and an app transfer — name the wait. Fix elsewhere: transfer
ownership to a company identity, add a second admin so one departure cannot lock the company
out.

---

## D. Secrets and email

### Q10. Company password manager for all shared credentials (recommended: yes)

Is there a 1Password/Bitwarden business account, is everyone on the roster in it
(`members-1password.json` vs roster), and is it the *only* place shared credentials live? Ask
how the last three shared credentials were shared; search — with the user, read-only — Slack
(`password`, `login`, `.pem`), Notion, and the wiki for the obvious strings; check
`repo-scan/docs-credentials.txt` for credentials in READMEs. Fix: a business vault ($8/seat);
move every found credential in and **rotate it** (moving does not un-leak it); a rule that
Slack is not a vault. The AWS root MFA recovery codes, the registrar login, and the Apple
Account Holder login go in a vault the CEO and one other person can see.

### Q11. Production secrets in a secret store, limited, known, rotated after departures (recommended: yes)

`aws-secrets.json`: names, `LastChangedDate`, `LastRotatedDate`, rotation enabled; compare the
dates to the departure dates in the roster — a secret last changed before the last engineer
left has been seen by that engineer. Same for the PaaS env stores (Vercel/Render env vars have
"updated" timestamps — screenshot), Stripe restricted keys (created date), and for the
`.env` files the sweep finds on disk (`secrets-on-disk` names and file dates). Who can read
them: IAM policies with `secretsmanager:GetSecretValue` on `*`, PaaS team members (everyone
with project access can read env vars — that is the whole team). Fix: one secret store per
platform (Secrets Manager / the PaaS env store — not a `.env` on the box); a list of every
secret with its consumers; rotate the ones older than the last departure now, in consumer
order (new value → consumers updated → verified → old value revoked). Put the list in the
runbook so the next departure is a checklist.

### Q12. Email domain: SPF, DKIM, DMARC set up and working; no external forwards (recommended: yes)

`domain-<name>.json`: SPF present with `-all`/`~all` and ≤ 10 lookups; DKIM selectors found
for the senders in use (Google, Microsoft, SendGrid, Postmark, Mailgun, SES); DMARC record
with `p=quarantine` or `p=reject` and a `rua=` address someone reads. `p=none` or no record
means anyone can send as the company — phishing your own customers and your own team's
password resets. **Working** means a real message passes: ask the user to send one to a
checker (Gmail "show original" shows SPF/DKIM/DMARC PASS per line; or a mail-tester address)
from each sending system, and record the result. Then external auto-forwards: `google-forwards.csv`
via `gam`, otherwise the Workspace admin's Gmail forwarding report (screenshot) — a former
employee's mailbox forwarding to their personal address is a Q2 finding. Fix: DMARC to
`quarantine` then `reject` after a week of reports; DKIM for every sender; remove the forwards.
