# Triage playbook

One section per finding class. Each says what **confirms** it, what **refutes** it, the false
positives that come up every time, and the fix to recommend. Work the group, not the individual
match, and write the verdict down before moving on.

## The three questions, asked of every group

1. **Is the value attacker-controlled?** Trace back from the sink. Request body, query string,
   path segment, header, cookie, uploaded filename, webhook payload, queue message, and anything
   from a third-party API are all untrusted. A constant, an enum, an internal id you generated,
   or a value already validated against an allow-list is not.
2. **Can an untrusted user reach this line?** Find the route, the CLI entry point, the cron job,
   the event handler. Code with no caller is a different (and smaller) finding — and a
   dead-code finding for code-quality-audit.
3. **What does success get the attacker?** Code execution and auth bypass sit at the top; a
   reflected error message sits near the bottom. This is what turns a rule severity into a real
   one.

If question 1 or 2 cannot be answered from the repo, the verdict is **Needs-context** and you
name what would settle it (a route table, the reverse-proxy config, the mobile client, traffic
logs).

## Command injection (CWE-78)

- **Confirms**: user-controlled string reaching `os.system`, `subprocess.*(shell=True)`,
  `exec`/`eval` of a shell string, backticks, `child_process.exec`, `Runtime.exec` with a
  concatenated command, Go `exec.Command("sh", "-c", ...)`.
- **Refutes**: the argument is a literal or comes from config the attacker cannot set; the call
  uses an argument vector with no shell (`subprocess.run([...])`, `execFile`); the value is
  validated against an allow-list *before* the call in the same path.
- **False positives**: build scripts, developer CLIs, migration tooling, test helpers. Still
  worth a 🟡 note if the script runs in CI with secrets in the environment.
- **Fix**: pass an argument list, never a shell string. If a shell is unavoidable, allow-list the
  value; quoting helpers are a last resort, not a control.

## SQL injection (CWE-89)

- **Confirms**: string concatenation or f-string/interpolation into a query, `db.raw()`,
  `.query(... + var)`, an ORM escape hatch (`extra()`, `raw()`, `literal()`, `Sequelize.literal`)
  carrying request data.
- **Refutes**: parameterized query with the variable in the parameter list; the interpolated
  part is a table/column name from a closed allow-list; the value is an integer already coerced.
- **False positives**: query *builders* that parameterize internally, migrations, seed scripts,
  and analytics queries over constants.
- **Fix**: parameterized queries. For dynamic identifiers, map through a literal dictionary of
  permitted names — never quote-and-hope.

## XSS (CWE-79)

- **Confirms**: `innerHTML`, `dangerouslySetInnerHTML`, `v-html`, `document.write`,
  `|safe`/`raw`/`mark_safe`/`html_safe` on request data or on anything stored that a user wrote.
- **Refutes**: the framework auto-escapes and no escape hatch is used; the value is passed
  through a maintained sanitizer (DOMPurify, bleach, sanitize-html) with a restrictive config;
  it is server-side rendering of a constant.
- **False positives**: templates rendering developer-authored constants, admin-only tooling
  (still 🟡 — admin XSS is privilege escalation), and markdown renderers that already escape.
- **Fix**: let the framework escape. Where raw HTML is genuinely required, sanitize with a
  maintained library, never a hand-rolled regex — and note the hand-rolled case for
  code-quality-audit Q22.
- **Stored beats reflected**: if the value is persisted, raise the severity a level.

## SSRF (CWE-918)

- **Confirms**: a request-controlled URL, host, or port reaching an HTTP client, a webhook
  sender, an image/PDF fetcher, or a URL preview generator.
- **Refutes**: the host is fixed and only the path varies (still check for `../` and absolute-URL
  override); the URL is validated against an allow-list of hosts *after* DNS resolution.
- **False positives**: outbound calls to configured third-party APIs; clients that only ever see
  internal service names from config.
- **Fix**: allow-list destinations, reject private/link-local/metadata ranges after resolution,
  disable redirects or re-validate each hop, and run egress through a proxy. Cloud metadata
  endpoints (`169.254.169.254`) are the payload that makes this a 🔴 on a cloud host.

## Path traversal and unsafe file handling (CWE-22)

- **Confirms**: a request-supplied filename or path component reaching `open`, `readFile`,
  `sendFile`, `os.path.join` with a root, an archive extractor (zip-slip), or a static-file
  handler.
- **Refutes**: the name is generated server-side (UUID) and the user-supplied name is only
  metadata; the resolved absolute path is checked to sit under the root *after* normalization.
- **False positives**: CLI tools reading a path the operator typed.
- **Fix**: resolve, then verify the real path is inside the intended root. Store with generated
  names. For archives, reject entries whose normalized path escapes the destination.

## Insecure deserialization (CWE-502)

- **Confirms**: `pickle`, `yaml.load` without `SafeLoader`, `marshal`, Java
  `ObjectInputStream`, PHP `unserialize`, .NET `BinaryFormatter`, or `node-serialize` on
  anything crossing a trust boundary — including cookies, cache entries and queue messages.
- **Refutes**: the input is produced and signed by this same system and the signature is
  verified before deserializing; the format is data-only (JSON with no custom decoder).
- **Fix**: JSON or another data-only format. If a rich format is required, sign it and verify
  before parsing. This class is usually **🔴 whenever it is reachable** — it is remote code
  execution by construction.

## Crypto, hashing, and randomness

- **Confirms**: MD5/SHA-1 for passwords or signatures, ECB mode, a static IV or key, a key
  committed in the repo, `Math.random()` / `random.random()` for tokens, session ids or
  password resets, TLS verification disabled (`verify=False`, `rejectUnauthorized: false`,
  `InsecureSkipVerify: true`), a hand-rolled JWT verify or `alg: none` accepted.
- **Refutes**: MD5/SHA-1 used as a non-security checksum (cache key, ETag, content dedupe) —
  a genuine and common refute, worth one line each.
- **Fix**: bcrypt/scrypt/argon2 for passwords, AES-GCM for encryption, the platform CSPRNG for
  tokens, a maintained JWT library with the algorithm pinned. Disabled TLS verification is 🔴 if
  it touches a network you do not control, 🟠 if it is a local dev fixture — and it should still
  not be in shipped code.

## Hardcoded secrets

- **Confirms**: a value that matches a live credential shape (provider key prefixes, PEM blocks,
  long high-entropy strings) in code, config, CI YAML, or a notebook.
- **Refutes**: an obvious placeholder (`xxx`, `changeme`, `your-key-here`), a test fixture that
  is clearly synthetic, a public key, a value already rotated.
- **Always ask two more questions** the scan did not: **is it live** (that decides rotation) and
  **is it in git history** (`semgrep scan` reads the worktree only — the history needs
  `gitleaks detect --no-git=false`, `trufflehog git`, or [sec-ops-audit](../../sec-ops-audit/SKILL.md)).
- **Fix**: rotate first, then remove. Removing a secret from the tip without rotating it changes
  nothing — it is still in the history and still valid. Move to the platform's secret store and
  note the rotation date.

## Authentication and session findings

Semgrep catches the mechanical half: a missing decorator where its siblings have one, a session
cookie without `Secure`/`HttpOnly`/`SameSite`, a JWT verified without checking `exp` or the
algorithm, a password compared with `==`.

It does **not** catch authorization. "This endpoint requires a login" and "this endpoint checks
that the record belongs to the caller" are different claims, and only the first has syntax to
match on. Any endpoint that takes an id and returns a record needs a human read — see
[code-quality-audit](../../code-quality-audit/SKILL.md) Q3.

## Infrastructure-as-code (Dockerfile, Terraform, Kubernetes, Actions)

- **Confirms**: a container running as root, `0.0.0.0/0` on a sensitive port, a public storage
  bucket, unencrypted storage or an unencrypted database, a `latest` image tag on a deployed
  workload, a GitHub Actions workflow using `pull_request_target` with a checkout of the PR head,
  or an unpinned third-party action.
- **Refutes**: the file is an example, a local-dev compose file, or a module never applied to a
  live environment — **check which before writing it up**, since a finding in `examples/` reads
  identically to one in production config.
- **Fix**: per the rule, but route anything about the *running* estate to
  [infra-audit](../../infra-audit/SKILL.md) — what is in the repo and what is deployed drift,
  and this scan only sees the repo.

## Audit-category findings

Rules whose id contains `.audit.` (most of `p/security-audit`) are designed to surface an API
for review rather than to assert a bug. Triage them as a batch: group by rule, read two or three
representative sites, and if the pattern is safe here, refute the whole group with one reason.
Do not let them dominate the report — they are the raw material for the custom rules in step 8,
where a repo-specific version of the same check will be precise enough to gate CI on.
