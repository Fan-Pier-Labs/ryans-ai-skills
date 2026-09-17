# Code review report template

Use this shape. Every one of the twenty questions gets a row in the scorecard and a section,
even when the answer is "Yes, verified" in one line — a reader checking the review against the
checklist should never wonder whether a question was skipped. Lead with the worst thing. Write
for someone who knows the domain but didn't watch you work: what it is, why it matters, what to
do, how sure you are.

---

```markdown
# Code Quality Review — <repo name>

**Scope:** `<owner/repo>` at `<branch>` `<short sha>` (<N> files, <N> lines, <languages>)
<packages reviewed, if a monorepo: "web/ and api/; ignored infra/terraform">
**Review date:** <YYYY-MM-DD>
**Working tree:** clean / <N> uncommitted paths (reviewed as-is)
**Evidence:** commands in this report, tools run (<eslint, tsc, mypy, knip, jscpd, madge — and
which were not installed>), test suite <run and passing / run and failing / not run because …>
**Not examined:** <production traffic, other repos in the org, infrastructure, dependency
licences, the mobile client>

---

## Summary

<Three to five sentences. The single worst finding first, with its consequence. Then the
overall shape: "a 22k-line TypeScript API with strict types and a real CI gate, no integration
tests, and four unauthenticated admin endpoints." End with what fixing the top three costs in
time.>

## Scorecard

| # | Question | Answer | Severity if No | One-line evidence |
|---|---|---|---|---|
| 1 | Linter + type checker enabled and enforced | Yes / **No** / Partial / Unknown | High | <eslint configured, not in CI; 412 warnings> |
| 2 | No dead code | | Medium | <knip: 23 unused exports, 4 unused files> |
| 3 | Endpoints require authN + authZ | | **Critical** | <4 of 47 routes unauthenticated; 6 IDOR> |
| 4 | No dead endpoints | | Medium | <3 candidates, no traffic data available> |
| 5 | No duplicate code | | Medium | <jscpd 6.1%; invoice total in 4 files> |
| 6 | Unit tests | | High | <128 tests, pass in 40s> |
| 7 | Integration tests | | High | <none — nothing boots the app> |
| 8 | Module graph is a DAG | | Medium | <2 cycles, one through the domain core> |
| 9 | Types set up | | High | <strict: false in api/tsconfig.json; 310 `any`> |
| 10 | CI exists and gates every PR | | High | <workflow on push to main only, not required; no coverage gate> |
| 11 | No committed secrets | | **Critical** | <.env tracked; live Stripe key> |
| 12 | Lockfile committed + audited | | Medium | <lock present; 3 high advisories> |
| 13 | No oversized files | | Medium | <2 files over 1000 lines> |
| 14 | Errors not swallowed | | Medium | <31 empty catches, 4 in payment path> |
| 15 | README covers setup/run/test | | Low | <install only; test command is stale> |
| 16 | Baseline ESLint rules enabled (TS/JS) | <n>% / N/A | High below ~80% | <62/105 as error; promise group absent> |
| 17 | Test coverage ≥ 80%, threshold enforced | <n>% lines / <n>% branches | High | <71% lines, 48% branches, no threshold; auth/ at 12%> |
| 18 | Force-push blocked on every branch (default branch is the floor) | | **High** | <default only / not protected at all / enforce_admins false> |
| 19 | Clock faked, no fixed sleeps in tests | | Medium | <31 fixed sleeps = 48 s/run; no fake-timer tooling> |
| 20 | No change-detector tests | | Medium | <4 snapshots over 1k lines; 6 files change in lockstep with their source> |

**Answer counts:** <n> Yes · <n> Partial · <n> No · <n> Unknown · <n> N/A

---

## Top findings

Ranked by severity, not by question order. Each one: what, where, what it costs, the fix.

### 🔴 1. <Title — the thing a reader must act on today>
**Where:** `<file:line>` (+<n> more, listed in Q<n>) · **Evidence:** <command and output, or the
code> · **Impact:** <what an attacker or a user gets, concretely> · **Fix:** <the exact change,
and what it breaks if anything> · **Effort:** <hours / a day>

### 🟠 2. <Title>
### 🟡 3. <Title>

<Three to seven findings. A long list buries the ones that matter.>

---

## Q1. Linter and type checker — <Answer>

<Config found, whether it is wired to a script / hook / CI, the violation count from actually
running it, and the fix. One line if it is a clean Yes.>

## Q2. Dead code — <Answer>

<Tool output, the categories found (unreferenced exports, unused files, commented-out blocks,
dead deps), and what you ruled out as framework-called. Counts, then the list, then the fix.>

## Q3. Endpoint authentication and authorization — <Answer>

<N/A with one line if this is a library or CLI.>

| Method | Path | File:line | AuthN | AuthZ | Finding |
|---|---|---|---|---|---|
| DELETE | `/api/admin/purge` | `api/main.py:21` | **none** | n/a | Unauthenticated destructive endpoint |

<Then: how auth is structured (deny-by-default or opt-in, and where the allowlist is), each
unauthenticated route with what it exposes, each IDOR with the query that needs scoping, and the
adjacent findings — CSRF, webhook signatures, JWT verification, rate limiting, CORS. This is the
longest section whenever the answer is not Yes.>

## Q4. Dead endpoints — <Answer>

| Method | Path | Repo references | Traffic data | Verdict |
|---|---|---|---|---|

<Say explicitly that no-reference routes are candidates, and what would confirm them.>

## Q5. Duplicate code — <Answer>

<Tool figure on non-vendored code, the groups worth extracting with locations, and the groups
you judged **not** worth extracting and why.>

## Q6. Unit tests — <Answer>

<Count, whether the suite runs and passes with the command you used, what it covers that
matters, what it mocks that undermines it, skipped-test count, coverage if measured.>

## Q7. Integration tests — <Answer>

<Which tiers exist, what they boot, whether you ran them, and the one flow that should be
covered first if none are.>

## Q8. Module graph — <Answer>

<Cycles with their files and what each costs; layer violations with the arrow that is wrong;
highest fan-in module. The fix per cycle plus the lint rule that keeps it fixed.>

## Q9. Types — <Answer>

| Package | Strict | `any` / untyped defs | Escapes | Runtime validation at boundaries |
|---|---|---|---|---|

## Q10. CI gates — <Answer>

Reproduce the gate table from the checklist, filled in. A missing workflow is the first line.

| Gate | Present | Evidence |
|---|---|---|
| A CI workflow exists | | <path, or **none found**> |
| Triggers on `pull_request` | | |
| Linter runs | | |
| Type check runs | | |
| Unit tests run | | |
| Integration tests run | | <on PRs / scheduled only / not at all> |
| Coverage threshold enforced (≥80%) | | <the command CI runs, and whether it carries the gate> |
| Dependency audit runs | | |
| Required by branch protection or ruleset | | <`gh api …/protection` result> |
| No `continue-on-error` on the gates | | |
| Covers every package | | |

| Workflow | Triggers on PR | Lint | Types | Unit | Integration | Coverage | Required |
|---|---|---|---|---|---|---|---|

## Q11. Committed secrets — <Answer>

| File:line | Kind | Redacted | Live? | In history? |
|---|---|---|---|---|

<Fix order: rotate (naming the consumers) → remove from tree → decide on history → add a
scanner. Never print a real secret value.>

## Q12. Lockfile and dependency audit — <Answer>

## Q13. Oversized files — <Answer>

| File | Lines | Changed in last 200 commits | One job? |
|---|---|---|---|

## Q14. Swallowed errors — <Answer>

<Counts by pattern, the ones in critical paths called out separately, and the lint rule.>

## Q15. README — <Answer>

<Which of setup / env / run / test / architecture are present, and what breaks if a new
engineer follows it literally.>

## Q16. Baseline ESLint rule coverage — <n>% (<n>/105 as error, <n> as warn)

<N/A in one line for a repo with no TypeScript or JavaScript, naming the equivalent checked
under Q1 instead.>

| Group | Baseline | Enabled | Missing |
|---|---|---|---|
| Floating / misused promises | 7 | | |
| Silent wrong behaviour | 8 | | |
| Error handling | 4 | | |
| Injection / legacy APIs | 11 | | |
| Module graph | 5 | | |
| React correctness | 2 | | |
| Type honesty | 4 | | |
| Everything else | 64 | | |

<Then: whether the type-aware rules actually resolve types (`projectService`/`project` present
and dependencies installed) or are nominally on and matching nothing; configuration differences
where the repo narrowed a rule's options rather than omitting it, and what each difference
changes; and the wave plan — which zero-violation rules can be committed as ratchets today, and
the measured violation count for the rest. Cross-reference Q1 and Q10: coverage means nothing if
the lint job is not required.>

## Q17. Test coverage — <n>% lines / <n>% branches (recommended ≥ 80%, enforced)

**Measured with:** <the exact command> · **Threshold configured:** <where, at what number, or
**none**> · **Tiers included:** <unit only / unit + integration> · **Excluded from the
denominator:** <what the include/exclude list drops>

| Scope | Lines | Branches | Note |
|---|---|---|---|
| Whole repo (production code) | | | |
| <the module that matters most> | | | |
| <lowest-covered file that matters> | | | |

<Then: the three lowest-covered files whose failure would cost something, with percentages; why
the branch number differs from the line number if it does; whether the covered lines are actually
asserted (cross-reference Q6); and the ratchet plan — today's number, the threshold to set one
point below it now, and which file to cover first. If coverage could not be produced, say so here
and what was missing, and answer Unknown rather than estimating.>

## Q18. History protection — <Answer>

**Coverage:** <every branch (`~ALL` ruleset) / default branch only / none> · **Unprotected
branches right now:** <list, or none>

| Setting | State | Evidence |
|---|---|---|
| Force-push blocked on **every** branch | | <ruleset ref patterns> |
| Force-push blocked on the default branch (the floor) | | |
| Deletion blocked (`allow_deletions` false / `deletion` rule) | | |
| Binds admins (`enforce_admins` true / no standing `bypass_actors`) | | |
| Required checks present (from Q10) | | |
| Tag protection on release tags | | <N/A if releases are not cut from tags> |
| Org: members cannot delete repositories | | <ask if not readable> |
| A second copy exists | | <mirror, or "unknown — asked"> |

<One line on who currently has write access, and the `gh api -X PUT …/protection` call that fixes
it. If the repo is unprotected, this belongs in "Today" in the sequence below regardless of what
else the review found.>

## Q19. Real time in tests — <Answer>

**Suite duration:** <the measured wall-clock time, and the command> · **Fixed sleeps:** <n>
totalling <n>s per run · **Clock-faking tooling present:** <what, or none> · **Retries
configured:** <yes/no, and whether they exist to absorb timing flakiness>

| Location | Waits | Was really waiting for | Replace with |
|---|---|---|---|

<Then: the slowest tests from the runner's own timing, so the grep is confirmed rather than
trusted; whether production code takes the clock as a dependency at all, since that is what makes
faking possible and the finding may belong to the source file; and, if there is expiry / TTL /
backoff / scheduling logic with no fake clock anywhere, the statement that none of it is covered —
cross-reference the per-file numbers in Q17.>

## Q20. Change-detector tests — <Answer>

| Signal | Count | Worst examples |
|---|---|---|
| Snapshots / golden files | <n>, largest <n> lines | |
| Tests whose only assertions are mock calls | | |
| Tests that compute the expected value with the code under test | | |
| Test files changing in lockstep with their source (ratio ≈ 1.0) | | |

<Lockstep ratios are candidates, not verdicts — say which ones you opened and what you found. For
each confirmed case: what behaviour the test was meant to protect, and the assertion that would
protect it instead. Note the ones you judged legitimate (a small reviewed snapshot, a verified
call at a real boundary) so the reader can see the line you drew. Close with the question for the
team: when you last refactored, how much of the diff was tests?>

---

## Recommended sequence

**Today (minutes to hours, no risk):** <add the `~ALL` no-force-push ruleset, or at minimum block
force-push and deletion on the default branch, and set enforce_admins; add the auth guard to the 4 open routes; rotate the committed key; turn the CI
workflow on for pull_request and mark it required; set the coverage threshold one point below
today's measured number; commit the <n> zero-violation baseline lint rules as ratchets>
**This week (a day or two):** <one integration test that boots the app; strict types in the api
package; replace the <n> fixed sleeps with polls and fake the clock in the expiry tests; delete the
dead exports knip found>
**Then (decisions, not fixes):** <split the two 1500-line modules; consolidate the duplicated
invoice logic; retire the v1 endpoints after 30 days of 410>

## Method and caveats

- Commands and tool versions used: <list>. Tools not installed and therefore not run: <list>.
- Counts exclude vendored, generated, and gitignored files (`git ls-files`-based).
- The test suite was <run / not run>; integration tests <not run because they need a database>.
- Auth findings are from reading routes and middleware; <no/some> runtime verification was done.
- Dead-code and dead-endpoint findings are candidates: frameworks call code by convention, and
  callers outside this repo are invisible here.
- Not reviewed: <infrastructure, secrets management at runtime, licences, performance, the
  mobile client, other repos in the org>.
```

---

## Per-question contract

`answer (Yes/No/Partial/Unknown) → evidence (the command and what it printed, or file:line) →
why it matters for this codebase → recommended state → the exact fix, with effort → confidence`

## Tone

Plain language, short sentences, tables for facts. Say what you checked and what you couldn't.
A "No" without a fix, or a fix without the command, isn't finished. Do not pad "Yes" answers;
one line of evidence is the whole section. Praise only what is earned, and be specific about it
— "the auth layer is deny-by-default with a three-entry allowlist" is worth more to the reader
than "good code quality overall".
