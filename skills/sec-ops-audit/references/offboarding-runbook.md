# Removal and rotation runbook — template

Fill this in with the company's actual systems (every column of the access matrix), secrets
(every entry from Q11), and owners. Deliver it inside the report as the Q2 fix and recommend
it live in the repo or the wiki. Run the *Rotate* section alone for a leaked key or a lost
laptop; the whole thing for a departure.

## 0. Before removing anything: what do they own or hold?

| Check | Where | If yes |
|---|---|---|
| Repos, packages, images under their personal account that prod depends on | Q1 evidence, `repo-scan/personal-deps.txt` | Transfer / re-publish under the org **first** |
| Tokens/keys they created that CI or prod uses (PAT, AWS key, npm token, Slack bot) | `repo-scan/ci-secret-exposure.txt`, `members-aws.json` key ages | Create the replacement under a company-owned identity, switch consumers, verify a deploy, **then** revoke |
| Resources that vanish with the account (GitHub repos, Atlas projects, Slack apps, Vercel projects in a personal scope, Apple apps, domains) | ownership table | Transfer ownership to the company identity |

## 1. Email first (it recovers everything else)

- [ ] Suspend in Google Workspace / M365; keep the mailbox for <30> days, forward to <the CEO>; remove any forwards or delegations they set up.
- [ ] Transfer their Drive/Docs ownership.

## 2. Every system (one line per column of the matrix)

| System | Remove from | Who does it | Done |
|---|---|---|---|
| GitHub org | Members, outside collaborator on <repos>, deploy keys they added, PATs | | |
| AWS | IAM user + keys, Identity Center, SSH key pairs named after them | | |
| <PaaS> | Team member | | |
| <DBaaS> | Org/project user, database users they used, their IP in the access list | | |
| Slack | Deactivate; review apps they installed | | |
| 1Password | Remove; note which vaults they could see (→ §3) | | |
| Servers | `authorized_keys` on <hosts> | | |
| Product admin panel | Staff/admin account | | |
| Registrar / DNS / Cloudflare | Member | | |
| Apple / Google Play | Users and Access | | |
| Stripe, email sender, observability, support, analytics, design, docs, ticketing | Member | | |
| VPN / Tailscale (if any) | User + devices | | |

## 3. Rotate — every secret they could have seen

| Secret | Store | Consumers (what breaks) | Rotation procedure | Done |
|---|---|---|---|---|
| `DATABASE_URL` app user | AWS Secrets Manager `prod/db/app` | ECS service `api`, Lambda `reports` | rotate via SM → force new deployment | |
| Stripe secret key | Vercel env `STRIPE_SECRET_KEY` | `web` | roll key in Stripe dashboard → update env → redeploy → delete old key | |
| … every entry from Q11 … | | | | |

Order: new value provisioned → consumers updated → verified → old value revoked. Never revoke
first.

## 4. Record

- [ ] Roster updated: status `former`, date
- [ ] Access matrix re-run (`scripts/secops-digest.py`) shows no cells in their row
- [ ] Anything they still hold that could not be removed (an Apple Individual enrolment, a domain in their name) listed here with the transfer plan
