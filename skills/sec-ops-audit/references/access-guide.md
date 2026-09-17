# Access guide — per system: what to ask for, how to collect, and the screenshot fallback

Order of preference: **API/CLI/MCP** (re-runnable, exact) → **screenshot transcribed to JSON**
(dated evidence, cannot be re-run) → **reported by user** (not evidence). Ask for everything in
one message, listing the systems and the scope for each, so the user does one round of granting.
Read-only scopes only; the collectors refuse nothing because they never write.

## The roster (`roster.csv`)

```csv
email,name,status,github,aliases,role
ceo@company.com,Ada Lovelace,current,adalove,ada.lovelace@gmail.com;U01ABCDE,ceo
bob@company.com,Bob Contractor,former,bobdev,bob@agency.io;bob.contractor@gmail.com,contractor 2023-2024
```

- `status`: `current` or `former`. Anyone not `current` is `former` for the matrix.
- `github`: login (GitHub's API does not return member emails). `npm`: npm username, if known —
  `dependency-provenance.sh` matches package maintainers against `email`, `github`, `npm`, and
  `aliases` to find employee-maintained dependencies.
- `aliases`: `;`-separated other identities — personal emails, Slack user ids, old company
  addresses, agency emails. Matching is case-insensitive on email, github, and any alias.
- Add `role` and dates in free text; the digest prints it next to the person.

## Normalized JSON the digest reads

One file per system, `members-<system>.json`:

```json
{"system": "vercel", "source": "api", "collected": "2026-09-13T10:00:00Z",
 "members": [
   {"id": "ada@company.com", "email": "ada@company.com", "name": "Ada", "role": "owner",
    "mfa": null, "last_active": "2026-09-12", "status": "active"}
 ],
 "notes": ["team: company-prod"]}
```

- `role`: `owner` | `admin` | `member` | `guest` | `outside` | `bot` | `unknown`. Owners and
  admins count as admin for Q3. Use `guest` for Slack guests/GitHub outside collaborators,
  `bot` for service accounts and apps.
- `mfa`: `true` / `false` / `null` (unknown). `status`: `active` | `suspended` | `deactivated`
  | `invited`. Deactivated identities are still listed (their tokens may live on) but shown
  greyed.
- `source`: `api`, `cli`, `mcp`, or `screenshot` — screenshots get a `"screenshot": "<file or
  description>"` note.

`ownership-<system>.json`:

```json
{"system": "aws", "account": "123456789012", "display_name": "Company Prod",
 "primary_email": "aws-root@company.com", "billing_email": "billing@company.com",
 "owner_identity": "ada@company.com", "source": "api", "notes": ["org management account"]}
```

`primary_email` not on `--domain` is flagged; `owner_identity` not equal to `--ceo` (or the
CEO not `owner`/`admin` in the matching `members-*.json`) is flagged.

Hand-transcribing a screenshot: write the file with `"source": "screenshot"`, one member per
visible row, `mfa: null` unless the page shows it, and put the page name and date in `notes`.

## Systems

For each: preferred access · exact read-only scope · what the collector writes · screenshot
fallback (page name) · notes.

### GitHub
- **Access**: `gh auth status` as an **org owner** (member-level `gh` sees members but not
  outside collaborators, installations, secrets, PATs, or `two_factor_requirement_enabled`).
  Scopes `read:org`, `repo`, `admin:org` read; fine-grained token: Organization
  "Administration: read", "Members: read", Repository "Administration: read".
- **Collector**: `scripts/github-access-inventory.sh --org <org>` → `members-github.json`,
  `ownership-github.json`, `github-outside-collaborators.json`, `github-installations.json`,
  `github-org-secrets.json`, `github-pats.json`, `github-forks.json`, `repo-<name>.json`
  (default-branch protection, deploy keys, outside collaborators, security_and_analysis,
  visibility), `github-audit-log.json` (Enterprise only).
- **Screenshot**: Org → People (with role filter), Outside collaborators, Settings → Third-party
  access, Installed GitHub Apps, Security → Authentication security (2FA requirement), Billing
  (email).
- **Note**: repos under personal accounts are invisible to the org API. Ask each current and
  former engineer, and check every deploy target's `repo` field.

### AWS
- **Access**: a profile with `SecurityAudit` + `account:GetContactInformation`,
  `account:GetAlternateContact`, `organizations:Describe*`, `identitystore:List*`,
  `sso:List*`. `aws sts get-caller-identity` first; never run against an unconfirmed account.
- **Collector**: part of `saas-access-inventory.sh --aws-profile <p>` → `members-aws.json`
  (IAM users with MFA, key ages, last used from the credential report; Identity Center users),
  `ownership-aws.json` (root contact, org management account), `aws-alternate-contacts.json`,
  `aws-keypairs.json`, `aws-external-trusts.json` (roles assumable by other accounts),
  `aws-secrets.json` (names + rotation dates), `aws-account-contact.json`.
- **Screenshot**: Billing → Payment methods (card holder), Account → root email/MFA, IAM Identity
  Center → Users if the API is denied.
- **Note**: the root email and MFA device are the ownership fact; the API shows the contact
  name/address but not the root email — ask, or screenshot Account settings. Hand infra-level
  MFA enforcement, CloudTrail, ports to infra-audit.

### GCP
- **Access**: `gcloud auth list`; Viewer + `resourcemanager.projects.getIamPolicy`.
- **Collector**: `gcloud projects list` + `get-iam-policy` per project → `members-gcp.json`.
- **Screenshot**: IAM & Admin → IAM per project; Billing account admins.

### Vercel
- **Access**: `VERCEL_TOKEN` (Account settings → Tokens; full-account read is the only kind) or
  `vercel whoami` logged in; `VERCEL_TEAM_ID` or `--vercel-team <slug>`.
- **Collector**: `GET /v2/teams`, `/v2/teams/{id}/members`, `/v9/projects` (linked `repo`,
  env var **names** only) → `members-vercel.json`, `ownership-vercel.json`, `vercel-projects.json`.
- **Screenshot**: Team → Settings → Members; Billing.

### Render
- **Access**: `RENDER_API_KEY` (Account settings → API keys, read is implied).
- **Collector**: `/v1/owners`, `/v1/services` (repo, branch, autoDeploy) → `ownership-render.json`,
  `render-services.json`. Members are **not** in the API.
- **Screenshot**: Workspace → Members (roles); Billing.

### Fly.io
- **Access**: `fly auth whoami`.
- **Collector**: `fly orgs list --json`, `fly orgs show <slug> --json` → `members-fly.json`.

### Heroku
- **Access**: `heroku auth:whoami`.
- **Collector**: `heroku teams --json`, `heroku members --team <t> --json`, `heroku apps --all
  --json`, `heroku access -a <app> --json` → `members-heroku.json`, `heroku-apps.json`.

### Railway, Netlify, DigitalOcean, Hetzner, Linode
- Railway: no member API — screenshot Workspace → People. Netlify: `netlify api listMembersForAccount`
  with a PAT (`NETLIFY_AUTH_TOKEN`) — collector covers it. DigitalOcean: `doctl account get`,
  team members are UI-only — screenshot Settings → Team. Hetzner/Linode: screenshot the
  project members; add the servers to `hosts.tsv` for the SSH sweep.

### Cloudflare
- **Access**: `CLOUDFLARE_API_TOKEN` with `Account Settings: Read`, `Zone: Read`, `DNS: Read`;
  `CLOUDFLARE_ACCOUNT_ID`.
- **Collector**: `/accounts/{id}/members`, `/zones` → `members-cloudflare.json`,
  `cloudflare-zones.json` (registrar-managed domains show `status` and expiry).
- **Screenshot**: Manage Account → Members; Domain Registration → Manage Domains.

### MongoDB Atlas
- **Access**: `atlas` CLI with an org API key (Org Read Only) — `atlas config list`.
- **Collector**: `atlas organizations users list`, `atlas projects list`, per project `atlas
  projects users list`, `atlas dbusers list`, `atlas accessLists list`, `atlas organizations
  apiKeys list` → `members-atlas.json`, `atlas-dbusers.json`, `atlas-accesslist.json`,
  `atlas-apikeys.json`.
- **Screenshot**: Organization → Access Manager; Project → Database Access, Network Access.

### Supabase / Neon / PlanetScale
- Supabase: `SUPABASE_ACCESS_TOKEN` → `/v1/organizations`, `/v1/organizations/{slug}/members`,
  `/v1/projects` → `members-supabase.json`. Neon/PlanetScale: screenshot Org → Members.

### Slack
- **Access**: `SLACK_TOKEN` — a user token from a **workspace admin** with `users:read`,
  `users:read.email`, `admin` (for `team.integrationLogs`), `team:read`.
- **Collector**: `users.list` (admins, owners, guests `is_restricted`/`is_ultra_restricted`,
  `deleted`, `has_2fa`, bots), `team.info`, `team.integrationLogs` → `members-slack.json`,
  `ownership-slack.json`, `slack-integration-log.json`.
- **Screenshot**: Admin → Manage members (filter: Deactivated, Guests); Manage apps; Settings →
  Authentication.

### Google Workspace / Microsoft 365
- **Access**: `gam` configured as a super admin (`gam info domain`), or `GOOGLE_ADMIN_TOKEN`
  (an OAuth access token with `admin.directory.user.readonly`,
  `admin.directory.rolemanagement.readonly`). M365: `az ad user list`, `az ad group member
  list` / Graph `directoryRoles`.
- **Collector**: users (suspended, 2SV enrolled, isAdmin, lastLoginTime), admins, forwards
  (`gam all users print forwards` when `gam`), third-party tokens (`gam all users print tokens`)
  → `members-google.json`, `google-forwards.json`, `google-tokens.json`.
- **Screenshot**: Admin console → Users (add "2-step verification" and "Last sign-in" columns),
  Account → Admin roles, Security → API controls → App access control, Reporting → Email log
  search for forwards.

### 1Password / Bitwarden
- **Access**: `op signin` as an owner/admin (`op whoami`). Bitwarden: `bw login` + org id.
- **Collector**: `op user list --format json`, `op group list`, `op vault list` (names +
  membership via `op vault user list`) → `members-1password.json`, `1password-vaults.json`.
- **Screenshot**: People; Vaults (who has access to the break-glass vault).

### Sentry, Datadog, PagerDuty, Grafana, New Relic
- Sentry: `SENTRY_TOKEN` + `SENTRY_ORG` → `/api/0/organizations/{org}/members/`. Datadog:
  `DD_API_KEY` + `DD_APP_KEY` (+ `DD_SITE`) → `/api/v2/users`. PagerDuty: `PAGERDUTY_TOKEN` →
  `/users`. Collector writes `members-<system>.json` for each. Grafana/New Relic: screenshot.

### Linear, Notion, Figma, Jira/Atlassian
- Linear: `LINEAR_API_KEY` → GraphQL `users { email active admin }`. Notion: `NOTION_TOKEN`
  (integration with user-information capability) → `/v1/users`. Figma/Atlassian: screenshot
  Admin → Members. These hold company data, so they are systems.

### Stripe, payments
- **Access**: `STRIPE_API_KEY` — a **restricted** key with `Account: read` only.
- **Collector**: `GET /v1/account` → `ownership-stripe.json` (business name, email, country).
  Team members are **not** in the API.
- **Screenshot**: Settings → Team and security (members + roles, 2FA column); Business details.

### Email sending: SendGrid, Postmark, Mailgun, SES
- SendGrid: `SENDGRID_API_KEY` → `/v3/teammates`. Postmark/Mailgun: screenshot Account → Users.
  SES: covered by AWS IAM. DKIM for each is checked by `domain-inventory.sh`.

### Tailscale / VPN
- **Access**: `TAILSCALE_API_KEY` + `TAILSCALE_TAILNET`.
- **Collector**: `/api/v2/tailnet/{t}/users`, `/devices` → `members-tailscale.json`,
  `tailscale-devices.json` (device name, user, lastSeen — the ex-employee laptop).

### Package registries and publishers: npm, Docker Hub, PyPI
- npm: `npm whoami` → `npm org ls <org> --json` → `members-npm.json`; `npm access list
  collaborators <pkg>` for packages outside the org scope. Docker Hub / PyPI / Chrome Web
  Store: screenshot Org → Members / Collaborators.

### App stores: Apple Developer, Google Play
- **Screenshot only** (App Store Connect API can list users but needs a key the Account Holder
  creates; ask if one exists). Apple: Membership details (entity type: Organization vs
  Individual; Account Holder name), Users and Access (all rows with roles). Google Play: Users
  and permissions; Account details (owner email).
- Transcribe to `members-apple.json` / `members-googleplay.json` and `ownership-*.json`.

### Domain registrar and DNS
- `domain-inventory.sh` covers whois/DNS. The account itself: screenshot the registrar's
  account page (account email, 2FA on, auto-renew per domain, payment method) and the domain
  list. Cloudflare Registrar is covered by the Cloudflare collector.

### Servers (EC2 and elsewhere)
- `ec2-ssh-sweep.sh discover` for EC2; non-AWS boxes go in `hosts.tsv` by hand. Ask for SSH as
  the deploy user with passwordless sudo where possible (auth logs and other users'
  `authorized_keys` need root). Say exactly what `on-box-secops.sh` reads (SKILL.md §4).

### The product's own admin panel
- Ask for a read-only export or query of users with staff/admin roles (email, role, last
  login), or a screenshot of the admin-users page. Transcribe to `members-product-admin.json`.

### Everything else with a login
- Intercom, HubSpot, Zendesk, Amplitude, Mixpanel, Segment, Twilio, Auth0/Clerk dashboard,
  Zapier, Retool, Airtable, Metabase, Docker Hub, the bank, the payroll provider: screenshot
  the members page, transcribe, done. Anything holding customer data or able to move money is
  a system.

## Asking for access — the message shape

List every system from §1, and for each the *exact* thing: "GitHub: run `gh auth status`, or
give me a fine-grained token with Organization Administration/Members read", "Stripe: a
screenshot of Settings → Team and security", "Apple: screenshots of Membership and Users and
Access". State that every collector is read-only and that screenshots are transcribed and
labelled as such. Offer to proceed with whatever is granted and mark the rest Unknown.
