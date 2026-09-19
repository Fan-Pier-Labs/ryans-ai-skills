# Report template

Fill every section. A section with nothing in it says "none found" and stays — an absent section
reads as an unasked question.

---

# Security audit — `<repo>` @ `<short sha>`

**Date** · **Branch** · **Semgrep `<version>`, `<OSS | Pro>` engine** · **Packs:** `p/default`,
`p/python`, …

## Summary

Three to six sentences, leading with the **worst confirmed finding** and what an attacker gets
from it. Then the shape of the rest: how many confirmed, how many need context, how many
refuted. Then the single sentence that bounds the whole document — what this scan did not look
at (authorization, git history, dependencies, infrastructure, running behaviour).

| | Count |
|---|---|
| 🔴 Critical | |
| 🟠 High | |
| 🟡 Medium | |
| 🟢 Low / Informational | |
| ⚪ Refuted | |
| ❓ Needs context | |
| Raw matches before dedupe and triage | |

## Coverage — what was actually scanned

> N of M git-tracked files scanned. `tests/` and `vendor/` covered by a second pass over a
> `git archive` copy. K files over the size limit, not scanned: … Languages with files but no
> rules loaded: none.

A one-line table of files scanned per language, and the reason for every excluded path. If
coverage is partial and could not be widened, say what a full scan would need — this paragraph
is what tells a reader how much the rest of the report is worth.

## Confirmed findings

Worst first. One block each:

### 🔴 1. `<one-line title: the bug, not the rule id>`

| | |
|---|---|
| **Where** | `path/to/file.py:120` (+ N more sites, listed below) |
| **Rule** | `check_id` · CWE-NNN · OWASP A0N |
| **Reachable by** | anonymous internet / authenticated user / internal operator / not reachable today |
| **Impact** | what the attacker gets |
| **Confidence** | High / Medium — and why |

**What the code does.** The read, in two or three sentences, with the path from the untrusted
input to the sink. Quote the minimum code needed.

**Why it is exploitable here.** The reachability argument, referencing the route or entry point.

**Fix.**

```diff
- the line as it is
+ the line as it should be
```

Plus anything that has to happen alongside the code change — rotate the key, invalidate
sessions, check the logs for prior exploitation.

**Other sites:** `a.py:44`, `b.py:91`, …

## Needs context

One line each: the finding, and the single question that would resolve it — with who can answer
it.

## Refuted

Grouped by rule, with the reason each group is not a bug. Keep this section; it is what stops
the next audit from re-litigating the same matches, and a reader uses it to calibrate the rest.

| Rule | Sites | Why it is not a bug here |
|---|---|---|

## What this audit could not see

The blind-spot table from the skill, filled in for this repo, each row naming who covers it:
authorization / IDOR, secrets in git history, vulnerable dependencies, cloud and server
configuration, business logic, missing controls, cross-file taint (if the OSS engine ran),
unsupported languages present in the repo.

## Recommended sequence

1. **Today** — the 🔴s, and any rotation they imply.
2. **This week** — the 🟠s.
3. **This month** — the 🟡s, plus the custom rules that would keep each class from coming back.
4. **Ongoing** — Semgrep in CI on the diff, with the pack list from this report.

## Method and caveats

The exact commands run, the packs and versions, the engine, the scratch paths, what was
excluded and why, how long it took, and anything that failed or timed out. Someone must be able
to reproduce this report from this section alone.
