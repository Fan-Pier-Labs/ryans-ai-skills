# Code quality checklist — the twenty-two questions, how to answer each, and what "good" looks like

Answer every question with **Yes / No / Partial / Unknown**, the evidence, and the recommended
state. "Unknown, could not verify" is an honest answer and better than a guess; say what would
have let you verify it.

Sources, by trust: a tool's output on non-vendored code → a command you ran (`git grep -c`,
`wc -l`) → reading the file → the config file's claim → what the user told you → your
impression of the code (label these, or leave them out).

**Altitude.** You already know each language's linters, test runners, coverage tools and clock
libraries; this file does not re-teach them. It carries what is easy to get wrong instead: which
patterns are false positives, where the honest threshold sits, what a number has to exclude before
it means anything, and which findings are candidates rather than verdicts. Where a command appears
it is because the exact flag or API field matters, not as a substitute for knowing the ecosystem.
Reach for the tool you know for the stack in front of you.

**Exclude from every count**: `node_modules`, `vendor`, `dist`, `build`, `out`, `.next`,
`coverage`, `.venv`, `venv`, `target`, `__pycache__`, `Pods`, migrations you did not write,
`*.min.js`, `*-lock.json`, `*.pb.go`, `*_pb2.py`, `*.g.dart`, `*.generated.*`, snapshots.
`git ls-files` already honours `.gitignore`; prefer it to `find`.

Contents: Q1 Lint + type checker · Q2 Dead code · Q3 Endpoint auth · Q4 Dead endpoints ·
Q5 Duplicate code · Q6 Unit tests · Q7 Integration tests · Q8 DAG · Q9 Types · Q10 CI gates ·
Q11 Committed secrets · Q12 Lockfile + audit · Q13 Oversized files · Q14 Swallowed errors ·
Q15 README · Q16 Baseline lint-rule coverage · Q17 Test coverage ≥ 80% ·
Q18 Force-push blocked on every branch · Q19 Faked clock, no fixed sleeps · Q20 No change-detector tests ·
Q21 Baseline TypeScript compiler-check coverage · Q22 Not re-implementing what a library solves

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
- Are they **deterministic** — no shared mutable fixture, no order dependence? Check for `.skip`,
  `.only`, `xit`, `@pytest.mark.skip`, `t.Skip` and count them; a suite with 40 skipped tests is a
  suite with 40 known-broken tests. Waiting on real time is **Q19**.
- Do they assert behaviour, or only that the code still looks like itself? That is **Q20**.
- Coverage is **Q17**, which has a hard recommended floor of 80% on lines and branches and asks
  whether a threshold enforces it. Answer this question on whether the tests exist, pass, and
  test behaviour; answer the percentage there.

What good looks like: the suite runs in under a couple of minutes, passes on a clean checkout
with one documented command, covers every non-trivial branch of the domain logic, and fails
loudly when behaviour changes. Ratio of test files to source files somewhere in the 0.3–1.0
range is typical of a healthy repo; well outside it in either direction is worth a sentence.

The fix, in this order: get the suite green and in CI (a red suite is worse than none, because
it trains the team to ignore failures), then write tests for the next bug you fix rather than
retrofitting coverage broadly, starting with auth, money, and anything with a `TODO` near it.
Only then chase the Q17 number.

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

A Yes needs them to **exist and to run in CI on every PR**, not to exist and be run by hand
before a release. An integration suite nobody runs rots faster than a unit suite, because the
service it boots keeps changing underneath it — check Q10 for the job, and check the last few
merged PRs actually executed it rather than skipping it on a path filter. Where the full tier is
genuinely too slow for every PR, the Yes requires a fast subset on PRs plus the full tier on a
schedule, with the schedule's failures going somewhere a human reads.

What good looks like: at least one test that boots the real app and exercises the critical path
end to end against a real database — signup → login → the one thing the product does → the one
thing that takes money. Plus one 401/403 test per auth mode. Wired into CI as a required check.
Three good integration tests are worth a hundred mocked unit tests for the failures that
actually reach production.

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
  `strict` is the floor, not the ceiling: **Q21** scores the fourteen further compiler checks it
  does not include. Answer this question on whether the type system is on and honest, and leave
  the per-flag scoring to Q21 so the two do not restate each other.
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

## Q10. Does CI exist, and does it gate every PR on lint, types, tests, integration tests and coverage? (recommended: yes, blocking)

The first sub-question is the blunt one: **is there any CI at all?** A repo with no workflow file
fails this outright, and that failure caps Q1, Q6, Q7 and Q17 at Partial no matter how good the
configuration is, because nothing in the repo is verified by anything but a human remembering to
run it.

```bash
# 1. Does CI exist?
git ls-files .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile azure-pipelines.yml bitbucket-pipelines.yml .buildkite/
# 2. What does each workflow trigger on, and what does it run?
grep -nE '^\s*(on|jobs|steps)|pull_request|merge_request|eslint|biome|tsc|mypy|ruff|golangci|clippy|rubocop|test|coverage|cov|playwright|cypress|audit|continue-on-error' .github/workflows/*.y*ml
# 3. Is it required, or advisory?
gh api repos/{owner}/{repo}/branches/main/protection 2>/dev/null          # 404 = not protected
gh api repos/{owner}/{repo}/rulesets 2>/dev/null                          # [] = no rulesets either
# 4. Did the checks actually run on what was merged?
gh pr list --state merged --limit 20 --json number,statusCheckRollup
gh run list --branch main --limit 10 --json name,conclusion,event
```

Every row of this table is part of the answer, and the report reproduces it filled in:

| Gate | Recommended | What a No means |
|---|---|---|
| A CI workflow exists | **yes** | nothing is verified automatically; everything below is moot |
| Triggers on `pull_request` | **yes** | push-to-main-only CI tells you after the fact |
| Linter runs (Q1, Q16) | **yes, blocking** | style and correctness rules are advisory |
| Type check runs (Q9) | **yes, blocking** | strict types are an editor feature, not a guarantee |
| Unit tests run (Q6) | **yes, blocking** | a red suite can merge |
| Integration tests run (Q7) | **yes, blocking** (or a fast subset on PRs + the full tier scheduled) | the app can stop booting without anyone noticing |
| Coverage threshold enforced (Q17) | **yes, blocking at ≥ 80%** | coverage drifts down one PR at a time |
| Dependency audit runs (Q12) | yes (non-blocking is acceptable while a backlog is cleared) | advisories accumulate silently |
| Required by branch protection or a ruleset | **yes** | every gate above is a suggestion |
| Force-push blocked on every branch (**Q18**) | **yes** | history can be rewritten or erased; configured in the same place, asked separately |
| Not `continue-on-error: true` | **yes** | the check is green whatever it found |
| Runs every package of a monorepo | **yes** | one package is guarded and the others are not |

Two traps worth checking by hand. A job that is required but whose steps are guarded by
`if:` conditions or `paths:` filters can pass without running anything — confirm on a recent
merged PR that the step actually executed. And a gate that runs the test command **without** the
coverage flag (`npm test` where the threshold lives in `npm run test:coverage`) enforces nothing;
the command CI runs must be the command that carries the gate.

Also record: whether Dependabot or Renovate is configured, and whether the suite is fast enough
that people do not routinely merge past it — over roughly fifteen minutes and they will.

What good looks like: one required workflow per package, under ten minutes, running lint, type
check, unit tests, an integration tier and a coverage gate on every pull request, with branch
protection or a ruleset requiring it and at least one review.

The fix, in this order, because each step is worth having before the next one lands:

1. **Protect the branch.** If CI already exists and is green, requiring it is a settings change
   measured in minutes and it is the single highest-value fix in this whole checklist.
2. **Add the missing gates** to the existing workflow — lint first (fastest, and Q16's
   zero-violation wave makes it green immediately), then type check, then tests.
3. **Add the coverage gate last**, at one point below today's measured number (Q17), so it goes
   green on the first run and ratchets from there.

The minimal blocking workflow is a dozen lines: checkout, install from the lockfile, `lint`,
`typecheck`, `test`. If the suite is red today, gate on lint and types now and add tests to the
gate the day they pass — never leave a required check that is expected to fail.

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

tsc and ESLint catch different halves, so this question and **Q21** (the compiler's own checks)
are scored separately and a repo is routinely high on one and low on the other.

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

## Q17. Is test coverage at least 80%, and is the threshold enforced? (recommended: yes)

Q6 asks whether tests exist and pass; Q7 whether anything boots the real app. This asks how much
of the code the suite actually executes, and whether anything stops that number sliding down.

**Measure it. Never estimate it**, and never quote a badge or a README figure you did not
reproduce. If you cannot run the suite with coverage on, the answer is Unknown and you say what
was missing — a guessed percentage is worse than no percentage.

```bash
# JS / TS
npx --no-install vitest run --coverage 2>&1 | tail -20
npx --no-install jest --coverage --coverageReporters=text-summary 2>&1 | tail -12
# Python
pytest --cov --cov-branch --cov-report=term-missing -q 2>&1 | tail -25
# Go  (no branch coverage; atomic mode counts every statement once)
go test -covermode=atomic -coverprofile=/tmp/c.out ./... >/dev/null 2>&1 && go tool cover -func=/tmp/c.out | tail -1
# Rust
cargo llvm-cov --summary-only 2>&1 | tail -6        # or: cargo tarpaulin --out Stdout
# Ruby: simplecov prints the total at the end of `bundle exec rspec`
# Java: ./gradlew jacocoTestReport  → build/reports/jacoco/test/html/index.html
# C#: dotnet test /p:CollectCoverage=true /p:CoverletOutputFormat=json

# Is a threshold configured anywhere, and at what number?
git grep -nE 'coverageThreshold|coverage\.thresholds|--cov-fail-under|fail_under|minimum_coverage|jacocoTestCoverageVerification|/p:Threshold|--fail-under' \
  -- '*.json' '*.js' '*.ts' '*.mjs' '*.cfg' '*.ini' '*.toml' '*.yml' '*.yaml' '*.gradle' '*.rb' Makefile
```

**Two numbers, not one.** Line coverage is what tools print by default; **branch** coverage is
the one that tells you something, because a file whose every line executes under a single input
can still have every `if`, every `?:` and every `catch` untested. 85% lines with 45% branches is
a much weaker suite than the headline suggests. Report both wherever the tool provides both
(`--cov-branch`, vitest/jest report it by default, Go does not have it at all — say so).

Three things make a headline percentage lie, and each is worth a line in the report:

- **What is in the denominator.** Generated clients, migrations, `__init__.py`, config files,
  type-only files and vendored code all inflate or deflate the number depending on which side of
  the include/exclude they land. Read the `collectCoverageFrom` / `coverage.include` / `omit`
  list before quoting anything, and say what it excludes.
- **Where the uncovered 20% is.** This is the actual finding. 80% overall with the auth
  middleware, the payment path, or the migration runner at 0% is worse than 65% spread evenly.
  Get per-file numbers (`--cov-report=term-missing`, `go tool cover -func`, the HTML report) and
  name the three lowest-covered files that matter, with their percentages.
- **Whether the covered lines are asserted.** A test that calls a function and asserts nothing
  raises coverage and catches no regression. Coverage is a floor on what is *executed*, never
  evidence that behaviour is *checked* — cross-reference Q6's "tests the mock" question before
  treating a high number as good news.

**Enforcement is half the question.** A measured 84% with nothing failing the build is a
Partial: it drifts down one PR at a time, and nobody notices until it starts with a 6. The gate
belongs in the test command itself so it fails locally too, not only in CI:

| Stack | The gate |
|---|---|
| vitest | `coverage: { thresholds: { lines: 80, branches: 80 } }` in `vitest.config.ts` |
| jest | `coverageThreshold: { global: { lines: 80, branches: 80 } }` |
| pytest | `--cov-fail-under=80` in `addopts`, plus `[tool.coverage.report] fail_under = 80` |
| go | no built-in gate; a CI step that parses `go tool cover -func` and exits non-zero |
| cargo-llvm-cov | `--fail-under-lines 80` |
| simplecov | `minimum_coverage 80` in `spec_helper.rb` |
| jacoco | a `jacocoTestCoverageVerification` rule wired into `check` |
| coverlet | `/p:Threshold=80 /p:ThresholdType=line%2Cbranch` |

Then Q10 checks that the command carrying the gate is the one CI runs on every PR.

**Integration and E2E coverage usually is not counted.** Playwright, Cypress and any suite that
drives a separate process contribute nothing to a unit-test coverage report unless the run is
instrumented (`c8`/`nyc` wrapping the server, `coverage run` with `--parallel-mode`, jacoco's
agent on the app under test). A repo with excellent Q7 coverage can therefore show a low Q17
number. Say which tiers the figure includes rather than failing the repo for a measurement gap,
and where combined coverage is achievable, report it.

What good looks like: 80% or better on lines **and** branches for production code, a threshold in
the test command that fails the build below it, no critical module far below the average, and the
excludes list short enough to read. Above roughly 90% the marginal test is usually being written
for the number rather than for a bug, and the effort belongs in Q7 instead.

The fix: ratchet, do not sprint. Measure today's number, set the threshold **one point below it**
so the build goes green immediately, and raise it as tests land — a threshold set to an
aspirational 80% on a repo at 55% is a red build the team will delete within a week. Spend the
first tests on the lowest-covered file that would hurt most if it broke, not on the easiest file
to cover. If the suite is currently red, Q6 comes first: coverage of a failing suite is a
meaningless number.

## Q18. Is force-push blocked on every branch, and deletion blocked on the branches that matter? (recommended: every branch; the default branch is the floor)

Every other question on this list is about the quality of the code. This one is about whether the
code can be **destroyed** — by a rogue engineer, a departing contractor, a compromised token, or
far more often a tired person running `git push --force` from the wrong directory at 1am. It is
the cheapest insurance in this checklist and the most frequently absent.

Q10 asks whether branch protection makes CI *required*. This asks whether it makes history
*immutable*. Same settings page, independent settings: a repo can require every check and still
allow anyone with write access to erase a year of commits with one command.

**The recommendation is force-push blocked on every branch.** Protecting only the default branch
is the minimum bar, not the target, and the reasons are not symmetric with how people think about
risk:

- **Feature branches are where the unbacked-up work lives.** The default branch exists in every
  teammate's clone, in CI artifacts, and in every fork. A colleague's half-finished branch exists
  in exactly one place, and a force-push over a shared branch silently destroys their commits.
  This happens far more often than force-pushing `main`, precisely because nobody thinks a feature
  branch is dangerous.
- **Long-lived branches are load-bearing.** `release/*`, `v2.x`, `staging` and hotfix branches are
  production history under a different name.
- **A PR branch rewritten after approval is a supply-chain move.** Approve a diff, force-push a
  different one, merge. Blocking force-push removes the manoeuvre; requiring stale reviews to be
  dismissed on push (`dismiss_stale_reviews`) closes what remains. Check both.
- **Default-deny is the posture that survives.** Protect everything, then carve out an exception
  you can name, rather than protecting one branch and hoping nothing important lives elsewhere.

**Be straight about the cost, because it is real.** Blocking force-push everywhere breaks
`git rebase` onto a PR branch, amending a commit, and any stacked-PR tool. Teams that run this
posture resolve it one of two ways, and the report should say which fits: allow force-push on a
namespaced personal pattern (`users/**`, `dev/**`) that never holds shared work, or move to a
squash-merge workflow where a branch is never rewritten because its commits are collapsed at merge
anyway. A recommendation that ignores the rebase workflow will be ignored in turn.

**Deletion is a different question from force-push and should be scoped differently.** Blocking
deletion on the default branch and on release branches is right; blocking it on every branch
fights routine cleanup and may interfere with automatic branch deletion after merge. Recommend
deletion protection where history must survive, not everywhere, and check that the team's
post-merge cleanup still works after any change.

Read the real configuration rather than assuming — both mechanisms can be in force at once, and
the ref patterns are the whole answer:

```bash
O=<owner>; R=<repo>; B=$(gh api repos/$O/$R --jq .default_branch)

# Classic protection is per branch pattern; ask about the default branch specifically.
gh api "repos/$O/$R/branches/$B/protection" --jq \
  '{force_push_allowed: .allow_force_pushes.enabled,
    deletion_allowed:   .allow_deletions.enabled,
    binds_admins:       .enforce_admins.enabled,
    dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews,
    required_checks:    (.required_status_checks.contexts // [])}' 2>/dev/null || echo "NOT PROTECTED"

# Rulesets are the modern mechanism, can target every branch at once, and can be set org-wide.
# `non_fast_forward` IS the force-push block. The ref patterns say how much it covers.
for id in $(gh api "repos/$O/$R/rulesets" --jq '.[].id'); do
  gh api "repos/$O/$R/rulesets/$id" --jq \
    '{name, enforcement, target,
      include: .conditions.ref_name.include, exclude: .conditions.ref_name.exclude,
      rules: [.rules[].type],
      bypass: [.bypass_actors[]? | {actor_type, bypass_mode}]}'
done
gh api "orgs/<org>/rulesets" 2>/dev/null        # an org-level ruleset covers every repo at once

# What is actually unprotected right now
gh api "repos/$O/$R/branches" --paginate --jq '.[] | select(.protected==false) | .name'
```

Scoring, so the answer is not binary:

| State | Answer |
|---|---|
| Force-push blocked on all branches (`~ALL` ruleset or `*` pattern), deletion blocked on default + release branches, binds admins, no standing bypass | **Yes** |
| Default branch only, properly bound | **Partial** — the floor, and the finding is what is *not* covered |
| Protection exists but `enforce_admins` is false, or a ruleset has `{OrganizationAdmin, always}` in `bypass_actors` | **No in practice** — see below |
| Nothing | **No** |

Three traps, in the order they bite:

- **`enforce_admins: false` is the default** when protection is created through the UI without
  ticking the box, and it is the single most common reason a "protected" branch is not protected.
- **A ruleset with a standing bypass actor is not protection for that actor.**
  `{actor_type: "OrganizationAdmin", bypass_mode: "always"}` in a five-person company is everyone.
  `bypass_mode: "pull_request"` is the narrower, usually-correct form.
- **Protection covers branches, not the repository.** Blocking force-push does nothing about
  repository deletion, transfer, or a visibility change. Those live in org settings
  (`members_can_delete_repositories`) and belong to whoever owns the org — name them in the report
  even though they are outside this repo.

Recovery, so the report is accurate rather than alarming: a force-push does not immediately erase
objects on GitHub's side, and a teammate's clone or a CI cache may still hold the old commits, so a
fast response often recovers everything. But that path depends on the reflog of a machine you do
not control, or on support finding unreachable objects before they are collected. Treat it as a
reason to act quickly, never as a substitute for the setting.

What good looks like: an org-level ruleset blocking force-push on every branch of every repo, with
a named exclusion for personal namespaces if the team rebases; deletion blocked on the default and
release branches; admins bound with no standing bypass; stale reviews dismissed on push; and one
honest answer to "if this repository disappeared tonight, where is the other copy?"

The fix. All branches, which is the recommendation, is a ruleset — do it at the org level if you
own the org, since it then covers repos nobody has thought about yet:

```bash
gh api -X POST "repos/$O/$R/rulesets" --input - <<'JSON'
{
  "name": "no force-push anywhere",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~ALL"], "exclude": ["refs/heads/users/**"] } },
  "rules": [ { "type": "non_fast_forward" } ]
}
JSON
```

The default branch alone, which is the floor and takes a minute. The three load-bearing lines are
`allow_force_pushes`, `allow_deletions` and `enforce_admins` — **drop the
`required_pull_request_reviews` block on a solo repo**, where requiring an approval means no merge
is possible without a second account:

```bash
gh api -X PUT "repos/$O/$R/branches/$B/protection" --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["<the CI check name from Q10>"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": true },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Setting `enforce_admins` on a one-person repo feels like locking yourself out; it is not — a pull
request still merges normally, and it is what stops an accidental `--force` on `main`. If
committing straight to the default branch is the actual workflow, keep force-push and deletion
blocked and drop the review requirement, rather than skipping protection altogether because the
review rule felt heavy. Those two settings are the ones that preserve the code, and they cost
nothing.

## Q19. Do tests wait on real-world time, or is the clock faked? (recommended: faked — no fixed sleeps)

A test that sleeps for two seconds costs two seconds on every run forever, and it is *also* flaky,
because the duration is a guess about how fast someone else's CI runner will be on a bad day. Too
short and it fails intermittently; long enough to be safe and the suite crawls. One fix solves
both: make time something the test controls.

The distinction that matters, because a grep for "timeout" lumps all three together and only one
is a finding:

| Pattern | Verdict |
|---|---|
| **Fixed sleep** — sleeping a hard-coded duration and hoping the thing happened | **finding**: pays the full cost every run and still races on a slow machine |
| **Polling with a deadline** — waiting on a condition with a timeout as the upper bound | fine: returns the moment the condition holds. A 10-second poll is not slow |
| **Faked clock** — advancing time programmatically | preferred: a 30-day expiry test runs in a millisecond |

Find every fixed sleep and **add up what they cost**. "31 fixed sleeps totalling 48 seconds per
run" is a finding a team acts on; "some tests sleep" is not. Confirm it against the suite's own
slowest-test output rather than the grep alone, since one framework-level timeout can dominate
everything the grep found.

Then the half of this question that is about production code, and the reason it usually goes
unfixed: **you can only fake time if the code takes time as a dependency.** Something calling the
system clock directly several layers down, or a retry helper with a hard-coded backoff and no
injectable delay, cannot be tested at any speed without global monkey-patching. When tests sleep,
check whether they sleep because nobody injected a clock — the finding then belongs to the source
file, not the test.

Also watch for the failure mode that looks like success: a suite that is fast **because the
time-dependent behaviour is not tested at all**. Nobody tests a 30-day expiry by waiting 30 days,
so without a fake clock that path simply has no test. If the repo has expiry, TTL, backoff,
scheduling, debounce, rate-limit windows or session timeouts and no clock-faking tooling anywhere,
the honest finding is that none of it is covered — and it will show up as a hole in Q17's per-file
numbers rather than as a slow suite.

Last, check whether retries are configured. A retry count that exists to absorb timing flakiness
is the suite telling you about this problem in its own words.

What good looks like: no fixed sleeps; waiting expressed as polling on a condition; the clock
injected in production code and faked in tests, so expiry, backoff and scheduling logic are tested
exhaustively in milliseconds; no retry configuration compensating for timing.

The fix, cheapest first: replace each fixed sleep with a poll on the condition it was really
waiting for. That is usually a one-line change and it makes the test faster *and* more reliable at
once, which is a rare combination worth leading with. Then, for genuinely time-dependent
behaviour, inject the clock at the boundary that owns it and fake it in the test — every mainstream
stack has a supported way to do this, including fake timers in the JS test runners, freezing
libraries in Python, an injected clock interface in Go, and `TimeProvider` in .NET. Do the slowest
test first and report the seconds saved: a suite dropping from four minutes to forty changes how
often people run it, which is worth more than the time itself.

## Q20. Are there change-detector tests? (recommended: no)

A change-detector test fails whenever the implementation changes and passes whenever it does not,
regardless of whether the behaviour is still correct. It is the worst trade in a test suite: it
charges maintenance on every refactor and buys no confidence, so it makes the code harder to
change while making nobody safer
([reference](https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html)).

Three shapes, in the order you will find them:

1. **The test restates the implementation.** The expected value is computed by the same logic, the
   same constant table, or the same helper that production code uses — so the assertion is
   `f(x) == f(x)` with extra steps, and it cannot fail for the reason you care about. This is the
   shape from the original article and the hardest to spot with a grep: look for a test that
   imports the module under test and then uses it to build the value it asserts against, or that
   mirrors the production branching arm for arm.
2. **The assertion is an undifferentiated blob.** A snapshot or golden file large enough that
   nobody reads the diff, so any change is approved by regenerating it. A small, reviewed snapshot
   of one component is a legitimate test; a 4,000-line snapshot of a whole page is a change
   detector with a nicer name. Size and reviewability are what separate them, so report the count
   of snapshots, the largest ones, and whether the scripts or CI regenerate them with an update
   flag as a habit.
3. **The assertion is about calls, not outcomes.** A test whose only assertions are that mocks
   were called, in an order, with exact arguments, is pinned to the current call graph rather than
   to behaviour. Verifying a call *is* right when the call is the observable contract at a
   boundary you own — "an email was sent to this address" is real — but a verification of an
   internal collaborator is just the implementation written twice.

The strongest mechanical signal is **lockstep churn**: a test file that changes in nearly every
commit that touches its source file. A test coupled to behaviour changes when the behaviour
changes, which is much rarer than the implementation changing. Compute the ratio from the git
history — commits touching both, over commits touching the source — and treat anything near 1.0 as
a candidate worth opening, especially if the file also carries snapshots or mock verification. It
is a candidate rather than a verdict: a file under active feature development legitimately moves
together with its tests, so read the commits before calling it.

Why this matters more than it sounds: these tests are the main reason a team stops refactoring.
Every cleanup turns into a second, larger diff in the test suite, the review gets harder, and the
rational response is to leave the code alone. A suite of change detectors also reports a healthy
Q17 number while catching nothing, which is why this question and the coverage question have to be
read together.

What good looks like: tests assert observable behaviour — a return value, a state change, a
message sent — against expected values a human wrote down; snapshots are small, few, and reviewed
in the diff; mock verification appears only at real boundaries; and a refactor that preserves
behaviour leaves the test suite untouched. That last sentence is the whole test for this question,
and it is worth asking the team directly: when you last restructured something, how much of the
diff was tests?

The fix, per test: work out what observable behaviour it was meant to protect and assert that
instead, with a hand-written expected value. Shrink an oversized snapshot to the fields that
actually matter rather than deleting the test. Replace call verification with an assertion about
the outcome the call produces. Where a test protects nothing but the current shape of the code,
delete it — an empty slot is more honest than a test that must be edited to make any change, and
coverage lost this way is coverage that was never real.

---

## Q21. What percent of the baseline TypeScript compiler checks are enabled? (recommended: 100%)

Q9 asks whether the type system is on and honest. Q16 asks what the linter is configured to
catch. This asks the third, separate question: **of the checks the compiler already ships, how
many is this repo actually running?** A repo can pass Q9 with `"strict": true` — nine checks —
and be leaving fourteen more on the table, every one of them free to turn on and none of them
visible in any tool's output until you do.

The baseline is `references/tsconfig-baseline.json`: **23 checks set by 15 options**, the union
of what two production TypeScript repos have landed one check at a time. Its header carries the
reasoning for each option and the list of options deliberately left out.

**TypeScript only.** N/A for a repo with no `tsconfig.json`; Q9 carries the weight, and the
nearest equivalents are mypy's `--strict` (and `disallow_any_explicit`, `warn_unreachable`,
`warn_return_any`, `warn_unused_ignores` beyond it) for Python, `go vet` plus
`golangci-lint`'s `nilness`/`exhaustive` for Go, `#![deny(warnings)]` plus clippy's `pedantic`
for Rust, and `<Nullable>enable</Nullable>` with `TreatWarningsAsErrors` for C#. A repo with
JavaScript only is a Q9 finding (no compiler is checking anything), not a 0% here.

### Measuring it

Never read the percentage off the tsconfig text. `extends` pulls options in from a base config
or a package (`expo/tsconfig.base`, `@tsconfig/node22`), `strict` expands into nine more, and
neither is visible in the file. `--showConfig` resolves both, which is the whole reason to use
it:

```bash
cd <repo>
npx --no-install tsc --showConfig -p tsconfig.json > /tmp/effective.json
```

Run it **once per tsconfig** — `git ls-files '*tsconfig*.json'` — and score each project
separately. A monorepo's root config says nothing about a package that does not extend it, and
the honest headline is the *lowest* project's score, not the average.

```bash
python3 - <<'PY'
import json, re, subprocess, sys
CHECKS = {  # the 23 in references/tsconfig-baseline.json, with the value that means "on"
 "A strict family": {k: True for k in (
   "alwaysStrict","noImplicitAny","noImplicitThis","strictBindCallApply",
   "strictBuiltinIteratorReturn","strictFunctionTypes","strictNullChecks",
   "strictPropertyInitialization","useUnknownInCatchVariables")},
 "B correctness": {k: True for k in (
   "noUncheckedIndexedAccess","exactOptionalPropertyTypes","noImplicitReturns",
   "noFallthroughCasesInSwitch","noImplicitOverride",
   "noPropertyAccessFromIndexSignature","noUncheckedSideEffectImports")},
 "C dead code + modules": {"noUnusedLocals": True, "noUnusedParameters": True,
   "allowUnreachableCode": False, "allowUnusedLabels": False,
   "verbatimModuleSyntax": True, "isolatedModules": True},
 "D hygiene": {"forceConsistentCasingInFileNames": True},
}
DEFAULT_ON = {"forceConsistentCasingInFileNames"}   # tsc applies these unless turned OFF, and
                                                   # --showConfig does not print them when unset
eff = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/effective.json"))["compilerOptions"]
on = off = 0
for group, checks in CHECKS.items():
    miss = [k for k, want in checks.items()
            if eff.get(k, want if k in DEFAULT_ON else None) != want]
    on += len(checks) - len(miss); off += len(miss)
    print(f"{group}: {len(checks)-len(miss)}/{len(checks)}" + (f"  missing: {', '.join(miss)}" if miss else ""))
print(f"TOTAL {on}/{on+off} = {100*on//(on+off)}%")
PY
```

`--showConfig` expands `strict` into exactly the nine Group A members and resolves `extends`
through packages, which is why it is the authoritative reading. It does **not** print an option
whose default is already the checked value — `forceConsistentCasingInFileNames` has defaulted to
true since TS 5.0, so its absence means on and only an explicit `false` is a finding. The snippet
above handles that one; if you hand-read the output, do the same.

Two further things `--showConfig` will not tell you, and both change the answer:

- **A check only covers the files the project includes.** A config at 23/23 whose `include` is
  `src/**` and whose `tests/` and `scripts/` are checked by nothing scores 100% over a fraction
  of the repo. Get the real denominator before quoting the number:
  `npx --no-install tsc -p <tsconfig> --listFiles | grep -v node_modules | wc -l`, against
  `git ls-files '*.ts' '*.tsx' | wc -l`. Report both, and treat a large gap as the finding —
  it outranks the percentage.
- **A check nobody runs is 0%.** Cross-reference Q1 and Q10: is `tsc --noEmit` wired to a script
  and required by branch protection, or does it only run in someone's editor? "21/23 enabled,
  but the typecheck job is advisory" is the honest sentence.

Do not count an option as covered because something similar is set. `noImplicitAny` alone is not
`strict`. A `@ts-expect-error` or an `// @ts-nocheck` at the top of a file suspends every check
in it — count those (Q9 already does) and say how much of the repo they exempt, because a 23/23
config over 40 `@ts-nocheck` files is not what the number implies.

### What good looks like

23/23 in every project, `include` covering every `.ts` file in the repo, `tsc --noEmit` in CI and
required by branch protection, and no `@ts-nocheck`. Below that, what matters is which checks are
missing, not the percentage: a repo without `noUncheckedIndexedAccess` has a class of runtime
crash it cannot see, while a repo without `noPropertyAccessFromIndexSignature` has a style gap.

Rank the missing ones by what they catch, not by how many errors they would produce:

| Missing check | What ships without it |
|---|---|
| `strict` (or any of its nine) | Everything below is moot; `null` and `undefined` are unchecked |
| `noUncheckedIndexedAccess` | `arr[i]` and `map[key]` are assumed present — the empty-array crash |
| `exactOptionalPropertyTypes` | An explicit `undefined` reaches a payload where the key should be absent |
| `noImplicitReturns` | A branch that falls off the end returns `undefined` against its annotation |
| `noFallthroughCasesInSwitch` | The missing `break` |
| `noImplicitOverride` | A renamed base method leaves subclass methods that are never called again |
| `verbatimModuleSyntax` / `isolatedModules` | Type-only imports survive into the bundle, or load-bearing ones are dropped |
| `noUnusedLocals` / `noUnusedParameters` | Q2's dead code, at the level the compiler could have caught for free |
| `allowUnreachableCode` / `allowUnusedLabels` left at default | Unreachable code is a greyed-out editor hint the build ignores |

### The fix

Copy `tsconfig-baseline.json` into the repo and adopt it in waves, as its header describes:
measure each missing flag alone from the command line
(`npx tsc --noEmit -p <tsconfig> --<flag> 2>&1 | grep -cE 'error TS'`), confirm the flag is not
already set before trusting a zero, canary every zero, commit the zero-cost flags together as a
ratchet, then fix the rest one flag per PR, smallest count first. Report the measured error count
per missing flag if you have it — that count is what makes the plan credible, and it is usually
much smaller than the team expects for everything except `noUncheckedIndexedAccess`.

Where a flag's count is genuinely too large for one sitting, scope it (a second tsconfig over the
directories that pass, or the flag on with an `exclude`) with a comment saying why and a tracking
issue — never leave it off silently. `enable-more-lint-or-ts-checks` is this whole loop as a
skill; hand it this file and the per-flag counts.

---

## Q22. Is the codebase re-implementing something a library already solves? (recommended: no)

Somewhere in most codebases is a function that parses CSV by splitting on commas, adds a day by
adding `86400000`, validates an email with a regex, or hashes a password with SHA-1 and a
homegrown salt. Each one looks small and reads fine. The cost is never the lines you can see: it
is the edge cases the author has not hit yet — the quoted field with an embedded newline, the DST
transition where a day is 23 hours, the plus-addressed and the unicode mailbox, the timing attack.
A library is those same lines plus a decade of other people's bug reports, and the reason to
prefer it is that the bug reports have already happened to someone else.

**Judge on edge cases, not on line count.** "It's only 200 lines" is the wrong axis: 200 lines of
hand-rolled CSV splitting is a smaller file and a much larger liability than `import csv`.

### Where hand-rolling is almost always wrong

| Domain | What the hand-rolled version gets wrong | Severity when found |
|---|---|---|
| **Crypto**: encryption, password hashing, signing, token generation | ECB or a reused IV, `Math.random()` as entropy, a fast hash instead of a KDF, comparison that leaks timing | 🔴 Critical |
| **Auth protocol**: JWT verification, OAuth/OIDC/SAML flows, session cookies | `alg: none`, signature checked but `exp`/`aud`/`iss` not, decode mistaken for verify, no state/PKCE | 🔴 Critical |
| **HTML / SQL / shell escaping and sanitization** | An allowlist regex that misses one vector; escaping applied in the wrong order or twice | 🔴 Critical |
| **Dates, times, timezones, durations** | DST (a day is not always 86,400 s), month-end arithmetic, leap years, parsing a naive string as UTC | 🟠 High |
| **Money and decimals** | Floats for cents; rounding that does not match the ledger or the tax rule | 🟠 High |
| **Parsers of a format someone else specified**: CSV, YAML/TOML/INI, XML/HTML, email addresses, URLs, query strings, semver, cron, MIME, globs, phone numbers | The quoted field, the escape, the nested case — every one of these formats is harder than its examples | 🟠 High |
| **Retry / backoff / circuit breakers / rate limiting / concurrency pools** | No jitter (synchronized retry storms), retrying non-idempotent calls, unbounded queues | 🟡 Medium |
| **Caching with TTL or eviction** | No bound, no stampede protection, a leak that only shows in production | 🟡 Medium |
| **Unicode work**: slugify, case folding, display width, normalization | Anything outside ASCII | 🟡 Medium |
| **Structural utilities**: deep equal, deep clone, deep merge, debounce/throttle, UUIDs | Cycles, `Date`/`Map`/`Set`/`undefined`, prototype pollution, `JSON.parse(JSON.stringify(x))` silently dropping fields | 🟡 Medium |
| **Large subsystems**: ORM / query builder / migrations, job queue, DI container, template engine, state machine, PDF or spreadsheet generation, text diffing | These are products. A homegrown one is a second product the team now maintains instead of theirs | 🟡 Medium–High, by how much rides on it |

### The four shapes, strongest finding first

1. **The library is already a dependency and the hand-rolled version exists anyway.** The repo
   pays the install size, the audit surface and the upgrade work for a package, and the code
   calls a homegrown copy instead — usually the copy without tests. Check the manifest *before*
   writing any finding in this question: `date-fns` in `package.json` next to a `addDays()` built
   on `86400000` is the cheapest fix in the whole review and the easiest to defend.
2. **Vendored or copy-pasted library code.** A `vendor/`, `third_party/` or `lib/external/` tree,
   or a file whose header says "adapted from https://github.com/…". This is a fork nobody will
   update: it misses every security patch silently, and no `npm audit` or Dependabot alert will
   ever mention it. Ask whether it was modified at all — if it was not, it is a dependency
   installed the wrong way, and the fix is one line in the manifest.
3. **A hand-rolled implementation with no equivalent dependency present.** The ordinary case.
   Name the library, check it (below), and rank by the severity table.
4. **The inverse: a dependency for something trivial.** Same question, same axis. A package whose
   whole body is `n % 2 === 1` is supply-chain surface for nothing; a 300 KB date library imported
   for one `format()` call is bundle weight for nothing; adopting a framework to avoid forty lines
   is a migration the team now owns. Report these here, because both answers come from the same
   judgment call and a review that only ever says "add a dependency" is not making one.

### Detecting it

The digest's Q22 section pairs a per-domain signal against the dependency list and flags the
overlaps, which is shape 1. Everything else needs reading. The high-signal greps, as leads rather
than findings:

```bash
git grep -nE '86400000|1000 ?\* ?60 ?\* ?60 ?\* ?24|24 ?\* ?60 ?\* ?60'   # date arithmetic in ms
git grep -nE 'createCipher\(|createDecipheriv?\(|Math\.random\(\).{0,40}(token|key|id|secret|salt)'
git grep -niE '(md5|sha-?1)\b.{0,60}(password|passwd|pwd|secret)'          # a fast hash as a KDF
git grep -nE "\.split\(['\"],['\"]\)" -- '*csv*' '*import*' '*export*'     # CSV by comma
git grep -nE '[A-Za-z0-9._%+-]\+@\[A-Za-z0-9' ; git grep -nE '@.*\\\.\[a-z\]'  # email regexes
git grep -nE 'atob\(|Buffer\.from\([^)]*base64.{0,40}split\(' -- '*jwt*' '*auth*' '*token*'
git grep -nE 'JSON\.parse\(JSON\.stringify\('                             # deep clone
git grep -nE 'replace\(/&/g' ; git grep -nE '&lt;|&amp;.{0,20}replace'    # hand escaping
git grep -nE 'while ?\(.{0,30}(attempt|retries|tries)|for ?\(.{0,20}attempt'   # retry loops
git grep -nE 'process\.argv|sys\.argv' -- '*cli*' '*bin*'                 # argument parsing
```

Then the other half, which the greps cannot do: read the dependency manifest and ask, for each
homegrown utility module in the repo (`utils/`, `lib/`, `helpers/`, `common/` are where they
live), whether it is solving a problem specific to this product or a problem the world already
solved. A utility file's imports tell you which: one that imports nothing and is full of string
and date manipulation is the candidate.

For shape 2, `vendor/`, `third_party/` and `external/` are excluded from every other count in this
review (so the line and duplication numbers stay honest), so look at them explicitly:
`git ls-files | grep -E '(^|/)(vendor|third_party|thirdparty|external|lib/vendor)/'`, plus
`git grep -nliE 'copied from|adapted from|based on (the )?https?://|originally from|forked from'`.

### False positives — check every one of these before writing a finding

- **A thin wrapper around a library is not reinvention.** It is the seam that lets the library be
  replaced. `formatMoney()` calling `Intl.NumberFormat` is good structure.
- **A small helper that is exactly what this domain needs**, with tests, can be cheaper than a
  dependency. The question is whether the problem has edge cases, not whether code exists.
- **The runtime may already ship it.** `crypto.randomUUID`, `structuredClone`, `URL` /
  `URLSearchParams`, `Intl`, `Temporal`, `AbortSignal.timeout`, `Object.groupBy`, and in Python
  `zoneinfo`, `secrets`, `tomllib`, `dataclasses`. Recommending a package for something the
  language now has is the same mistake from the other side — check the runtime version in
  `engines` / `python_requires` / `go.mod` before naming one.
- **A deliberate no-dependency policy**, in an ADR, `CONTRIBUTING.md`, or a comment on the file.
  Common and legitimate for a published library, an edge/serverless bundle with a size ceiling, an
  embedded target, an air-gapped build, or a licence policy. Report it as a documented decision and
  score the question against the policy, not against your preference.
- **They tried the library and it did not fit.** Look for a removed dependency in the history
  (`git log -S'<package>' -- package.json`) or a comment saying why. That is an answered question,
  not an open one.
- **The reinvention is the product.** Do not tell a company whose product is a parser to use a
  parsing library.

### What good looks like

Solved problems are solved by a maintained dependency; the homegrown code in the repo is the part
that is actually about this business. Each dependency is there for a reason bigger than one
function. Nothing is vendored except with a written reason and a plan to re-sync. Where a library
was deliberately not used, the file says so and says what it would have cost.

### The fix

Per finding, and **do not batch them** — replacing hand-rolled crypto is a security fix that wants
its own reviewed PR; replacing a deep-clone helper is a cleanup.

1. **Shape 1 first** (library already installed): mechanical swap, usually an afternoon, and the
   argument is already won.
2. **Then by the severity table.** Crypto, auth-protocol and sanitization findings are 🔴 and
   belong in "Today" — the hand-rolled version is not tech debt, it is the vulnerability.
3. **Check the library before recommending it**: last release, open-issue trend, maintainer count,
   downloads, licence, transitive dependency count, and bundle size if it ships to a browser.
   Swapping working homegrown code for an abandoned package with forty transitive dependencies is
   a worse trade than leaving it alone, and a review that names a package without this check has
   not finished the recommendation.
4. **Keep the hand-rolled version's tests and run them against the library.** They are the
   written-down spec of what this codebase actually needs, and the ones that now fail are exactly
   the behaviour differences to decide about — which is also how you find out the old code had a
   bug. Where there are no tests, write two or three characterization tests before the swap.
5. **For a vendored copy**: diff it against the upstream version it came from. Unmodified means
   delete the tree and add the dependency. Modified means the diff is the real decision — upstream
   it, or record it as an owned fork with the version it forked from and who watches upstream's
   advisories.
