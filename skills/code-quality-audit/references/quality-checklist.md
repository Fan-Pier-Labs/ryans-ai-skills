# Code quality checklist — the sixteen questions, how to answer each, and what "good" looks like

Answer every question with **Yes / No / Partial / Unknown**, the evidence, and the recommended
state. "Unknown, could not verify" is an honest answer and better than a guess; say what would
have let you verify it.

Sources, by trust: a tool's output on non-vendored code → a command you ran (`git grep -c`,
`wc -l`) → reading the file → the config file's claim → what the user told you → your
impression of the code (label these, or leave them out).

**Exclude from every count**: `node_modules`, `vendor`, `dist`, `build`, `out`, `.next`,
`coverage`, `.venv`, `venv`, `target`, `__pycache__`, `Pods`, migrations you did not write,
`*.min.js`, `*-lock.json`, `*.pb.go`, `*_pb2.py`, `*.g.dart`, `*.generated.*`, snapshots.
`git ls-files` already honours `.gitignore`; prefer it to `find`.

Contents: Q1 Lint + type checker · Q2 Dead code · Q3 Endpoint auth · Q4 Dead endpoints ·
Q5 Duplicate code · Q6 Unit tests · Q7 Integration tests · Q8 DAG · Q9 Types · Q10 CI gates ·
Q11 Committed secrets · Q12 Lockfile + audit · Q13 Oversized files · Q14 Swallowed errors ·
Q15 README · Q16 Baseline lint-rule coverage

---

## Q1. Is a linter and type checker enabled, and enforced? (recommended: yes)

This question is about existence and enforcement. **Q16 measures rule-level coverage** against
`eslint-baseline.config.mjs` for TypeScript and JavaScript repos; answer this one first, then
that one.

Three separate claims, and a Yes needs all three: the tool is **configured**, it **passes** (or
its violation count is known), and something **enforces** it — a CI job, a pre-commit hook, or
at minimum a documented script. A config file nobody runs is a No with extra steps.

| Language | Linter | Type checker | Formatter |
|---|---|---|---|
| TypeScript / JavaScript | eslint (`.eslintrc*`, `eslint.config.*`), biome | `tsc --noEmit` + `strict` | prettier, biome |
| Python | ruff, flake8, pylint | mypy, pyright | black, ruff format |
| Go | golangci-lint, `go vet`, staticcheck | the compiler | gofmt |
| Rust | clippy | the compiler | rustfmt |
| Ruby | rubocop | sorbet / RBS (rare; note its absence, don't fail on it) | rubocop |
| Java / Kotlin | checkstyle, spotbugs, PMD, detekt, ktlint | the compiler | spotless |
| C# | Roslyn analyzers via `.editorconfig`, `TreatWarningsAsErrors` | the compiler | dotnet format |
| PHP | phpstan, psalm | phpstan levels | php-cs-fixer |
| Swift | swiftlint | the compiler | swiftformat |

Detect:

```bash
git ls-files | grep -Ei '(eslintrc|eslint\.config|biome\.json|\.?prettierrc|tsconfig.*\.json|mypy\.ini|\.?ruff\.toml|\.flake8|\.?pylintrc|pyrightconfig|\.golangci|clippy\.toml|rustfmt\.toml|\.rubocop|phpstan\.neon|psalm\.xml|\.swiftlint|\.editorconfig|\.pre-commit-config|\.husky)'
grep -nE '\[tool\.(mypy|ruff|black|pylint|pyright|isort)' $(git ls-files 'pyproject.toml' '**/pyproject.toml')
# is it wired to anything?
python3 -c "import json;print(json.load(open('package.json')).get('scripts'))" 2>/dev/null
grep -nE '(lint|typecheck|type-check|format|check)' Makefile justfile tox.ini noxfile.py 2>/dev/null
grep -rnE '(eslint|biome|tsc|mypy|pyright|ruff|flake8|pylint|golangci|clippy|rubocop|phpstan)' .github/workflows/ 2>/dev/null
```

Then **run it read-only** and count:

```bash
npx --no-install eslint . -f unix | tail -3
npx --no-install tsc --noEmit -p tsconfig.json 2>&1 | tail -5
mypy --ignore-missing-imports . 2>&1 | tail -3
ruff check --no-fix --statistics . 2>&1 | tail -20
golangci-lint run --timeout 5m 2>&1 | tail -5 ; go vet ./... 2>&1 | tail -5
cargo clippy --all-targets --quiet -- -D warnings 2>&1 | tail -5
```

Never pass `--fix`, `--write`, `--unsafe-fixes`, or `-w`. If the tool is not installed, say
"not installed, not run" — or run it once with `npx --yes` / `uvx` and label it an ad-hoc run.

What good looks like: linter and type checker configured at the repo root (and in each package
of a monorepo), zero violations on `main`, both wired into a CI job that blocks merge, and a
pre-commit hook so contributors find out before CI does. Rules that matter more than style:
`no-floating-promises`, `no-unused-vars`, `no-explicit-any`, `eqeqeq`, exhaustive-switch,
ruff's `F` (pyflakes) and `B` (bugbear), `errcheck` in golangci-lint.

The fix: add the config for the language's mainstream tool with its recommended preset, run it
once, and **fix or explicitly baseline** the existing violations (`eslint --max-warnings`, ruff
`per-file-ignores`, a `# type: ignore` sweep with a tracking issue) — a linter that reports
4,000 problems on every run teaches the team to ignore it. Then wire it into CI as a blocking
job. Report the violation count as the finding; do not fix them as part of the review.

## Q2. Is there dead code anywhere in the repo? (recommended: no)

Five different things, and they need different evidence:

1. **Unreferenced functions, classes, exports.** Tools first:
   ```bash
   npx --no-install knip --reporter compact        # dead files, exports, deps — best for JS/TS
   npx --no-install ts-prune                        # dead exports only
   vulture . --min-confidence 80 --exclude 'venv,.venv,migrations'   # python
   deadcode ./...                                   # go (golang.org/x/tools/cmd/deadcode)
   cargo machete                                    # rust: unused deps
   ```
   By hand, one symbol at a time: `git grep -nw mySymbol | grep -v '^path/where/defined'`.
2. **Unreferenced files.** A module nothing imports. `knip` finds these; otherwise cross the
   file list against the import graph.
3. **Commented-out code.** Runs of five or more comment lines that are clearly code:
   ```bash
   git grep -nE '^\s*(//|#)\s*(if|for|while|return|def |class |function |const |let |var |import |from |self\.|this\.)' | wc -l
   ```
4. **Unreachable branches**: `if (false)`, code after `return`, a feature flag hard-coded on
   for a year. Linters catch some of this; `grep -rn 'FEATURE_\|_ENABLED = True'` finds flags.
5. **Dead dependencies**: declared, never imported. `knip`, `depcheck`, `cargo machete`,
   `pip-extra-reqs`.

Before calling anything dead, rule out **the ways code gets called without an import**: route
decorators (`@app.get`, `@Controller`), DI containers and autowiring, CLI entry points
(`[project.scripts]`, `package.json#bin`), Django `settings`/`urls`, template and JSX string
references, serializers resolved by name, reflection, dynamic `importlib.import_module` /
`require(variable)`, migration files, test fixtures and `conftest.py`, and **other repos in the
org** that import this one as a library. A public package's exports are its product: for a
library, unreferenced-inside-the-repo means nothing.

Why it matters: dead code is read, maintained, refactored, and security-patched for no return.
It makes every "where is this used" search ambiguous, and it is the main reason a codebase feels
bigger than the product it delivers.

What good looks like: no dead exports reported by the language's tool, `TODO`/`FIXME` count in
the low tens with owners or issue links, no commented-out blocks (git history is the archive).

The fix: delete it. Not comment it out, not `@deprecated` it — delete it, in one commit per
area, with the tool's output in the commit message. If the team is nervous, delete behind one
release of monitoring on the log line that says it was reached.

## Q3. Do endpoints correctly require authentication *and* authorization? (recommended: yes)

N/A for a library, a CLI, or a static site — say so and move on. If the app has users, this is
usually the highest-severity question on the list.

Two distinct checks, and most codebases fail the second:

- **Authentication (authN)** — is the caller logged in? A missing check exposes the endpoint to
  the internet.
- **Authorization (authZ)** — is this caller allowed *this record*? A missing check is an IDOR:
  any logged-in user reads or writes anyone else's data. This one is invisible to route-level
  greps, because the route *is* authenticated.

Step 1, enumerate every route. Pick the patterns for the stack:

```bash
# express / koa / fastify / hono
git grep -nE "\.(get|post|put|patch|delete|all)\(\s*['\"\`]/"
git grep -nE "\.use\(" -- '*.ts' '*.js'          # middleware, and where it is mounted
# nest
git grep -nE '@(Controller|Get|Post|Put|Patch|Delete|UseGuards|Public)\('
# next.js
git ls-files | grep -E '(pages/api/.*\.(ts|js)$|app/.*/route\.(ts|js)$)'
# fastapi / flask
git grep -nE '@\w+\.(get|post|put|patch|delete|route|api_route)\('
git grep -nE '(include_router|register_blueprint|add_middleware|before_request)'
# django / rails
git grep -n 'path(\|re_path(' -- '*urls.py' ; cat config/routes.rb 2>/dev/null
# go / spring / asp.net
git grep -nE '\.(HandleFunc|GET|POST|PUT|PATCH|DELETE)\(|@(Get|Post|Put|Patch|Delete|Request)Mapping\(|\[Http(Get|Post|Put|Patch|Delete)\]'
```

Step 2, for each route, find the authN evidence and classify it:

| Status | Meaning |
|---|---|
| inline | An auth middleware, dependency, guard, or decorator on the route itself. |
| router | Auth applied to the router/blueprint/controller that owns it, or at its mount point. |
| global | App-wide middleware. **Confirm what it excludes** — every global auth has a public allowlist, and that allowlist is where the bugs are. |
| expected-public | Health, metrics, login, signup, OAuth callback, webhooks, static. Public by design. |
| none-seen | Nothing auth-looking anywhere on the path. Each of these is a finding until proven otherwise. |

The traps, in the order they bite:

- **Middleware order.** In express, `app.get('/x', h)` registered *before* `app.use(requireAuth)`
  is not protected. Read the file top to bottom, not with grep alone.
- **Mount-point auth.** `app.use('/api/users', requireAuth, usersRouter)` protects every route
  in `usersRouter`, which lives in another file with no auth token in sight. Follow the mount.
- **The allowlist in a global check.** `if (PUBLIC_PATHS.some(p => url.startsWith(p)))` plus a
  `PUBLIC_PATHS` entry of `/api/user` silently opens `/api/users/…`. Read prefix matches
  adversarially.
- **Guard registered but never applied**, or `@Public()` left on after a refactor.
- **Two apps, one auth.** A second server, a Lambda, a worker HTTP port, an admin app on
  another port — each needs its own answer.

Step 3, authZ. For every route that takes a resource id, find the ownership check:

```bash
git grep -nE '(findById|findUnique|findOne|get_object_or_404|objects\.get|\.query\(.*\bid\b|SELECT .* WHERE id)' 
```

For each hit, does the query or the code after it constrain by the caller — `where: { id,
userId: session.user.id }`, `.filter(owner=request.user)`, an explicit `if (row.userId !==
me.id) return 403`, or a policy/permission object? A fetch by id alone, returned to the caller,
is an IDOR. Also check: role checks on admin routes (`role === 'admin'`, `@Roles('admin')`),
mass-assignment (`update(req.body)` letting a caller set `role` or `isAdmin`), and tenant
isolation in anything multi-tenant (`orgId` in every query, not just the first one).

Step 4, the adjacent things you will find here and should report: CSRF protection on
cookie-authenticated mutations, secrets compared with `==` instead of a constant-time compare,
webhook signature verification (Stripe, GitHub) present and actually failing closed, JWTs
verified with a real secret and `algorithms` pinned (not `verify: false`, not `none`), rate
limiting on login and password reset, and CORS not set to reflect any origin with credentials.

What good looks like: auth is **deny by default** — one global middleware or router-level guard
with a short, explicitly reviewed public allowlist, so a new route is protected unless someone
opts out. Authorization lives in one place (a policy layer, or a row-level-security predicate
in every query), not re-implemented per handler. A test exists that calls a protected endpoint
with no token and with another user's token, and expects 401 and 403.

The fix: for each unauthenticated route, either add the guard or add it to a documented public
allowlist, in one PR that also inverts the default if it is currently opt-in. For IDORs, scope
the query by the caller rather than adding a post-fetch `if` — a scoped query cannot be
forgotten in the next handler. Report every finding with method, path, file:line, what an
attacker gets, and the one-line fix. Sort by what the endpoint exposes, not by how many there
are.

## Q4. Are there dead endpoints? (recommended: no)

A route that exists, is served, and nothing calls. Each is attack surface, maintenance, and a
false constraint on refactoring ("we can't change that shape, something might use it").

Detect, per route path, whether anything in the repo references it:

```bash
git grep -nF '/api/users/me' -- . ':!*test*' ':!*spec*'   # prod references
git grep -nF '/api/users/me'                              # any reference, tests included
```

Parameterised paths need the static prefix plus a wildcard segment, and a client calling
`` `${BASE}/users/${id}/posts` `` will only match on `/users/`. Check the generated client, the
OpenAPI spec, and the frontend's api module before concluding anything.

Ranked evidence that a route is actually dead:

1. **Traffic.** The only real proof. Access logs, CloudWatch/ALB metrics per path, APM
   (Datadog, Sentry performance), or an analytics tool, over at least 30 days — ask the user
   for it. Zero hits in 30 days on a route with no scheduled caller is a dead endpoint.
2. **No reference anywhere in the repo** including the generated client and the spec.
3. **Referenced only by its own tests** — a common shape for a route whose feature was cut.
4. **Superseded**: `/api/v1/x` next to `/api/v2/x`, `legacy` or `old` in the path, a handler
   whose body is `res.status(410)` or returns a hard-coded stub.

The callers you cannot see from the repo, and must ask about: mobile app versions still in the
field, other repos and services in the org, partner integrations and webhooks pointed at you,
cron jobs and schedulers, Zapier/Retool/internal tools, and bookmarked admin URLs. A route with
no repo references and no traffic data is a **candidate**, and the report must say so.

What good looks like: every route is reachable from a known caller, versioned paths are retired
on a schedule, and removal follows a deprecation: log every call with the caller's identity for
30 days → announce → return 410 for 30 days → delete.

The fix: for each candidate, the sequence above. Never delete a route on repo-grep evidence
alone; the 410 window is what makes it safe.

## Q5. Is there duplicate code? (recommended: no)

```bash
npx --no-install jscpd --min-tokens 50 --reporters console --ignore '**/node_modules/**,**/dist/**' .
pylint --disable=all --enable=duplicate-code --min-similarity-lines=8 --recursive=y .
# no tool installed: normalised-line frequency finds the worst offenders
git ls-files '*.py' '*.ts' '*.js' '*.go' | xargs awk 'NF && $0 !~ /^[[:space:]]*([#/*]|$)/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"");print}' | sort | uniq -c | sort -rn | head -40
```

Also look for the duplication tools miss because the text differs: the same **business rule**
in three places (tax, pricing, permission, retry, date-window logic), the same constant
re-declared, parallel `if type == …` ladders that must be edited together, a validation schema
duplicated between client and server, and near-copies that drifted — where the fix is not
extraction but deciding which copy is correct.

Judge each group before reporting it. Duplication is a problem when the copies **must change
together**; when they represent two domains that merely look alike today, a shared helper
couples them and is the worse outcome. Test setup duplication is usually fine, and sometimes
better than a fixture nobody can follow. Say which groups you judged not worth extracting — it
shows the review was more than a tool run.

What good looks like: no group of eight or more lines repeated across files; one canonical
helper per concept, with the name a new engineer would guess; a shared types/schema package
where client and server must agree.

The fix, per group: name the concept, put it in the module that owns the domain (not a
`utils.ts` grab bag), replace every copy, and add one test for the extracted unit. Start with
the group whose copies have already drifted — that one is a latent bug, not just debt.

## Q6. Are there unit tests? (recommended: yes)

```bash
git ls-files | grep -cE '(^|/)(tests?|spec|__tests__)/|[._-](test|spec)\.|(^|/)test_[^/]*\.py$|_test\.go$'
git ls-files | grep -vcE '(^|/)(tests?|spec|__tests__)/|[._-](test|spec)\.|_test\.go$'   # source files
git grep -cE '\b(it|test|describe)\(|\bdef test_|func Test[A-Z]|\bit ['\"]' -- <test paths> | tail -1
npm test 2>&1 | tail -20     # or pytest -q / go test ./... / cargo test / bundle exec rspec
```

A Yes needs: tests exist, they **run and pass on a clean checkout**, and they cover the code
where a bug costs something. The shape matters more than the count:

- Do they test **behaviour or the mock**? A test that mocks the database, the HTTP client and
  the clock, then asserts the mock was called, passes forever regardless of the code.
- Is the **money / auth / migration / permission** logic tested? That is where the value is.
- Are there **edge cases and failure paths**, or only the happy path?
- Are they **deterministic** — no `sleep`, no real clock, no shared mutable fixture, no order
  dependence? Check for `.skip`, `.only`, `xit`, `@pytest.mark.skip`, `t.Skip` and count them;
  a suite with 40 skipped tests is a suite with 40 known-broken tests.
- Coverage: report it only if you measured it (`npm test -- --coverage`, `pytest --cov`,
  `go test -cover ./...`), and name what is uncovered that matters rather than the headline
  percentage.

What good looks like: the suite runs in under a couple of minutes, passes on a clean checkout
with one documented command, covers every non-trivial branch of the domain logic, and fails
loudly when behaviour changes. Ratio of test files to source files somewhere in the 0.3–1.0
range is typical of a healthy repo; well outside it in either direction is worth a sentence.

The fix, in this order: get the suite green and in CI (a red suite is worse than none, because
it trains the team to ignore failures), then write tests for the next bug you fix rather than
retrofitting coverage broadly, starting with auth, money, and anything with a `TODO` near it.

## Q7. Are there integration tests? (recommended: yes)

Unit tests with everything mocked cannot tell you the app boots, the routes are mounted, the
query compiles, the migration applies, or the auth middleware is wired. That is this question.

```bash
git grep -lE 'supertest|TestClient\(|AsyncClient\(|testcontainers|@playwright/test|cypress|selenium|MockMvc|@SpringBootTest|rack/test|capybara|httptest\.NewServer|WebApplicationFactory'
git ls-files | grep -iE '(^|/)(integration|e2e|acceptance|functional|system)/|\.(int|integration|e2e)\.'
git grep -rn 'services:' docker-compose*.y*ml 2>/dev/null      # what the suite can stand up
grep -rnE 'pytest\.mark\.(integration|e2e)|describe\(.?e2e' . 2>/dev/null | head
```

The tiers, and what each buys:

| Tier | Shape | Buys you |
|---|---|---|
| API / service | Real app object, real router, real DB (testcontainers, sqlite, a scratch schema); HTTP client hitting it | Routes mounted, auth wired, queries compile, serialisation correct |
| Contract | Provider verifies a consumer's expectations (pact), or the OpenAPI spec is validated against responses | Clients don't break silently |
| E2E / browser | Playwright or Cypress against a running stack | The critical user journey works end to end |

Do not run these against anything shared. Run them only if they stand up their own dependencies
(testcontainers, docker compose, an in-memory DB) and need no credentials and no network write;
otherwise report them as present-but-not-executed and say what they need. Never point a test
suite at a database you did not create.

What good looks like: at least one test that boots the real app and exercises the critical path
end to end against a real database — signup → login → the one thing the product does → the one
thing that takes money. Plus one 401/403 test per auth mode. Three good integration tests are
worth a hundred mocked unit tests for the failures that actually reach production.

The fix: start with one. `supertest`/`TestClient` against the app object with a containerised
database, covering login plus the main flow, wired into CI. Name the flow in the report.

## Q8. Is the module graph generally a DAG? (recommended: yes)

"Generally" is the right word: the test is not academic acyclicity, it is whether dependencies
point one direction so a change has a bounded blast radius.

```bash
npx --no-install madge --circular --extensions ts,tsx,js,jsx src
pylint --disable=all --enable=cyclic-import --recursive=y .
lint-imports                     # python, if importlinter contracts exist
go list -json ./... | grep -c ImportCycle   # Go and Rust reject cycles at compile time — Q8 is structurally a Yes there
```

Two findings live here, and the second matters more:

1. **Cycles.** Report each cycle with its files and what it costs: broken lazy initialisation,
   `ImportError` on reordering, a module that cannot be imported or tested alone, bundlers
   emitting `undefined` for a partially-initialised export. A two-file type-only cycle is a
   nit; a cycle through the core domain is High.
2. **Layer violations.** Even with no cycles, does the dependency direction make sense? Draw
   the layers the repo implies — routes/controllers → services/domain → data access →
   infrastructure — then check the arrows:
   ```bash
   git grep -nE "from ['\"].*(routes|controllers|views|api)/" -- 'src/domain/*' 'src/services/*' 'app/models/*'
   git grep -nE "from ['\"].*(models|db|prisma|sqlalchemy)" -- 'src/routes/*' 'src/controllers/*'
   ```
   Domain importing HTTP, models importing views, a shared `utils` that imports half the app,
   or a "god module" everything imports and which imports everything back — each is the thing
   that makes the codebase feel like it cannot be changed safely.

Also worth one line each: fan-in (what everything depends on — that file needs the best tests)
and fan-out (a module importing 30 others is doing too much).

What good looks like: no cycles, or a handful of type-only ones; a dependency direction you can
state in one sentence and check mechanically; enforcement — eslint `import/no-cycle`,
`import-linter` contracts, `depguard` in golangci-lint — so it stays true.

The fix, per cycle: find which direction is wrong and invert it. The three moves that resolve
almost every cycle are extracting the shared types into a leaf module, dependency inversion
(the lower layer defines an interface the higher layer implements), and moving the shared
function into the module that owns the concept. Then add the lint rule so the cycle cannot come
back. Type-only cycles in TypeScript are fixed by `import type` alone.

## Q9. Are types set up? (recommended: yes)

Not "is the language typed" — is the type system **on, strict, and honest**?

```bash
# TypeScript: strictness per config, and how often it is escaped
git ls-files '*tsconfig*.json' | xargs grep -nE '"(strict|noImplicitAny|strictNullChecks|noUncheckedIndexedAccess)"'
git grep -cE '(^|[^\w$])any([^\w$]|$)' -- '*.ts' '*.tsx' ':!*test*' | tail -1
git grep -c '@ts-\(ignore\|nocheck\|expect-error\)' -- '*.ts' '*.tsx' | tail -1
git ls-files '*.js' '*.jsx' | wc -l        # untyped islands in a TS repo
# Python: annotation coverage and escapes
git grep -cE '^\s*(async )?def ' -- '*.py' ':!*test*' | tail -1
git grep -cE '^\s*(async )?def \w+\([^)]*\)\s*->' -- '*.py' ':!*test*' | tail -1
git grep -c '# type: ignore' -- '*.py' | tail -1
grep -nE 'strict|disallow_untyped_defs|ignore_errors|follow_imports' mypy.ini setup.cfg pyproject.toml 2>/dev/null
```

The questions behind the numbers:

- Is `strict` true (or mypy `disallow_untyped_defs` / pyright `strict`), and in **every**
  package of the monorepo? One `"strict": false` in a leaf config is where the bugs live.
- Is the checker run in CI (Q10) or only in the editor?
- Are the **boundaries** typed: request/response bodies, database rows, external API
  responses, environment variables? Types matter most where data enters the process, and that
  is exactly where `any`, `dict[str, Any]`, `interface{}`, and `JSON.parse` land.
- Is validation **runtime** at those boundaries (zod, pydantic, io-ts, serde), or does the code
  cast and hope? A compile-time type on parsed JSON is a comment, not a check.
- Is typing used to make illegal states unrepresentable — discriminated unions over
  `status: string`, branded ids over bare `string`, `Result`/`Either` over throwing — or is
  everything `Record<string, unknown>` with casts at every use?
- In Go/Rust/Java/C#, the language answers the basic question; the real findings are
  `interface{}`/`any`/`Object` in hot paths, `unsafe`, nullable-reference warnings disabled, or
  `dynamic`.

What good looks like: strict mode on everywhere, the checker blocking in CI, zero `any` in
non-test code without a comment saying why, runtime validation at every boundary feeding typed
models inward, and no untyped islands.

The fix: turn strictness on **per directory**, not repo-wide in one PR — `strict: true` with an
`include` list that grows, or mypy's per-module `disallow_untyped_defs`. Fix boundaries first
(the API layer and the DB layer), since that is where types prevent real bugs. Get the CI gate
in before the backlog is finished, so new code cannot add to it.

## Q10. Does CI gate every PR on lint, types, and tests? (recommended: yes, blocking)

```bash
git ls-files .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile azure-pipelines.yml
grep -nE '^\s*(on|jobs|steps)|pull_request|eslint|tsc|mypy|ruff|test|audit' .github/workflows/*.y*ml
gh api repos/{owner}/{repo}/branches/main/protection 2>/dev/null   # is it required, or advisory?
gh pr list --state merged --limit 20 --json number,statusCheckRollup  # did checks actually run?
```

A Yes needs: a workflow that triggers **on pull_request**, runs lint + type check + tests, and
is **required** by branch protection so a red check blocks merge. A workflow that only runs on
push to `main`, or that exists but is not required, is a Partial — it tells you after the fact.
Check that it runs on the whole repo, not one package of a monorepo, and that it is not
`continue-on-error: true`.

Also record: Dependabot or Renovate present, a dependency/vulnerability scan
(`npm audit`, `pip-audit`, `govulncheck`, CodeQL, semgrep, trivy), and whether the suite is fast
enough that people do not routinely merge past it (over ~15 minutes and they will).

What good looks like: one required workflow per package, under ten minutes, running lint, types,
unit tests and a fast integration tier on every PR, with branch protection requiring it and at
least one review.

The fix: the minimal blocking workflow is a dozen lines — checkout, install with the lockfile,
`lint`, `typecheck`, `test` — then mark it required in branch protection. If the suite is red
today, gate on lint and types first and add tests to the gate the day they pass.

## Q11. Are secrets committed to the repo? (recommended: no)

```bash
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '\.(example|sample|template|dist)$'
git grep -nE 'AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|xox[abpr]-|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.eyJ'
git grep -nEi '(password|secret|api_?key|access_?token|private_?key)\s*[:=]\s*["'"'"'][^"'"'"'[:space:]]{8,}'
git grep -nE '(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^:/[:space:]]+:[^@/[:space:]]{4,}@'
gitleaks detect --source . --redact --no-banner   # also scans history, if installed
grep -nE '^\s*\.env' .gitignore
```

Filter the false positives — `example`, `changeme`, `your-key-here`, `xxx`, `process.env`,
`os.environ`, `<placeholder>`, test fixtures, and hashed values — and **never print a real
secret in the report**: name the file, the line, and the kind, redacted to a prefix.

Two things that change the severity: is the credential **live** (ask; a test key is Medium, a
live key is Critical), and is it **in history** even if deleted from `HEAD`
(`git log -p -S '<fragment>' --all`) — if the repo was ever public or has ever been cloned by
someone who left, treat it as disclosed. A secret in history is not fixed by a commit that
deletes it.

What good looks like: no secrets in the tree or history; `.env` gitignored with a committed
`.env.example` listing the names only; real values in a secret manager or the platform's env
config; a pre-commit secret scanner or GitHub push protection so the next one never lands.

The fix, in order: **rotate first** (the credential is compromised the moment it is committed —
naming the consumers before rotating is the part people skip and it is what breaks production),
then remove from the tree, then decide about history rewriting (`git filter-repo`, coordinated
with everyone who has a clone), then add the scanner. Report it in exactly that order.

## Q12. Is a lockfile committed and are dependencies audited? (recommended: yes)

```bash
git ls-files | grep -E '(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|Cargo\.lock|go\.sum|Gemfile\.lock|composer\.lock)'
grep -cE '==' requirements.txt 2>/dev/null ; wc -l < requirements.txt 2>/dev/null
npm audit --audit-level=high 2>&1 | tail -15
pip-audit -r requirements.txt --progress-spinner off 2>&1 | tail -15
govulncheck ./... 2>&1 | tail -15 ; cargo audit 2>&1 | tail -15
npm outdated 2>/dev/null | head -20
```

A manifest with no lockfile means two developers and CI resolve different versions, and a
"works on my machine" bug nobody can reproduce. `requirements.txt` with `>=` and no lock is the
same problem. An application commits its lockfile; a **library** does not commit one for
consumers but should still lock its CI.

Report: lockfile present per package, audit findings at high/critical with the fix version,
anything a major version or more behind on a security-relevant dependency (framework, auth,
crypto, serialisation), and whether Dependabot/Renovate is on. Do not report the full
`npm outdated` table; report the ones that matter and the count of the rest.

What good looks like: lockfile committed and CI installing from it (`npm ci`, `poetry install
--sync`, `uv sync --frozen`), zero unfixed high/critical advisories, Renovate or Dependabot
opening grouped PRs, and a CI audit step.

The fix: commit the lockfile, switch CI to the frozen install, resolve high/critical advisories
(`npm audit fix` without `--force` first, then the majors by hand), and turn on automated
updates so this does not recur. `dependency-updater` in this repo does the recurring part.

## Q13. Are there oversized files? (recommended: none over ~1000 lines)

```bash
git ls-files -z '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.go' '*.rb' '*.java' '*.rs' '*.cs' \
  | xargs -0 wc -l | sort -rn | head -25
```

Exclude generated files, schemas, migrations, lockfiles, and vendored code — then judge what is
left. 1000 lines is a threshold, not a rule: what matters is whether the file has one job. A
1200-line file that is 60 small pure functions on one topic is fine; a 600-line React component
holding fetching, state, validation and layout is not. Check the hot-files list from step 2 —
a huge file that changes every week is the expensive one; a huge file nobody has touched in two
years is mostly harmless.

The related smells worth a line: a function over ~80 lines, cyclomatic complexity nobody can
hold in their head (nested conditionals four deep), a `utils.ts` / `helpers.py` that is a
grab bag, and files that multiple people must edit for any feature (merge-conflict magnets —
visible in `git log --name-only` co-occurrence).

What good looks like: files named for one responsibility, most under 400 lines, no file over
1000 that is not generated, and a lint rule (`max-lines`, `max-lines-per-function`) holding the
line for new code.

The fix, for the worst two or three only: name the responsibilities inside the file, extract
each into a module with the existing tests still passing, and do it as a pure move with no
behaviour change so the diff is reviewable. Do not recommend splitting every large file — pick
the ones that change often.

## Q14. Are errors swallowed? (recommended: no)

```bash
git grep -nE 'catch\s*(\([^)]*\))?\s*\{\s*\}' -- '*.ts' '*.tsx' '*.js' '*.java' '*.cs' '*.php'
git grep -nE '\.catch\(\s*\(?\w*\)?\s*=>\s*(\{\s*\}|null|undefined)\s*\)'
git grep -nE '^\s*except\s*:' -- '*.py'
git grep -nA1 -E '^\s*except\b.*:' -- '*.py' | grep -B1 -E '^\s*(pass|\.\.\.|return None|continue)\s*$'
git grep -nE 'rescue\s*(=>\s*\w+)?\s*$' -A1 -- '*.rb' | grep -B1 -E '^\s*(nil|end)'
git grep -nE '^\s*_\s*(,\s*_)*\s*:?=' -- '*.go'          # discarded error returns
git grep -nE '\.unwrap\(\)|\.expect\(' -- '*.rs' ':!*test*'
```

Then read each hit and classify it, because the pattern alone does not say which:

- **Deliberate and documented** — a comment explaining why the failure is safe to ignore, and
  the code does something sensible after. Fine. Say so.
- **Swallowed** — the error disappears with no log, no metric, no rethrow. The bug becomes
  "nothing happened and nobody knows why". This is the finding.
- **Swallowed in a critical path** — payment, auth, data write, migration. High severity: the
  system reports success while having failed.

Nearby and worth reporting together: logging an error and continuing as if it succeeded,
`console.error` as the only handling in a server process, `catch` that converts every failure
into a 200, retry loops with no ceiling and no backoff, and errors caught so broadly that
programming bugs (`TypeError`) are handled as expected conditions.

What good looks like: failures propagate to a boundary that decides what to do; every caught
error is logged with context or converted into a typed domain error; one error-reporting sink
(Sentry or equivalent) actually receiving events; and a lint rule enforcing it — eslint
`no-empty`, `@typescript-eslint/no-floating-promises`, ruff `BLE`/`E722`, `errcheck` in
golangci-lint, clippy's `unwrap_used`.

The fix: per hit, either log with context and rethrow, or narrow the `except`/`catch` to the
specific error the code can actually handle and comment why. Then turn on the lint rule so new
ones cannot land, and report the count you had to baseline.

## Q15. Does the README explain setup, run, and test? (recommended: yes)

```bash
ls README* CONTRIBUTING* CLAUDE.md docs/ 2>/dev/null
grep -niE 'install|prerequisite|\.env|environment|docker|npm run|make |test|architecture' README.md | head -20
```

The test is not length, it is whether **a new engineer can get from clone to a passing test run
and a running app** using only what is written. Check for: prerequisites with versions, install,
required environment variables (and a committed `.env.example` to match), the run command, the
test command, and how to run migrations or seed data. Then look for the gap that makes this a
No in practice: commands that no longer exist in `package.json`, a Python version the lockfile
contradicts, or a missing "you also need Postgres and Redis running".

Worth one line each: an architecture or directory overview for anything over a few thousand
lines, a `CLAUDE.md` for agent sessions, and ADRs or `docs/` for decisions that would otherwise
be re-litigated.

What good looks like: clone → documented install → documented test command → green, with no
tribal knowledge. Ideally verified by CI running the same commands the README lists, so they
cannot rot.

The fix: write the five sections by actually following them on a clean clone, and fix what
breaks. This is the cheapest fix on the whole list and the one that pays back on every new hire
and every agent session.

## Q16. What percent of the baseline lint rules are enabled? (recommended: 100%)

Q1 asks whether a linter exists and is enforced. This question asks whether it is configured to
catch anything. A repo can pass Q1 with `eslint:recommended` and still miss every rule in
`eslint-baseline.config.mjs` — 105 rules, almost all of which catch code that compiles, runs,
and does something other than what it reads as.

**TypeScript / JavaScript only.** For other languages this is N/A and Q1 carries the weight;
note the nearest equivalent and whether it is on: ruff's `F`, `B`, `BLE`, `SIM`, `RET`, `ASYNC`
families (and `ALL` minus an explicit ignore list) for Python; `golangci-lint` with `errcheck`,
`govet`, `staticcheck`, `bodyclose`, `contextcheck`, `nilerr` for Go; clippy's `pedantic` for
Rust; rubocop's default cops for Ruby.

### Measuring it

The baseline is `references/eslint-baseline.config.mjs`. Compare it against the **effective**
config of the repo under review, not the text of its config file — most rules arrive through
presets like `tseslint.configs.recommended`, and only `--print-config` resolves those:

```bash
cd <repo>
npx --no-install eslint --print-config src/index.ts > /tmp/effective.json   # any real .ts file
```

Then compute coverage:

```bash
python3 - <<'PY'
import json, re, sys
BASELINE = "<path to>/references/eslint-baseline.config.mjs"
pairs = re.findall(r'^\s{6,}"([@a-z][\w@/-]*)"\s*:\s*("off"|"error"|"warn"|\[)',
                   open(BASELINE).read(), re.M)
want = {n for n, v in pairs if v != '"off"'}                    # 105 rules
eff = json.load(open("/tmp/effective.json")).get("rules", {})
def level(v):
    v = v[0] if isinstance(v, list) else v
    return {0: "off", 1: "warn", 2: "error"}.get(v, v)
on    = {r for r in want if level(eff.get(r, "off")) == "error"}
warn  = {r for r in want if level(eff.get(r, "off")) == "warn"}
missing = sorted(want - on - warn)
print(f"{len(on)}/{len(want)} as error = {100*len(on)//len(want)}%  (+{len(warn)} as warn)")
for r in missing:
    print("  missing:", r)
PY
```

Report the percentage, the count as `error` versus `warn`, and the missing rules **grouped**,
not as a flat list of 80 names. The useful grouping is by what the rule catches (41 of the 105
fall into these seven groups; the remaining 64 are individually smaller wins):

| Group (count) | Rules | Why the group matters |
|---|---|---|
| Floating / misused promises (7) | `no-floating-promises`, `no-misused-promises`, `await-thenable`, `require-await`, `return-await`, `no-async-promise-executor`, `no-promise-executor-return` | An unawaited promise loses its rejection; the failure surfaces as "nothing happened" |
| Silent wrong behaviour (8) | `require-array-sort-compare`, `array-callback-return`, `no-for-in-array`, `no-base-to-string`, `no-misused-spread`, `no-unsafe-enum-comparison`, `restrict-plus-operands`, `no-template-curly-in-string` | Compiles, runs, produces the wrong value |
| Error handling (4) | `only-throw-error`, `prefer-promise-reject-errors`, `use-unknown-in-catch-callback-variable`, `no-unsafe-unary-minus` | Ties into Q14 |
| Injection / legacy APIs (11) | `no-eval`, `no-new-func`, `no-implied-eval`, `no-script-url`, `no-proto`, `no-caller`, `no-extend-native`, `no-iterator`, `no-new-wrappers`, `no-new-native-nonconstructor`, `no-multi-str` | Usually zero violations, so free to adopt |
| Module graph (5) | `import-x/no-cycle`, `no-self-import`, `no-mutable-exports`, `no-import-type-side-effects`, `consistent-type-imports` | The enforcement half of Q8 |
| React correctness (2) | `react-hooks/rules-of-hooks`, `exhaustive-deps` | Nothing else in the toolchain sees these |
| Type honesty (4) | `no-explicit-any`, `no-unnecessary-type-assertion`, `no-unsafe-function-type`, `no-invalid-void-type` | Ties into Q9 |

Two things that change the answer and must be checked before you report a number:

- **Type-aware rules need working type information.** Roughly half the baseline requires
  `parserOptions.projectService` (or `project`) and every package's dependencies installed.
  Without them the rules load, report nothing, and look enabled. If `--print-config` shows them
  on but the repo lints with no `projectService` and no `project`, report the percentage as
  nominal and say the type-aware half is not actually running.
- **A rule set nobody runs is still 0%.** Cross-reference Q1 and Q10: coverage means nothing if
  lint is not wired to CI. Report both numbers together — "88% of the baseline enabled, but the
  lint job is not required by branch protection" is the honest finding.

Do not count a rule as covered because the repo has "something similar". `no-unused-vars`
without `caughtErrorsIgnorePattern`, or `prefer-nullish-coalescing` without the
`ignorePrimitives` narrowing, are different rules in practice. Where the repo's option object
differs from the baseline's, list it as a configuration difference rather than as missing, and
say which behaviour the difference changes.

### What good looks like

100% of the baseline enabled as `error`, type-aware rules actually resolving types, the whole
set green, and the lint job required by branch protection. Below 100%, what matters is which
rules are missing: a repo missing the promise group has a class of production bug it cannot see,
while a repo missing `prefer-object-has-own` has a style gap.

### The fix

Copy `eslint-baseline.config.mjs` into the repo and adopt it in waves, exactly as the header of
that file describes: turn each candidate rule on alone, count, commit every zero-violation rule
immediately as a ratchet (canary-verifying each zero, because a rule that silently matches
nothing looks identical to a clean repo), then fix the rest one rule per PR, smallest count
first. Do not open a single PR that enables 105 rules — it will report thousands of violations
and be closed. Report the wave plan with the measured violation count per missing rule if you
have it, since that count is what makes the plan credible.

The five places marked `ADAPT:` in the baseline need the repo's own paths (ignores, test globs,
the import-cycle scope, the React globs). The entries marked `DECISION:` are deliberate
narrowings with the reasoning attached — a repo that has narrowed them differently for a stated
reason is fine, and a repo that has silently dropped them is not.
