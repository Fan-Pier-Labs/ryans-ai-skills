---
name: code-quality-audit
description: Review a whole repository's code quality against twenty-two concrete questions — is a linter and type checker enabled and enforced, is there dead code, do endpoints require authentication and authorization, are there dead endpoints, is there duplicate code, are there unit tests, are there integration tests, is the module graph a DAG, are types set up, does CI exist and gate every PR on lint, tests, integration tests and coverage, are secrets committed, is the lockfile committed and audited, are files oversized, are errors swallowed, does the README explain setup/run/test, what percent of a baseline ESLint rule set is enabled, what percent of a baseline set of TypeScript compiler checks is enabled, is test coverage at least 80% with the threshold enforced, is the default branch protected from force-push and deletion, do tests wait on real-world time instead of a faked clock, are there change-detector tests, and is the codebase re-implementing something a well-maintained library already solves — and deliver a scorecard report with evidence and exact fixes. Use whenever the user asks to review the code quality of a repo or codebase, asks "is this codebase any good", "what tech debt do we have", "audit our code", "is this maintainable", "what would a senior engineer flag", "grade this repo"; asks about dead code, duplicate code, circular imports, missing tests, missing types, whether strict mode or stricter TypeScript compiler options are on (noUncheckedIndexedAccess, exactOptionalPropertyTypes, noImplicitOverride and the rest), test coverage or a coverage percentage, whether CI runs their tests and linter, branch protection or force-push protection, slow or flaky tests, tests that sleep or wait on real time, brittle or snapshot-heavy tests, unauthenticated endpoints, hand-rolled code for a solved problem ("are we reinventing the wheel", "should this be a library", homegrown crypto, date math, CSV parsing, retry logic), or which eslint rules or tsconfig options they should have on; or wants a due-diligence read on a codebase they are inheriting, acquiring, or taking over. For reviewing one pull request's diff, use auto-reviewer instead.
---

# Repo Code Review

The question is not "is this diff good" (that is `auto-reviewer`, which reviews one PR at a
time). It is: **is this codebase one a team can keep working in, and what would a careful
senior engineer flag on day one?** Twenty-two questions, each with a recommended answer. The
report is a scorecard with evidence a founder can hand to a new engineering lead, or a buyer
can use in technical due diligence.

| # | Question | Recommended |
|---|---|---|
| 1 | Is a **linter and type checker** enabled for this language, and enforced? | Yes |
| 2 | Is there **dead code** anywhere in the repo? | No |
| 3 | If the app has auth, do endpoints correctly require **authentication and authorization**? | Yes |
| 4 | Are there **dead endpoints**? | No |
| 5 | Is there **duplicate code**? | No |
| 6 | Are there **unit tests**? | Yes |
| 7 | Are there **integration tests**? | Yes |
| 8 | Is the module graph **generally a DAG**? | Yes |
| 9 | Are **types** set up? | Yes |
| 10 | Does **CI exist**, and gate every PR on lint, types, unit tests, integration tests and coverage? | Yes — blocking |
| 11 | Are **secrets committed** to the repo? | No |
| 12 | Is a **lockfile committed** and are dependencies audited? | Yes |
| 13 | Are there **oversized files** (over ~1000 lines)? | No |
| 14 | Are **errors swallowed** (empty catch, bare except, ignored `err`)? | No |
| 15 | Does the **README** explain setup, run, and test? | Yes |
| 16 | What percent of the **baseline ESLint rules** are enabled? (TS/JS) | 100% |
| 17 | Is **test coverage** at least 80% on lines and branches, and is the threshold enforced? | Yes |
| 18 | Is the default branch protected from **force-push and deletion**? | Yes |
| 19 | Do tests **wait on real-world time**, or is the clock faked? | Faked — no fixed sleeps |
| 20 | Are there **change-detector tests** (fail on any change, prove nothing)? | No |
| 21 | What percent of the **baseline TypeScript compiler checks** are enabled? (TS) | 100% |
| 22 | Is the codebase **re-implementing what a library solves** (or depending on one for something trivial)? | No |

`references/quality-checklist.md` has, for each question: how to detect it in each language
(with the exact commands), why it matters, what good looks like, and the fix. Questions 3 and 4
have the most detection detail because they are the ones a model gets wrong most often; Q22
carries the longest false-positive list, because it is the one where a confident wrong answer
costs the team a migration.

Two questions are scored against a vendored baseline rather than judged. **Q16** uses
`references/eslint-baseline.config.mjs`, a 105-rule flat config from a production TypeScript
monorepo; nearly every rule in it catches code that compiles, runs, and does something other than
what it reads as. **Q21** uses `references/tsconfig-baseline.json`, 23 compiler checks set by 15
options, the union of what two production TypeScript repos have landed one check at a time.

They are separate questions because tsc and ESLint catch different halves, and a repo is
routinely high on one and low on the other: the compiler sees every file it is pointed at with no
config for a rule to be missing from, but only knows type-level facts; the type-aware lint rules
see intent. Both are N/A for repos with no TypeScript — Q1 and Q9 cover those, and the checklist
names the nearest equivalents for Python, Go, Rust, Ruby and C#. Q16 additionally applies to
JavaScript-only repos; Q21 does not, because a JS repo has no compiler checking anything, which
is a Q9 finding rather than a 0%.

**Read-only by default, always.** Inventory, read, judge, recommend. This skill's entire write
surface is one report file, plus a PR comment or issue if the user asks for one. Never fix code,
reformat, add a config, or run a linter with `--fix` unless the user reads the report and names
what to change.

## Why this skill exists

A model asked "review this codebase" will read a handful of files, say "well-structured, uses
TypeScript, has tests", and miss that `strict` is `false` so the types are decorative, that
`npm test` runs four tests against a mocked client and nothing else, that the linter is
installed but wired to no script and no CI job, that three route files export handlers nobody
mounts, that `/api/admin/export` has no auth check because the middleware is applied to a
sibling router, that the same 40-line invoice calculation exists in four files, and that
`utils/date.ts` adds a month by adding thirty days while `date-fns` sits unused in
`package.json`.

Every one of those is mechanically detectable. The rules below force you to look for each one
explicitly and write down **Yes / No / Partial / Unknown** so nothing is skipped quietly, and
to prefer a command's output over your impression of the code.

## Workflow

Run in order. Load `references/quality-checklist.md` when you reach step 3; load
`references/report-template.md` when you reach step 6.

### 1. Scope and ground rules

- Confirm **which repo and which branch**: `git -C <repo> rev-parse --abbrev-ref HEAD`,
  `git remote get-url origin`, `git log -1 --format='%h %as %an'`. Default to the current
  working directory. Never review a repo the user has not named or implied.
- If the remote is GitHub and `gh` is authenticated, read the repository settings once here —
  they answer Q10 and Q18 and nothing else in the review depends on them:
  `gh api repos/<o>/<r>/branches/<default>/protection`, `gh api repos/<o>/<r>/rulesets`. A `404
  Branch not protected` is itself a finding, not an error to work around.
- Ask, or read from `CLAUDE.md` / `README.md`: what the product is, what is in scope (a
  monorepo may have one package that matters), and **whether the app has authentication at
  all**. Q3 and Q4 are N/A for a library or CLI, and saying so is a real answer.
- If the working tree is dirty, say so in the report — you are reviewing the tree as it is.
- Work in a scratchpad. Any output directory you create goes **outside** the repo, or into
  `.gitignore`'d space. Never leave a report or tool output as untracked clutter in the repo
  unless the user asks for it there.

### 2. Get the shape of the repo before judging any of it

```bash
cd <repo>
git ls-files | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20   # what language is this
git ls-files | wc -l
cloc . 2>/dev/null || git ls-files -z | xargs -0 wc -l | sort -rn | head -30
git log --since=90.days --format=%an | sort -u | wc -l                  # how many people
git log -200 --name-only --format= | grep . | sort | uniq -c | sort -rn | head -15  # hot files
```

Use `git ls-files` rather than `find`, so `node_modules`, `dist`, `.venv` and every other
gitignored tree stay out of every count. Where you must walk the filesystem, exclude
`node_modules dist build .next out coverage .venv venv vendor target __pycache__` explicitly.
Never quote a line count, a duplication figure, or a test count that includes vendored or
generated files — one `node_modules` in the denominator makes every number meaningless.

The numbers you need before step 3: files and lines per language, count of non-test source
files, count of test files, the top-level directory layout, and whether this is a monorepo
(multiple `package.json` / `pyproject.toml` / `go.mod`). Review each package separately when
they differ, and say which package each finding is in.

Then run the inventory, which does the mechanical half of every question in one pass:

```bash
scripts/repo-inventory.sh --repo <repo> --out <scratch dir>     # read-only; --no-analyzers to skip tool runs
```

It writes `DIGEST.md` plus the JSON behind it: the import graph and its cycles (Q8), the
deterministic dead-code pass for Python and TS/JS — unreachable files, unreferenced
definitions, and everything it declined to call dead with the reason (Q2) — every
HTTP endpoint with its visible auth status and whether anything references it (Q3/Q4),
duplicate blocks (Q5), hand-rolled implementations paired against the dependency list (Q22),
test/CI/config/lockfile/secret/big-file/swallowed-error signals, and
the output of whichever analyzers are already installed (`run-analyzers.sh` never installs
anything and never passes `--fix`). Read `DIGEST.md` first. Every line in it is a pointer,
not a verdict: open the file before you cite it. The output directory must be outside the
repo or gitignored.

### 3. Answer the twenty-two questions

Work through `references/quality-checklist.md` in order. For each question write:

```
answer (Yes / No / Partial / Unknown) → evidence (the command and what it printed, or file:line)
→ why it matters for this codebase → recommended state → the exact fix → confidence
```

Rules that keep this honest:

- **Prefer a tool's output to your reading.** Run what is installed (`eslint`, `tsc --noEmit`,
  `mypy`, `ruff check`, `go vet`, `cargo clippy`, `knip`, `vulture`, `jscpd`, `madge
  --circular`, `npm audit`). For Q16 and Q21 the tool output IS the answer, and the config file
  is not: `eslint --print-config <a real .ts file>` and `tsc --showConfig -p <each tsconfig>`
  resolve the presets and the `extends` chain that make a config's text an unreliable read.
  Read-only invocations only: never `--fix`, `--write`, or
  `--unsafe-fixes`. If a tool is not installed, say "not installed, not run" rather than
  guessing what it would say — or run it once from a throwaway location (`npx --yes`, `uvx`)
  if the user is fine with that, and label the result as an ad-hoc run.
- **Count, then cite.** "12 of 47 route handlers have no auth check" beats "auth looks
  inconsistent". Every count needs the command that produced it in the report.
- **Open the file before you claim anything about it.** A grep hit is a lead, not a finding.
- **Unknown is an answer.** Say what access or artifact would have resolved it (production
  access logs, the mobile client's repo, a passing test run).

### 4. Run the test suite with coverage on, don't just count test files

```bash
npm test 2>&1 | tail -30        # or: pytest -q, go test ./..., cargo test, bundle exec rspec
# then the same suite with coverage, for Q17 — the number must be measured, never estimated
npx --no-install vitest run --coverage 2>&1 | tail -20
pytest --cov --cov-branch --cov-report=term-missing -q 2>&1 | tail -25
go test -covermode=atomic -coverprofile=/tmp/c.out ./... >/dev/null 2>&1 && go tool cover -func=/tmp/c.out | tail -1
```

A suite that does not pass on a clean checkout is a finding in its own right, and it caps the
value of Q6, Q7 and Q17 at "tests exist but do not run" — coverage of a failing suite is a
meaningless number. Run unit tests freely; run integration tests only if they need no external
service, no credentials, and no network write — otherwise report them as present but not
executed, and say what they would need. Never run a test suite that seeds or migrates a
database you did not create.

For Q17, record line **and** branch coverage, read the include/exclude list before quoting any
figure, and get per-file numbers so the report can name the lowest-covered files that matter
rather than only the headline percentage. If coverage cannot be produced, the answer is Unknown
with the reason — never an estimate.

While the suite runs, capture what Q19 needs: the wall-clock duration and the slowest tests, from
the runner's own per-test timing. A suite whose slowest tests are all waiting on fixed durations is
the finding, and the seconds are the argument.

### 5. Judge structure with the codebase in front of you

Q2, Q5, Q8 and Q13 are where a model produces noise. Before writing any of them:

- Read the two or three largest non-test files end to end, and the highest-fan-in module. If
  you have not read a file, you cannot say it should be split.
- For every duplicate group, decide whether extracting it is actually an improvement.
  Two similar-looking validators for two different domains are not duplication.
- Open the two or three largest test files and ask what breaks them. A test that has to change
  whenever the implementation changes is Q20's finding, and it is only visible by reading; no tool
  reports it. The git history's lockstep ratio tells you which files to open first.
- Read the repo's utility modules (`utils/`, `lib/`, `helpers/`, `common/`) with Q22 in mind:
  a file that imports nothing and is full of date, string, money or parsing code is where
  reinvention lives. Check the dependency manifest before writing the finding — a library that is
  already installed and going unused is a different, much cheaper finding than one that is not.
- Read `dead-code.py`'s **excluded** list before its findings list: each row says why the pass
  declined to call something dead, and a reason you disagree with is a finding it suppressed.
  If it reported `entry_point_discovery: incomplete`, re-run it with `--entry <the real roots>`
  before quoting a single dead-file number — do not report the suppressed list.
- For every dead-code candidate, check the ways a framework calls code without an import:
  route decorators, DI containers, CLI entry points in `pyproject.toml` /
  `package.json#bin`, Django `settings`, template references, reflection, dynamic
  `importlib` / `require`, and other repos in the org. A public library's exports are its
  product — unreferenced does not mean dead.

### 6. Write the report

Use `references/report-template.md`: summary → scorecard (all twenty-two rows, always) → one
section per question → the top findings ranked by severity → a recommended sequence → method
and caveats. Lead with the worst thing. A "Yes, verified" is one line; do not pad it. A "No"
without a fix, or a fix without the command, is not finished.

Severity, applied consistently:

| Severity | Meaning |
|---|---|
| 🔴 Critical | Live exposure or data loss: an unauthenticated endpoint that reads or writes user data, a committed live credential, hand-rolled crypto / password hashing / JWT verification / HTML sanitization on a live path, no backups of anything the code is the only copy of. |
| 🟠 High | The team will hit this soon and it will hurt: no tests around money or auth, no CI gate, an unprotected default branch anyone can force-push, types disabled, a circular core that makes every change risky. |
| 🟡 Medium | Real maintenance cost: duplication, dead code, oversized files, swallowed errors, missing lint rules. |
| 🟢 Low / Good | Nits, and things that are genuinely fine. Say what is good, but only what is earned. |

## Gating: what may run

```
read files, git log, and analyzers in read-only mode            ──→ default, always fine
   ↓
run the unit test suite                                          ──→ fine
   ↓
run integration tests that need a DB, credentials, or network    ──→ ask first; say what they touch
   ↓
install a tool globally, write into the repo, run --fix,
apply any code change, post a comment, open an issue or PR       ──→ only after the user names it
```

The user reading the report and saying "fix the duplication in the invoice code" authorizes
that change and nothing else. Never batch fixes across questions.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "It's TypeScript, so Q9 is a Yes." | Check `strict` in every `tsconfig*.json`, then count `any` and `@ts-ignore` in non-test code. `strict: false` plus 300 `any`s is a Partial at best. |
| "`strict: true`, so Q21 is a Yes." | `strict` is nine of the twenty-three. The fourteen it leaves off — `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitReturns`, `noImplicitOverride` and the rest — are where the runtime crashes are. Score them. |
| "I read the tsconfig, so I know what's on." | You don't: `extends` pulls options in from a base config or a package, and `strict` expands into nine more, neither visible in the file. Only `tsc --showConfig` resolves both. Never score Q21 off the JSON text. |
| "The root tsconfig is at 23/23." | Score every `tsconfig*.json` separately and headline the *lowest*. A package that does not extend the root inherits nothing from it. |
| "Q21 is 100%, so the compiler is checking the repo." | Only the files in `include`. A config at 23/23 that never sees `tests/` or `scripts/` is 100% of a fraction — compare `tsc --listFiles` against `git ls-files '*.ts'` before quoting the number. |
| "There's an `.eslintrc`, so Q1 is a Yes." | Is it wired to a script, a pre-commit hook, or a CI job? A config nobody runs is not enforced. Run it and count the violations. |
| "There's a `tests/` directory, so Q6 is a Yes." | Count assertions, not files, and run it. Four smoke tests over a 40k-line app is a No. Tests that mock the thing under test are decoration. |
| "The tests pass, so the code is covered." | Coverage is a separate claim. Report it only if you measured it, and name what is uncovered that matters (auth, money, migrations). |
| "These routes have `requireAuth` at the top of the file, so they're protected." | Middleware order, per-route overrides, and sibling routers decide that. Check each route, and check that authZ (is this *your* record) exists, not just authN. |
| "No test references this endpoint, so it's dead." | Mobile apps, other repos, cron, webhooks and external partners are all callers you cannot see. Dead-endpoint findings are *candidates* until traffic logs or the owner confirm. |
| "Same 30 lines in three places — extract a helper." | Check whether the three will change together. Coincidental similarity is not duplication, and a premature shared helper is worse than the copies. |
| "There are circular imports, so the architecture is broken." | Say which cycle and what it costs: broken lazy loading, untestable modules, import-order bugs. A two-file type-only cycle is a nit; a cycle through the core domain is a High. |
| "`git grep` found no callers, so it's dead code." | Frameworks call by convention and config, not imports. Check decorators, DI, entry points, templates, and dynamic imports first. |
| "`dead-code.py` printed 400 unreachable files." | Read its coverage line. Below the floor it suppresses them and tells you a root is missing; above it, a number that large in a live repo still means an unresolved alias or a bundler root. Fix the roots with `--entry`, then re-run. Never paste a suppressed list into the report. |
| "The script found nothing, so Q2 is a Yes." | It answers two mechanical halves for two languages. Commented-out blocks, unreachable branches, dead feature flags, dead dependencies and every other language are still yours — and a repo whose whole graph is entry points has told you nothing. |
| "It's `medium` confidence, so it's probably dead." | Medium means the name appears in no other file. For a public library that is the normal state of its API, and for anything called by string it is wrong. Open the file. |
| "The file is 3000 lines but it's generated / a schema." | Generated and vendored files are out of scope entirely. Exclude them from every count, and say you did. |
| "I'll report duplication as a percentage." | Only if a tool measured it on non-vendored, non-generated code. Otherwise report the groups you found and where. |
| "I couldn't run the linter, so I'll estimate the violations." | Never. "Not installed, not run" is the honest answer. |
| "There's a `tests` job in CI, so Q10 is a Yes." | Check that it is *required* by branch protection, that no `if:`/`paths:` filter skipped it on the last merged PRs, and that the command it runs is the one carrying the coverage gate. A required check whose steps did not execute is green and worthless. |
| "Coverage is 84%, so Q17 is a Yes." | Only with a threshold enforcing it, branch coverage in the same range, and no critical module far below the average. 84% with the auth path at 0% and no gate is a Partial. |
| "There's a coverage badge saying 91%." | Reproduce it or report Unknown. Badges go stale, and they usually report lines on a favourable include list. |
| "The tests use timeouts, so Q19 is a No." | A poll with a deadline returns as soon as the condition holds and costs nothing; a fixed sleep pays every time. Judge the mechanism, not the number, and report the total duration of the fixed ones. |
| "The suite is fast, so Q19 is a Yes." | Or the time-dependent behaviour is not tested at all, which is the same absence wearing a better number. If there is expiry, backoff or scheduling logic and no clock-faking anywhere, say so. |
| "Snapshots are tests, so coverage is real." | A snapshot nobody reads is approved by regenerating it. Report snapshot count and size, and whether the scripts update them as a habit (Q20). |
| "The mock was asserted, so the behaviour is tested." | Verifying an internal collaborator pins the call graph, not the behaviour. Only a boundary you own — a message actually sent — is a real contract. |
| "The branch is protected, so Q18 is a Yes." | Protection and immutability are separate settings. Read `allow_force_pushes`, `allow_deletions`, and whether `enforce_admins` is on or a ruleset has a standing `bypass_actors` entry — in a small team where everyone is an admin, protection without those is decorative. |
| "They wrote their own date/CSV/retry helper, so Q22 is a No." | Check first: does a library for their niche exist, does the runtime now ship it (`crypto.randomUUID`, `structuredClone`, `Intl`, `zoneinfo`), did they try one and remove it, is there a written no-dependency policy, and is the helper a thin wrapper — which is a seam, not a reinvention. |
| "It's only 200 lines, so hand-rolling it was fine." | Line count is the wrong axis. Count the edge cases: 200 lines of CSV splitting is a smaller file and a bigger liability than `import csv`. |
| "They should use the library, so I'll name one." | Not until you check it: last release, maintainers, open issues, licence, transitive deps, bundle size. Swapping working code for an abandoned package with forty transitive dependencies is a worse trade, and a recommendation without that check isn't finished. |
| "Hand-rolled crypto is a Q22 cleanup." | It is a 🔴 security finding that happens to be filed under Q22. Same for JWT verification, OAuth flows and HTML sanitization — those go in "Today", not in the refactor list, and never in a batched cleanup PR. |
| "Their eslint config is long, so Q16 is high." | Length is not coverage. Resolve the effective config with `eslint --print-config` and diff rule names against the baseline — most rules arrive through presets, and a long config can still miss the whole promise group. |
| "The type-aware rules are in their config, so they're on." | Half the baseline needs `projectService`/`project` and installed dependencies. Without them the rules load, match nothing, and look enabled. Check, and report the percentage as nominal if they aren't resolving types. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or
wherever `CLAUDE.md` says analyses live), plus a chat summary that leads with the worst finding
and the scorecard's No count. Offer, and do not assume, the follow-ups: a GitHub issue per
finding, a `plans/` remediation plan, or fixing the top item. Record durable facts in the
project's `CLAUDE.md` — the package layout, which commands lint/type/test the repo, which
tools are installed — so the next review is a re-run, not a rediscovery.

## Reference files

- `scripts/repo-inventory.sh` — runs everything below and builds `DIGEST.md`; step 2.
  `--help` for flags. `scripts/run-analyzers.sh` is the tool-runner half, callable alone.
- `scripts/import-graph.py` — intra-repo import graph for Python and JS/TS, cycles via
  Tarjan SCC, fan-in/fan-out; the mechanical half of Q8.
- `scripts/dead-code.py` — the deterministic half of Q2 for Python (parsed with `ast`) and
  TS/JS: unreachable files, unreachable clusters, code reached only from its own tests,
  definitions referenced nowhere, and an *excluded* list that names why each rule-out was made.
  Reports its own import-graph coverage and suppresses file-level findings below it rather than
  guessing; `--entry` names roots it cannot find, `--fail-on` makes it a CI ratchet. Every other
  language is reported as unanalysed with the tool that does answer for it. `--help` for flags.
- `scripts/find-endpoints.py` — routes for Express/Nest/Next/FastAPI/Flask/Django/Rails/Go/
  Spring/ASP.NET, follows router mounts one file deep for prefix and auth, counts references
  to each path; the mechanical half of Q3 and Q4.
- `scripts/dup-blocks.py` — normalised-window duplicate detector with no dependencies; Q5.
- `scripts/quality-digest.py` — the config/test/CI/secret/type/size/error scans, the eighteen
  hand-rolled-implementation signals paired against the dependency manifest (Q22), and the
  `DIGEST.md` writer. Pure read.
- `references/quality-checklist.md` — the twenty-two questions: what to look at, why each matters,
  what good looks like, and the fix. Deliberately kept above per-language tooling detail: it
  carries the false positives, thresholds and judgment calls, not an ecosystem tutorial. Read
  during step 3.
- `references/eslint-baseline.config.mjs` — the 105-rule baseline Q16 measures against, with the
  reasoning kept on every rule and the wave-adoption method in its header. Read for Q16, and
  hand it to the user as the thing to copy into their repo.
- `references/tsconfig-baseline.json` — the 23 compiler checks (15 options) Q21 measures against:
  the union of what two production TypeScript repos have landed, with the WHY on every option, the
  options deliberately left out and the reason for each, and the same wave-adoption method in its
  header. Read for Q21, and hand it to the user as the thing to copy into their repo. It is a
  valid tsconfig as written — `tsc --showConfig -p` on it prints the 23.
- `references/report-template.md` — the scorecard report skeleton and the per-question
  contract. Read during step 6.
