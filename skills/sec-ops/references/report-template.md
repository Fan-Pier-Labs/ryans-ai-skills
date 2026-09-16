# Sec-ops report template

Every one of the thirteen questions gets a scorecard row and a section, even when the
answer is "Yes, verified" in one line. Lead with the worst thing: former people with access,
then code outside the company's control, then resources in someone else's name. The access
matrix and the ownership table are the two artifacts a founder will actually use; put them
before the per-question sections.

---

```markdown
# Operational Security Audit — <company>

**Scope:** <N> systems (<list>), <M> people on the roster (<c> current, <f> former), <k> servers swept
**Audit date:** <YYYY-MM-DD>
**Evidence:** API/CLI collectors (`secops-<date>/`), SSH sweep of <n>/<m> instances,
repo scan of <repos>, DNS/whois, <n> screenshots transcribed (listed in Method), user answers
labelled "reported"

---

## Summary

<Three to five sentences. The single worst finding first, with the consequence ("Bob, a
contractor who left in 2024, is still an Atlas org owner, has an SSH key on the prod box, and
owns the GitHub repo the API deploys from"). Then the shape: how many systems, how many
former people with access, how many resources not in the company's name. End with what
fixing the top three takes.>

## Scorecard

| # | Question | Answer | Severity if No | One-line evidence |
|---|---|---|---|---|
| 1 | All code in the company code host; everything live traces to it (1a–1f) | | Critical | <k hosts/units NO MATCH; tier missing; n HIGH deps> |
| 2 | No ex-contractor / ex-engineer access | | Critical | <n former people with access across m systems> |
| 3 | CEO owner/admin everywhere; all accounts and all servers in company's name | | Critical | <k systems where CEO not owner; j accounts on personal email; h hosts on unowned infra> |
| 4 | No secrets in repo history | | High | |
| 5 | No shared accounts / credentials | | High | |
| 6 | Prod access by named individual | | High | |
| 7 | Domains company-owned, locked, auto-renew | | Critical | |
| 8 | Billing in company's name | | Medium | |
| 9 | App-store / registry accounts company-owned | | High | |
| 10 | Password manager; nothing in chat/docs | | High | |
| 11 | Secrets in a store, limited, rotated after departures | | High | |
| 12 | SPF/DKIM/DMARC working; no external forwards | | Medium | |
| 13 | 2FA on every identity, required where possible | | High | <n identities with MFA off> |

---

## Access matrix

<Paste `ACCESS-MATRIX.md`. Rows: people (former first, then unknown, then current). Columns:
systems. Cell: role. Bold the former rows. Below it, the identities that could not be keyed
to a person, and the systems that are screenshot-only or missing.>

## Ownership table

| System | Account / org | Primary email | On company domain | CEO role | Billing | Source |
|---|---|---|---|---|---|---|
| AWS <acct id> | | | | | | api / screenshot |
| GitHub <org> | | | | | | |
| Domain <name> | registrar | | | | auto-renew? lock? | whois + screenshot |
| Apple Developer | entity type | | | Account Holder | | screenshot |
| … | | | | | | |

---

## Q2. Ex-contractor / ex-engineer access — <Answer>

<Per former person: a table of every cell in their row, what they created or own that must be
transferred first, which secrets they could have seen, and the removal order. This is the
longest section when the answer is No.>

## Q1. All code in the company code host — <Answer>

| Sub-check | Answer | Evidence |
|---|---|---|
| 1a Every repo / deploy source is org-owned | | <services → repos; forks; CLI-deployed services> |
| 1b Every live host traces to a repo component | | <`CODE-RECONCILIATION.md`: n hosts, k NO MATCH, structural gaps> |
| 1c Every scheduled job / pipeline has source | | <EventBridge/Glue/Step Functions/cron → DAGs/scripts; k NO MATCH> |
| 1d Production runs the committed code | | <Lambda LastModified vs CI; on-box uncommitted/unpushed; app dirs without .git> |
| 1e Company-owned dependencies are in the company's hands | | <`deps-provenance.md`: n HIGH (low-volume + employee-maintained), m MEDIUM> |
| 1f Mobile/desktop builds have source in the repo | | |

<Then per NO MATCH item: what it is, what serves/runs it, what breaks without it, where the
source probably is, how to recover it, and the fix. A missing frontend or backend tier, or a
production pipeline with no source, is written up like a Critical security finding. HIGH
dependency rows: package, maintainer (roster name + status), weekly downloads, where it is
used, and the vendoring/transfer recommendation.>

## Q3. Ownership — <Answer>

<Per system where the CEO is not owner or the account is in another name: current holder,
the vendor's transfer procedure, whose cooperation it needs, and the risk while it waits.
Then the infrastructure table from `CODE-RECONCILIATION.md → Where each host physically runs`:
every live host and API host, its IP owner and provider, and whether that provider's account is
in the inventory. Any host on a residential IP, a tunnel, or an unaccounted provider is written
up as Critical: what runs there, whose box it is, what the migration into the company's account
looks like, and what happens to it the day that person leaves.>

## Q4 … Q13 — one section each, in numeric order

<`answer → evidence (source) → why it matters here → recommended state → exact step and
order → confidence`. One line when Yes.>

---

## Removal and rotation runbook for <company>

<`references/offboarding-runbook.md` filled in with this company's systems, secrets, and
owners. This is a deliverable, not an appendix.>

---

## Recommended sequence

**Today (minutes, no risk):** <add CEO as owner on X, Y, Z; remove former people from systems
where they own nothing; turn on the 2FA requirement; DMARC to quarantine; transfer lock on>
**This week (needs ordering):** <replace personal PATs/keys with company-owned ones, then
remove the people; transfer repos/projects/apps then remove owners; rotate secrets older than
the last departure, consumer by consumer>
**Decisions:** <Apple company enrolment; registrar consolidation; secret store; password manager>

## Method and caveats

- Collectors ran read-only on <date>; JSON is in `<dir>/`.
- Screenshots transcribed: <system: page, date> — point-in-time, not re-runnable.
- Systems with no evidence: <list> — marked Unknown.
- On-box evidence is one sample per instance; secret values were never read; SSH key
  fingerprints and comments were recorded, not keys.
- Answers marked "reported by user" were not verified.
- Things I could not find and asked about: <X — user said it is at Y (reported) / user does
  not know (flagged under Q1/Q3)>.
- Not examined: application code security, dependency CVEs, infrastructure configuration
  (see infra-audit), cost (see infra-cost-review), personal devices.
```

---

## Per-question contract

`answer (Yes/No/Partial/Unknown) → evidence (source + what it showed) → why it matters for
this company → recommended state → the exact step, in an order that keeps production up →
confidence`

## Tone

Plain language, short sentences, tables for facts. Name people by the roster name and the
identity that was found ("bob@agency.io, Bob Contractor, former"). Say what you checked and
what you couldn't. A "No" without the transfer/removal step, or a removal step without the
"transfer/replace first" note where it applies, is not finished. Recommend what a
five-person company will actually do, not what a hundred-person one should.
