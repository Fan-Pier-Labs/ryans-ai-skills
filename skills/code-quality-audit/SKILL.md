---
name: code-quality-audit
description: Review a whole repository's code quality against twenty-three concrete questions — is a linter and type checker enabled and enforced, is there dead code, do endpoints require authentication and authorization, are there dead endpoints, is there duplicate code, are there unit tests, are there integration tests, is the module graph a DAG, are types set up, does CI exist and gate every PR on lint, tests, integration tests and coverage, are secrets committed, is the lockfile committed and audited, are files oversized, are errors swallowed, does the README explain setup/run/test, what percent of a baseline ESLint rule set is enabled, what percent of a baseline set of TypeScript compiler checks is enabled, is test coverage at least 80% with the threshold enforced, is the default branch protected from force-push and deletion, do tests wait on real-world time instead of a faked clock, are there change-detector tests, is the codebase re-implementing something a well-maintained library already solves, and is build output, a dependency tree or a cache committed to git — and deliver a scorecard report with evidence and exact fixes. Use whenever the user asks to review the code quality of a repo or codebase, asks "is this codebase any good", "what tech debt do we have", "audit our code", "is this maintainable", "what would a senior engineer flag", "grade this repo"; asks about dead code, duplicate code, circular imports, missing tests, missing types, whether strict mode or stricter TypeScript compiler options are on (noUncheckedIndexedAccess, exactOptionalPropertyTypes, noImplicitOverride and the rest), test coverage or a coverage percentage, whether CI runs their tests and linter, branch protection or force-push protection, slow or flaky tests, tests that sleep or wait on real time, brittle or snapshot-heavy tests, unauthenticated endpoints, hand-rolled code for a solved problem ("are we reinventing the wheel", "should this be a library", homegrown crypto, date math, CSV parsing, retry logic), build artifacts committed to the repo ("are there .pyc files in git", "is node_modules checked in", "why is our repo so big", "is our clone slow", committed `dist/`, `.o`/`.a`/`.class` files, a missing or ignored-too-late `.gitignore`), or which eslint rules or tsconfig options they should have on; or wants a due-diligence read on a codebase they are inheriting, acquiring, or taking over. For reviewing one pull request's diff, use auto-reviewer instead.
---

# Repo Code Review

The question is not "is this diff good" (that is `auto-reviewer`, which reviews one PR at a
time). It is: **is this codebase one a team can keep working in, and what would a careful
senior engineer flag on day one?** Twenty-three questions, each with a recommended answer. The
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
| 23 | Is **build output, a dependency tree or a cache committed** to git (`.pyc`, `node_modules/`, `dist/`, `.o`/`.a`, `target/`)? | No |

`references/quality-checklist.md` has, for each question: how to detect it in each language
(with the exact commands), why it matters, what good looks like, and the fix. Questions 3 and 4
have the most detection detail because they are the ones a model gets wrong most often; Q22
carries the longest false-positive list, because it is the one where a confident wrong answer
costs the team a migration. Q23 is the only question answered on the *unfiltered* file list —
every other count in this review drops `node_modules`, `dist` and `vendor` so its numbers mean
something, and Q23's whole subject is which of those trees git is tracking.

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

The one thing it installs is the analyzers, and only the ones the user approves by name at the
**dependency preflight** (step 2) before anything else runs. On a no, the audit does not run —
it does not run degraded. That gate exists because the alternative is worse than either answer:
an audit that gets four questions in, finds the tool missing, and produces a scorecard of
Unknowns the user cannot act on.

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

Run in order. Load `references/quality-checklist.md` when you reach step 4; load
`references/report-template.md` when you reach step 7.

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

### 2. Dependency preflight — ask once, then install or stop

**Do this before the inventory, and never skip it.** Half the twenty-three questions are answered
by a tool, not by reading: Q2 needs `knip` or `vulture`, Q16 needs the repo's `eslint`, Q21 needs
`tsc`, Q1 needs whatever checks this language. Discovering that mid-run is what turns an audit
into a half-report full of Unknowns.

```bash
scripts/run-analyzers.sh --repo <repo> --out <scratch dir> --check
```

`--check` runs nothing. It prints which analyzers this repo's languages call for, which are
already present, and the exact install command for each missing one — with the one-off
(`npx --yes`, `uvx`) equivalent where there is one.

Then **one message to the user**, listing every missing tool, what each one answers, and the
command. Not one question per tool, and not a question you answer for them:

```
This audit needs 3 tools that aren't installed here:

  knip      → which files and exports are dead (Q2 — nothing else answers this)   npx --yes knip
  eslint    → the Q16 rule-coverage score against the 105-rule baseline           npm i -D eslint
  gitleaks  → secrets in git history (Q11)                                        brew install gitleaks

They run read-only, and the npx/uvx ones install nothing into the repo.
Install these and run the audit? (yes / no)
```

Two paths, and only these two:

- **Yes** → install exactly what was listed, confirm each one runs (`<tool> --version`), then go
  to step 3. Record in the report's method section what was installed and whether it was
  ephemeral or left in the tree.
- **No** → **stop. Do not run the audit.** Name the questions that would have been unanswerable
  and say the offer stands. Never start anyway and fill the gaps with greps, impressions, or a
  column of Unknowns — a scorecard whose evidence column is empty is worse than no scorecard.

Default to the **ephemeral** form (`npx --yes`, `uvx`, `pipx run`): it keeps this skill's
read-only promise, which a `npm i -D` into the user's `package.json` does not. Use the project
install only where the tool must resolve the repo's own dependencies — type-aware ESLint rules
and `tsc` on the project's own TypeScript version — and say in the ask that it touches
`package.json` and the lockfile and is revertable. Never `sudo`, and never a global install
without calling it global. `../shared/dependency-preflight.md` is the full contract.

Tools with a real fallback are worth listing but are not a gate: `jscpd` (`dup-blocks.py` covers
duplication) and `madge` (`import-graph.py` covers cycles). Say which is which in the ask, so a
user can approve the ones that matter and decline the rest — a partial yes is a yes for what they
approved.

### 3. Get the shape of the repo before judging any of it

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

The numbers you need before step 4: files and lines per language, count of non-test source
files, count of test files, the top-level directory layout, and whether this is a monorepo
(multiple `package.json` / `pyproject.toml` / `go.mod`). Review each package separately when
they differ, and say which package each finding is in.

Then run the inventory, which does the mechanical half of every question in one pass:

```bash
scripts/repo-inventory.sh --repo <repo> --out <scratch dir>     # read-only; --no-analyzers to skip tool runs
```

It writes `DIGEST.md` plus the JSON behind it: the import graph and its cycles (Q8), every
HTTP endpoint with its visible auth status and whether anything references it (Q3/Q4),
duplicate blocks (Q5), hand-rolled implementations paired against the dependency list (Q22),
tracked build output, dependency trees and caches with the tracked-but-ignored set called out
separately (Q23), test/CI/config/lockfile/secret/big-file/swallowed-error signals, and
the output of the analyzers step 2 settled (`run-analyzers.sh` itself never installs anything
and never passes `--fix` — the installing happened at the preflight, with the user's yes).
Read `DIGEST.md` first. Every line in it is a pointer,
not a verdict: open the file before you cite it. The output directory must be outside the
repo or gitignored.

### 4. Answer the twenty-three questions

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
  `--unsafe-fixes`. **Q2 is the one question with no acceptable fallback**: the "which files are
  dead" half needs `knip` (TS/JS) or `vulture` (Python), and step 2 is where that was resolved —
  never substitute a grep for it. A tool still missing here means the user declined it by name at
  the preflight: say "declined at preflight, not run", mark what it would have answered Partial or
  Unknown, and leave it there. Never guess what a tool would have said, and never install one now
  that was not in the list the user approved.
- **Count, then cite.** "12 of 47 route handlers have no auth check" beats "auth looks
  inconsistent". Every count needs the command that produced it in the report.
- **Open the file before you claim anything about it.** A grep hit is a lead, not a finding.
- **Unknown is an answer.** Say what access or artifact would have resolved it (production
  access logs, the mobile client's repo, a passing test run).

### 5. Run the test suite with coverage on, don't just count test files

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

### 6. Judge structure with the codebase in front of you

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
- For every dead-code candidate, check the ways a framework calls code without an import:
  route decorators, DI containers, CLI entry points in `pyproject.toml` /
  `package.json#bin`, Django `settings`, template references, reflection, dynamic
  `importlib` / `require`, and other repos in the org. A public library's exports are its
  product — unreferenced does not mean dead.

### 7. Write the report

Use `references/report-template.md`: summary → scorecard (all twenty-three rows, always) → one
section per question → the top findings ranked by severity → a recommended sequence → method
and caveats. Lead with the worst thing. A "Yes, verified" is one line; do not pad it. A "No"
without a fix, or a fix without the command, is not finished.

Severity, applied consistently:

| Severity | Meaning |
|---|---|
| 🔴 Critical | Live exposure or data loss: an unauthenticated endpoint that reads or writes user data, a committed live credential — including one baked into a committed build artifact or `.tfstate` — hand-rolled crypto / password hashing / JWT verification / HTML sanitization on a live path, no backups of anything the code is the only copy of. |
| 🟠 High | The team will hit this soon and it will hurt: no tests around money or auth, no CI gate, an unprotected default branch anyone can force-push, types disabled, a circular core that makes every change risky, a committed artifact that deploys without CI rebuilding it. |
| 🟡 Medium | Real maintenance cost: duplication, dead code, oversized files, swallowed errors, missing lint rules, committed caches and compiled objects. |
| 🟢 Low / Good | Nits, and things that are genuinely fine. Say what is good, but only what is earned. |

## Gating: what may run

```
read files, git log, and analyzers in read-only mode            ──→ default, always fine
   ↓
run the unit test suite                                          ──→ fine
   ↓
install an analyzer ephemerally (npx --yes / uvx / pipx run)     ──→ step 2's yes covers exactly
   ↓                                                                 the tools it listed
install an analyzer into the repo (npm i -D / pip install)       ──→ step 2's yes, and only when
   ↓                                                                 named as touching the lockfile
run integration tests that need a DB, credentials, or network    ──→ ask first; say what they touch
   ↓
install a tool globally, write into the repo, run --fix,
apply any code change, post a comment, open an issue or PR       ──→ only after the user names it
```

The user reading the report and saying "fix the duplication in the invoice code" authorizes
that change and nothing else. Never batch fixes across questions. A yes at the preflight
authorizes the tools on that list and nothing else — not a second tool you wish you had four
questions later, and not the same tool installed a different way.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "It's TypeScript, so Q9 is a Yes." | Check `strict` in every `tsconfig*.json`, then count `any` and `@ts-ignore` in non-test code. `strict: false` plus 300 `any`s is a Partial at best. |
| "`strict: true`, so Q21 is a Yes." | `strict` is nine of the twenty-three baseline checks. The fourteen it leaves off — `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitReturns`, `noImplicitOverride` and the rest — are where the runtime crashes are. Score them. |
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
| "The linter already covers dead code, so Q2 is handled." | It covers the inside of a file. `no-unused-vars` and `noUnusedLocals` are file-local by design and never flag an `export`. The one cross-file rule, `import/no-unused-modules`, is a **no-op on ESLint 10** (the API it needs was removed) and on ESLint 9 flat config only enumerates `.js` — measured, not assumed. Cross-file is knip's job. |
| "knip listed 300 unused files." | Then its `entry` config is wrong, not the repo. A root its plugins cannot see makes everything behind it look unused. Fix `entry` and re-run; never paste that list into a report. |
| "knip is clean, so nothing is dead." | Its default treats test files as entry points, so a module whose only consumer is its own test reads as used. Re-run with tests out of `entry` to surface those — that is dead code with a test attached, and both go in one commit. |
| "vulture is the Python knip." | It is not. vulture matches names, with no import graph, so it answers "is this name used" but never "is this module reachable". The file-level half for Python is yours: walk it from the real entry points and say that you did. |
| "The file is 3000 lines but it's generated / a schema." | Generated and vendored files are out of scope entirely. Exclude them from every count, and say you did. |
| "I'll report duplication as a percentage." | Only if a tool measured it on non-vendored, non-generated code. Otherwise report the groups you found and where. |
| "I couldn't run the linter, so I'll estimate the violations." | Never. "Not installed, not run" is the honest answer. |
| "Most of the tools are here, I'll start and install the rest if I need them." | That is the failure the preflight removes. Run `--check` first, ask once, and let the user decide with the whole list in front of them — a second ask four questions in has already spent their time. |
| "They said no, but I can still do most of it." | No means the audit does not run. A scorecard with the tool-answered questions blank reads as "these are fine" to everyone who sees it later, which is the one outcome worse than no report. |
| "They approved knip, and eslint is the same kind of thing." | It is not. Approval is per-tool and per-install-method. Installing something they did not name — especially into their `package.json` — is the thing that makes the next yes harder to get. |
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
| "`node_modules` is in `.gitignore`, so Q23 is a Yes." | `.gitignore` does nothing to a file git already tracks. That is how almost every one of these lands: `git add -A` first, ignore rule later. `git ls-files -ci --exclude-standard` is the command that finds them, and it is the first thing to run. |
| "`ls` shows no build output, so nothing is committed." | You looked at the working tree. Q23 is about the tracked tree and its history — a 400 MB `node_modules` deleted two years ago is still in every clone. Read `git count-objects -vH` and the biggest blobs across `--all`. |
| "`git rm -r --cached dist` fixes it." | It fixes the future. The bytes stay in history and every clone still downloads them. Only a history rewrite removes them, and that invalidates every clone, fork and open PR — recommend it when `size-pack` is genuinely painful or a live secret is in there, and say so explicitly either way. |
| "They committed the built `dist/`, that's just untidy." | Ask what deploys. If the artifact ships and CI does not rebuild it, nobody can prove the running code matches the source, and an edit made straight to `dist/` survives every review — that is 🟠 High, not a nit. Check it for baked-in keys too; a secret in `main.js` is invisible to every `.env` scan. |
| "`vendor/` is committed, so that's a finding." | Not on its own. Go's `vendor/` is a supported hermetic-build workflow, and PHP and CocoaPods teams commit theirs deliberately. The finding is a vendored tree with no written reason and no CI check that it is in sync — and if it has been *modified*, it is a Q22 unpatched fork as well. |
| "There are generated protobuf stubs in git." | Committing generated code is a real trade: consumers skip the generator toolchain. The finding is drift — no generator config, no CI job regenerating it and failing on a diff, or a source of truth that has moved on. Regenerate and `git diff --exit-code` before writing anything. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or
wherever `CLAUDE.md` says analyses live), plus a chat summary that leads with the worst finding
and the scorecard's No count. Offer, and do not assume, the follow-ups: a GitHub issue per
finding, a `plans/` remediation plan, or fixing the top item. Record durable facts in the
project's `CLAUDE.md` — the package layout, which commands lint/type/test the repo, which
tools are installed — so the next review is a re-run, not a rediscovery.

## Reference files

- `scripts/repo-inventory.sh` — runs everything below and builds `DIGEST.md`; step 3.
  `--help` for flags. `scripts/run-analyzers.sh` is the tool-runner half, callable alone;
  `--check` is its dry-run preflight — nothing executes, it just prints what is present, what is
  missing, and the install command for each — and that is step 2.
- `../shared/dependency-preflight.md` — the ask-once-then-install-or-stop contract this skill
  shares with `sec-ops-audit`, `pr-demo-media`, `dependency-updater` and
  `enable-more-lint-or-ts-checks`: what goes in the ask, ephemeral vs project installs, what to do
  on a failed install, and what a no means. Read during step 2 if anything about the ask is
  unclear.
- `scripts/import-graph.py` — intra-repo import graph for Python and JS/TS, cycles via
  Tarjan SCC, fan-in/fan-out; the mechanical half of Q8.
- `scripts/find-endpoints.py` — routes for Express/Nest/Next/FastAPI/Flask/Django/Rails/Go/
  Spring/ASP.NET, follows router mounts one file deep for prefix and auth, counts references
  to each path; the mechanical half of Q3 and Q4.
- `scripts/dup-blocks.py` — normalised-window duplicate detector with no dependencies; Q5.
- `scripts/quality-digest.py` — the config/test/CI/secret/type/size/error scans, the eighteen
  hand-rolled-implementation signals paired against the dependency manifest (Q22), and the
  `DIGEST.md` writer. Pure read.
- `references/quality-checklist.md` — the twenty-three questions: what to look at, why each matters,
  what good looks like, and the fix. Deliberately kept above per-language tooling detail: it
  carries the false positives, thresholds and judgment calls, not an ecosystem tutorial. Read
  during step 4.
- `references/eslint-baseline.config.mjs` — the 105-rule baseline Q16 measures against, with the
  reasoning kept on every rule and the wave-adoption method in its header. Read for Q16, and
  hand it to the user as the thing to copy into their repo.
- `references/tsconfig-baseline.json` — the 23 compiler checks (15 options) Q21 measures against:
  the union of what two production TypeScript repos have landed, with the WHY on every option, the
  options deliberately left out and the reason for each, and the same wave-adoption method in its
  header. Read for Q21, and hand it to the user as the thing to copy into their repo. It is a
  valid tsconfig as written — `tsc --showConfig -p` on it prints the 23.
- `references/report-template.md` — the scorecard report skeleton and the per-question
  contract. Read during step 7.
