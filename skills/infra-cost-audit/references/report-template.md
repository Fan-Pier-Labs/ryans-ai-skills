# Report template

Use this shape. Fill every section; if a section has nothing, say so in one line rather than
deleting it — "no Tier C items" is information. Lead with the biggest single number. Keep the
prose for someone who knows the domain but didn't watch you work: what it is, what it costs,
what you recommend, how sure you are, how to undo it.

---

```markdown
# <Provider> Cost Review — <account / project name>

**Account:** <id> (<identity you ran as>)
**Region(s):** <where things actually are — "other regions verified empty via <method>">
**Review date:** <YYYY-MM-DD>
**Data sources:** Cost Explorer (unblended), CloudWatch <N>-day metrics, live inventory
(`infra-cost-review-<acct>-<date>/`), SSH sweep of <N> running instances (`ssh-sweep-<date>/`) <or "not granted — CPU-only utilisation">

---

## Summary

Steady-state spend is **$<X>/month** (<trend: flat / up N% since / down since>).

| Month | Cost |
|---|---:|
| <last 3–6 months> | |

**Reducible spend identified: ~$<Y>/month (<Z>%)**, in three confidence tiers:

| Tier | Monthly saving | Risk |
|---|---:|---|
| A — Waste, no production impact | **$** | None |
| B — Rightsizing and configuration | **$** | Low |
| C — Needs a decision from you first | **$** | Requires verification |

**The single biggest finding:** <one sentence, with the number>.

**Handed to infra-audit:** <N> non-cost findings (see the section at the end) — <the one that
matters most, in a clause, e.g. "production MongoDB runs on the app server">.

---

## Where the money goes (<last full month>)

| Service | Cost | Share |
|---|---:|---:|

Top usage types (what the service lines are actually made of):

| Usage type | Cost | What it is |
|---|---:|---|

---

## Tier A — Waste. Cut these. (~$<A>/month)

### A1. <Finding title with the number> — $<n>/mo
<What it is, in plain language. Why it's billing. The gotcha if there is one.>

| <Resource> | <State/Size> | <Created / stopped since> |
|---|---|---|

**Evidence:** <the commands/metrics that prove it's unused — ≥2 signals for anything you call waste>
**Confidence:** High / Medium / Low — <why>
**Reversibility:** <snapshot first → recoverable / irreversible: lose the IP>
**Action:**
```bash
<exact read-only or reversible command, with --profile and --region explicit>
```
<Then the destructive step, clearly separated, with the precondition ("once the snapshot reports
`available`").>

### A2. …

---

## Tier B — Rightsizing. Low risk. (~$<B>/month)

### B1. <Finding> — $<low>–$<high>/mo
<Metrics: avg / max over N days. What the metrics do NOT tell you (memory, I/O). The conservative
step and the aggressive step, with both savings.>

---

## Tier C — Verify before cutting (~$<C>/month)

Real costs where the infrastructure alone can't tell you whether the workload is still needed.
Each needs a yes/no from someone who knows the product.

### C1. <Finding> — $<n>/mo
<The signal that made it suspicious. What "keep" costs and what "kill" requires (final snapshot).>

---

## Handed to infra-audit (not cost items)

One line each, with where it was seen. These are not scored here; run `infra-audit` for them.

- <Self-hosted MongoDB on i-0abc (app box), port 27017 open to 0.0.0.0/0>
- <Cleartext third-party credentials in /var/www/app/config.js on a public host>
- <693-day uptime, Node 16, on the production box>

---

## Recommended sequence

**This week — $<A>/month, no production risk:**
1. …

**Next — $<B>/month, low risk, needs a maintenance window:**
…

**Then — decisions, not engineering:**
…

**Landing point:** roughly **$<lo>–$<hi>/month**, down from $<X>.

---

## Method and caveats

- Current costs are unblended actuals from Cost Explorer for <month>.
- Utilization is CloudWatch `CPUUtilization` over <dates> plus one on-box sample of memory,
  I/O, traffic and logins per instance (<date>). One sample is not a trend; downsizings below
  are the conservative step unless `sar` history or agent metrics supported more.
- **Target prices are estimates** from <Price List API / pricing page for <region> on <date>>;
  confirm against the bill after any change.
- What was not examined: <data transfer, reserved pricing, …>.
- Probes that failed (permissions): <list, or "none">.
```

---

## Per-finding contract (every item, every tier)

`what it is → what it serves / who owns it (or "unknown, could not verify") → current $/mo →
after $/mo → saved → confidence + evidence → reversibility → exact command(s)`

## Tone

Plain language, short sentences, numbers in tables. Say what you checked and what you couldn't.
No hedging on things you verified; no confidence on things you didn't. A finding the reader can't
act on without asking you a question isn't finished.
