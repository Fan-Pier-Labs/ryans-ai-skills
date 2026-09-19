---
name: code-security-audit
description: Run Semgrep over a whole codebase and turn its output into a triaged security report — pick the rule packs from the languages actually present, prove the scan reached the code (Semgrep skips `tests/`, `vendor/`, `node_modules/`, every gitignored path and every file over 1 MB by default), triage every finding to confirmed / refuted / needs-context with the file open, re-rank severity against what this app actually exposes, and name the bug classes Semgrep structurally cannot see. Use whenever the user asks to run semgrep, "scan this repo for vulnerabilities", "is this code secure", "do a security audit of the codebase", "security scan", "run SAST", "static analysis for security", "find security bugs"; asks about injection, SQL injection, XSS, SSRF, command injection, path traversal, insecure deserialization, hardcoded secrets or credentials in code, weak crypto, OWASP Top Ten or CWE Top 25; or wants a security pass before a launch, a pen test, a customer security questionnaire, or technical due diligence. Read-only — it never applies an autofix and never uploads code. For one pull request's diff use auto-reviewer; for who has access to what and for secrets in git history use sec-ops-audit; for cloud and server configuration use infra-audit; for general code quality use code-quality-audit.
---

# Code Security Audit

Semgrep over the whole repository, then the work that makes the output worth reading. Running
the scanner is the cheap part and takes one command. This skill is the other three:

1. **Proving the scan reached the code** — the default target selection drops more of a repo
   than anyone expects, and a clean report on a third of the files is worse than no report.
2. **Triaging every finding** to **confirmed / refuted / needs-context**, with the file open and
   the evidence written down.
3. **Naming what Semgrep structurally cannot see**, so "the scan was clean" is never mistaken
   for "the code is safe".

**Read-only, always.** Never `--autofix`/`-a`, never `--replacement`, never `semgrep ci`, never
`semgrep publish`, never `semgrep login` without asking. The entire write surface is one report
file outside the source tree, plus custom rules in `.semgrep/` if — and only if — the user asks
for them.

## Why this skill exists

A model told "run semgrep" runs `semgrep --config auto .`, reads the last line, and reports a
number. Both numbers it can get are usually wrong.

**Zero findings** is usually a coverage failure. Verified on semgrep 1.177 against a repo with
`src/`, `tests/`, `vendor/` and `node_modules/`, each holding the identical `subprocess.run(c,
shell=True)`: exactly **one** file was scanned. `tests/`, `vendor/` and `node_modules/` are in
Semgrep's built-in `.semgrepignore` defaults, every gitignored path is dropped before that, and
any file over 1 MB is dropped after. The scan then reports success. And the process **exits 0
with findings** — the exit code only becomes 1 if you pass `--error`. "Semgrep exited 0" means
Semgrep ran.

**Four hundred findings** is usually one rule firing forty times in generated code, plus an
audit-category pack whose rules are written to surface every use of a risky API for human
review rather than to assert a bug. A count with no dedupe and no triage state is not a result.

The rules below force the coverage proof before the findings, and a written verdict per finding
group so nothing is passed through unread.

## Which repo

By default this skill targets **the repo you are currently in** (`git rev-parse --show-toplevel`,
`git remote get-url origin`). It never scans a path the user has not named or implied, never
reaches outside that tree, and never scans a host, a URL, or a running service — this is static
analysis of source code, not a pen test. If the target is ambiguous, **ask**.

## Workflow

Run in order. Load `references/semgrep-packs.md` at step 3, `references/triage-playbook.md` at
step 6, `references/report-template.md` at step 9.

### 1. Scope, exposure, and ground rules

```bash
git rev-parse --abbrev-ref HEAD && git log -1 --format='%h %as %an' && git status --short | head
```

- Confirm the repo, branch and commit, and say in the report if the tree is dirty — you are
  auditing the tree as it stands.
- Ask, or read from `README.md` / `CLAUDE.md`, the three things that decide severity later:
  **what is internet-facing**, **what data the app holds** (payments, PII, health, credentials),
  and **who the untrusted users are** (anonymous internet, authenticated tenants, internal
  staff only). The same `os.system` call is a 🔴 on a public endpoint and a 🟢 in a build script.
- Work in a scratch directory **outside the repo**. Never leave scan output as untracked
  clutter in the source tree.

**Say what leaves the machine, before the first run.** `semgrep scan` does not upload source
code, but it does fetch rules from `semgrep.dev` and, by default, reports pseudonymous usage
metrics whenever the config is pulled from the registry. `--config auto` additionally **logs in
to the registry with your project URL**. Every command in this skill therefore passes
`--metrics=off` and names its packs explicitly instead of using `auto`. If the codebase is
sensitive enough that even rule fetches are unwelcome, say so and offer the offline path in
`references/semgrep-packs.md` (fetch the packs once, scan from a local rule directory).

### 2. Get Semgrep, and know which engine you are running

Prefer an ephemeral run over a global install:

```bash
uvx --from semgrep semgrep --version     # no install; needs uv
pipx run semgrep --version               # no install; needs pipx
brew install semgrep                     # macOS, global
python3 -m pip install --user semgrep    # global
docker run --rm -v "$PWD:/src" semgrep/semgrep semgrep --version   # no host install at all
```

Record the version in the report. Then be explicit about the engine, because it bounds every
taint finding you are about to write up:

- **OSS engine (the default, and what you will almost always have): intrafile only.** It follows
  taint within a single file. A source in one file reaching a sink in another is invisible to
  it — and so is a sanitizer in another file, so it produces both false negatives and false
  positives at file boundaries.
- **Pro engine** (`--pro`, `--pro-intrafile`, `--pro-path-sensitive`) adds interfile and
  interprocedural analysis and the Pro languages (Apex, C#, Elixir). It requires
  `semgrep login` and `semgrep install-semgrep-pro`. **Logging in is an account action on the
  user's semgrep.dev org — ask first, never do it unprompted.**

The report must say which engine produced it. "OSS engine, intrafile taint only" is a caveat
the reader needs, not a footnote.

### 3. Pick the packs from the languages that are actually in the repo

```bash
git ls-files | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -25
git ls-files | grep -Ei 'dockerfile|\.tf$|\.ya?ml$|k8s|helm|\.github/workflows' | head -20
```

Then build the `--config` list from `references/semgrep-packs.md`, which carries the verified
pack names with their rule counts. Every audit gets:

- `p/default` — the curated cross-language set. This is the baseline, not `auto`.
- **one pack per language present** (`p/python`, `p/javascript`, `p/typescript`, `p/golang`,
  `p/java`, `p/ruby`, `p/php`, `p/csharp`, `p/kotlin`, `p/swift`, `p/rust`).
- **one pack per config-as-code surface present** (`p/dockerfile`, `p/terraform`,
  `p/kubernetes`, `p/github-actions`, `p/nginx`).
- `p/secrets` and `p/gitleaks` for credentials in the working tree.
- `p/owasp-top-ten` and `p/cwe-top-25` for the framing the report will use.

Add `p/security-audit` **knowing what it is**: audit-category rules that flag every use of a
risky API for a human to review. It finds real bugs the curated packs miss and it will produce
the bulk of your refutes. Run it, label it, and never quote its raw count as "vulnerabilities".

A pack name that 404s exits 7 with `Failed to download configuration` — that is a typo in your
command, not a finding. The packs verified to exist are listed in the reference; `p/express`,
`p/rails`, `p/html`, `p/bash`, `p/gitlab-ci` and `p/nodejs-scan` do **not**.

### 4. Run the scan

```bash
OUT="${OUT_DIR:-$(mktemp -d)}"; echo "$OUT"
uvx --from semgrep semgrep scan \
  --config p/default --config p/python --config p/secrets \
  --metrics=off --disable-version-check \
  --max-target-bytes 5000000 \
  --json-output "$OUT/findings.json" --sarif-output "$OUT/findings.sarif" \
  --verbose . > "$OUT/scan.log" 2>&1
echo "exit=$?"   # 0 = ran (findings or not) · 2 = semgrep failed · 7 = a bad --config
tail -40 "$OUT/scan.log"
```

Repeat `--config` once per pack. Keep `--verbose`: its skipped-files report is the input to
step 5, and it prints the per-language rule/file table you need there. `--max-target-bytes` is
raised from its 1 MB default so large real source files are not dropped silently; leave minified
bundles excluded (`--exclude-minified-files`) rather than raising it further.

On a large repo, scope the first pass (`--include 'src/**'`) to get an early read, then run the
full scan. `-j` defaults to ~85% of the cores; leave it alone unless the machine is busy.

### 5. Prove the scan covered the code — this is the point of the skill, don't skim it

Three independent defaults each drop files before any rule runs. Check all three:

```bash
sed -n '/Files skipped/,/Scan Summary/p' "$OUT/scan.log"      # the full skip report, by reason
python3 - "$OUT/findings.json" <<'PY'
import json,sys,collections
d=json.load(open(sys.argv[1]))
sc=d["paths"]["scanned"]
print("files scanned:", len(sc))
ext=collections.Counter(p.rsplit(".",1)[-1] for p in sc if "." in p)
print("by extension:", ext.most_common(15))
PY
git ls-files | wc -l        # compare. A large gap is a finding about the scan, not the code.
```

- **Gitignored paths are skipped.** Usually right. Wrong when the repo gitignores generated
  application code, a `config/` with real defaults, or a whole deployed subdirectory.
- **`.semgrepignore` defaults skip `tests/`, `vendor/`, `node_modules/`** and friends. Skipping
  `node_modules/` is right. Skipping `tests/` and `vendor/` for a **security** audit is not:
  hardcoded credentials, disabled TLS verification and permissive CORS live in test helpers,
  and `vendor/` is code that ships.
- **Files over `--max-target-bytes` are skipped**, as are minified files.

If `tests/` or `vendor/` matter here — and for credentials they always do — scan a **copy**,
never the working tree. A project `.semgrepignore` *replaces* the defaults rather than adding to
them (verified), so one empty file in a throwaway copy restores full coverage without writing
anything into the user's repo:

```bash
mkdir -p "$OUT/full" && git archive HEAD | tar -x -C "$OUT/full"   # tracked files only, no write to the repo
printf '# empty: scan everything\n' > "$OUT/full/.semgrepignore"
uvx --from semgrep semgrep scan --config p/secrets --config p/default \
  --metrics=off --disable-version-check --json-output "$OUT/full.json" "$OUT/full"
```

Finally, check the per-language table `--verbose` printed: **a language with files but no rules
means the pack list is wrong**, not that the language is clean. Fix step 3 and re-run before
writing anything.

The report states the coverage number: *"N of M tracked files scanned; `tests/` and `vendor/`
covered by a second pass; 3 files over 5 MB not scanned (listed)."*

### 6. Triage every finding — group, dedupe, then open the file

```bash
python3 - "$OUT/findings.json" <<'PY'
import json,sys,collections
d=json.load(open(sys.argv[1]))
rows=collections.defaultdict(list)
for r in d["results"]:
    m=r["extra"].get("metadata",{})
    rows[(r["check_id"], r["extra"].get("severity"), m.get("confidence"),
          m.get("likelihood"), m.get("impact"),
          (m.get("cwe") or [""])[0][:40])].append(f'{r["path"]}:{r["start"]["line"]}')
for k,v in sorted(rows.items(), key=lambda kv:-len(kv[1])):
    print(f'{len(v):4d}  sev={k[1]:<7} conf={k[2]} lik={k[3]} imp={k[4]}  {k[0]}')
    print(f'      {k[5]}')
    for loc in v[:6]: print("      -", loc)
    if len(v)>6: print(f'      … {len(v)-6} more')
print("total raw:", len(d["results"]), "| rule groups:", len(rows))
PY
```

Work **group by group**, not finding by finding, and write for each group:

```
check_id → sites (deduped by file:line) → verdict (Confirmed / Refuted / Needs-context)
→ the evidence: the file read, the path from an untrusted input to the sink, or the reason
   it cannot be reached → severity for THIS app → the exact fix → confidence
```

Rules that keep this honest:

- **Open the file before every verdict.** A Semgrep match is a lead. `Refuted` without a read
  is a guess, and `Confirmed` without a read is worse.
- **Answer reachability explicitly**: is the tainted value attacker-controlled, and can an
  untrusted user reach this line? A command injection in a developer CLI and one in a request
  handler are not the same finding. If you cannot tell, that is `Needs-context` and you say what
  would settle it.
- **`extra.severity` is the rule author's severity, not yours.** Re-rank with the table below,
  using the rule's `metadata.confidence` / `likelihood` / `impact` and step 1's exposure answers.
- **Forty sites of one rule is one finding with forty sites**, unless the sites genuinely differ.
  Report it that way.
- **Refuted findings are part of the deliverable.** List them with the reason. That list is what
  stops the next audit from re-litigating the same forty matches, and it is what a reader uses
  to decide whether to trust the rest of the report.

`references/triage-playbook.md` has the per-class procedure — what confirms and what refutes an
injection, XSS, SSRF, path traversal, deserialization, crypto, secrets, or IaC finding, and the
standard false positives for each.

### 7. Name what Semgrep could not see

A scan with every pack loaded is still blind to these. State each one in the report, with who
covers it:

| Blind spot | Why Semgrep misses it | Covered by |
|---|---|---|
| **Authorization / IDOR** — the endpoint authenticates but never checks the record is yours | A missing check has no syntax to match | [code-quality-audit](../code-quality-audit/SKILL.md) Q3 |
| **Secrets in git history** | `semgrep scan` reads the worktree; `--historical-secrets` is part of the paid Secrets product | `gitleaks detect`, `trufflehog git`, [sec-ops-audit](../sec-ops-audit/SKILL.md) |
| **Vulnerable dependencies (SCA)** | `p/supply-chain` is a stub; real SCA is the paid product | `npm audit`, `pip-audit`, `osv-scanner`, Dependabot |
| **Cloud, server and network configuration** | Not in the repo | [infra-audit](../infra-audit/SKILL.md) |
| **Multi-step business logic** — price tampering, replayable state transitions, race conditions | No single-file pattern | Manual review |
| **Missing controls** — no rate limiting, no lockout, weak session lifecycle, no audit log | Absence of code | Manual review |
| **Cross-file taint** (OSS engine) | Intrafile only | `--pro`, or read it yourself |
| **Unsupported languages** | `semgrep scan --show-supported-languages` lists what is in scope | Language-specific tooling |

Do a **bounded manual pass** on the two that pay off most for a web app: pick the endpoints that
read or write another user's data and check for an authorization check, and grep the config for
disabled TLS verification, permissive CORS, and debug flags. An hour here beats another pack.

### 8. Custom rules — only if the user wants them

The packs know nothing about this codebase's own dangerous wrappers: its `db.raw()`, its
`render_unsafe()`, the decorator every handler must carry. Two or three rules for those turn
this audit into a gate that holds. Write them only on request:

```bash
mkdir -p .semgrep && $EDITOR .semgrep/no-raw-sql.yaml
uvx --from semgrep semgrep scan --test .semgrep/           # rule + fixture, must pass before it ships
uvx --from semgrep semgrep scan --config .semgrep/ --error .   # how CI would run it
```

A rule without a `# ruleid:` / `# ok:` fixture is not finished — a rule that cannot fail is
indistinguishable from one that passes.

### 9. Write the report

`references/report-template.md`: summary → coverage statement → confirmed findings ranked by
severity → needs-context → refuted, with reasons → what Semgrep could not see → method,
versions, packs and caveats → a recommended sequence. Lead with the worst confirmed finding.
A report whose first paragraph is a rule count is not finished.

## Severity — rebased on this app, not on the rule

| Severity | Meaning |
|---|---|
| 🔴 Critical | Reachable by an untrusted user and leads to code execution, authentication bypass, or bulk data access: injection on a public endpoint, deserialization of user input, hardcoded live credential, hand-rolled or disabled auth/crypto on a live path. Fix today. |
| 🟠 High | Reachable but bounded, or unreachable today and one refactor away: stored XSS behind a login, SSRF into a private network, path traversal in an authenticated upload, TLS verification disabled, a secret live in the tree but scoped to staging. |
| 🟡 Medium | Real weakness with no current path to exploit: weak hashing on non-credential data, a permissive CORS origin on a read-only endpoint, an audit-category hit on an internal tool. |
| 🟢 Low / Informational | Hardening and hygiene. Say what is genuinely fine, but only what you verified. |
| ⚪ Refuted | Matched, read, and not a bug — with the reason. |

## Gating: what may run

```
semgrep scan (read-only), git log, reading files                 ──→ default, always fine
   ↓
scanning a git-archive copy in the scratch dir                    ──→ fine
   ↓
semgrep login / install-semgrep-pro (account action)              ──→ ask first
   ↓
writing .semgrep/ rules, filing an issue, opening a PR,
running the app, touching a live host, --autofix                  ──→ only after the user names it
```

The user reading the report and saying "fix the SQL injection in the billing query" authorizes
that one change. Never batch security fixes across findings — each one needs its own review.

## Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "Semgrep exited 0, so the code is clean." | Exit 0 means Semgrep ran. Findings do not change it without `--error`. Read the JSON. |
| "Zero findings." | Check `paths.scanned` first. Verified: with `src/`, `tests/`, `vendor/` and `node_modules/` holding the same bug, the default scan reads one of the four. |
| "I ran `--config auto`, so the right rules ran." | `auto` picks by language detection *and logs in to the registry with your project URL*. Name the packs so the report can list them and the next run is reproducible. |
| "`p/security-audit` is the security pack." | It is 79 audit-category rules that flag risky APIs for review. `p/default` is the curated set. Run both, label which produced what. |
| "`ERROR` severity means critical." | That is the rule author's severity, with no knowledge of this app. Re-rank against exposure. |
| "The taint rule fired, so it is exploitable." | The OSS engine is intrafile. It cannot see the sanitizer in the next file either. Trace the path yourself before you write Confirmed. |
| "No path from user input, so it is fine." | Also check the framework's implicit inputs: headers, cookies, webhook bodies, queue messages, filenames, and anything from a partner API. |
| "It is only in tests, so it does not matter." | A credential in a test is a credential. A disabled TLS check in a test helper is one import away from production. |
| "The scan took four minutes, so it was thorough." | Minutes measure rules × files scanned, and the skipped files cost nothing. Only the coverage numbers say what was read. |
| "It found `password = "..."`, so there is a hardcoded secret." | Check whether the value is live, its scope, and whether it is also in git history — which this scan never looked at. A placeholder is a refute; a live key is a 🔴 *and* a rotation. |
| "The same rule fired 40 times, so there are 40 vulnerabilities." | One finding, forty sites — unless the sites differ. Dedupe before you count. |
| "Rules ran for 1,074 rules, so every language is covered." | Check the per-language table. A repo with Go files and no Go rules reads as clean. |
| "`--pro` would find more, so these numbers are wrong." | They are the OSS numbers and that is a fine report — as long as it says so. Do not log in to someone's org to improve a count. |
| "I will fix them as I find them." | Read-only. A security fix that nobody reviewed is how the next finding gets introduced. |
| "Semgrep tagged it CWE-89, so I will report SQL injection." | The CWE comes from the rule, not from this code. Open the file. |
| "Clean scan, so the app is secure." | Step 7 exists because of this sentence. Authorization, history, dependencies, infra and business logic were never looked at. |

## Output

Deliver the report as a markdown file in the project's `plans/` or `docs/` directory (or
wherever `CLAUDE.md` says analyses live) — never in a public place without asking, since a
confirmed-findings list is an exploitation guide until it is fixed. In chat, lead with the worst
confirmed finding and the coverage statement.

Offer, and do not assume: a GitHub issue per confirmed finding (private repos only, and ask
before putting exploit detail in one), a `plans/` remediation sequence, custom rules from step 8
wired into CI, or fixing the top finding.

Record in the project's `CLAUDE.md` what makes the next run a re-run instead of a
rediscovery: the pack list, the coverage overrides and why, the Semgrep version and engine, and
**the refuted findings with their reasons**.

## Guardrails

- **Read-only.** Never `-a`/`--autofix`, never `--replacement`, never `--dryrun` as a prelude to
  applying, never `semgrep ci`, never `semgrep publish`. No code changes without the user naming
  the fix.
- **Never `semgrep login` or `install-semgrep-pro` unprompted** — it touches the user's
  semgrep.dev account.
- **Say what leaves the machine before the first run**, and always pass `--metrics=off`. Never
  use `--config auto` on a private codebase without saying that it sends the project URL.
- **Never write into the source tree.** Scan output, the `.semgrepignore` override and the
  report copy all live in the scratch dir; the second pass reads a `git archive` copy.
- **Never claim a finding you have not opened the file for**, and never report a count without
  dedupe and a triage verdict.
- **Static only.** No running the app, no exploiting a finding, no touching a live host, URL, or
  service. That is a different engagement with a different authorization.
- **Confirmed findings are sensitive.** No public issues, no pasting them into a third-party
  service, until the user says so.
- **No personal, org, or account references** in anything this skill writes.

## Tuning

| Variable | Default | Effect |
|---|---|---|
| `OUT_DIR` | a `mktemp -d` | Where scan output and the report draft land. Must be outside the repo. |
| `SEMGREP_RULES` | unset | Semgrep's own env form of `--config`; the explicit flags in this skill win on clarity. |
| `SEMGREP_SEND_METRICS` | `off` here | Set by `--metrics=off` on every command. |
| `SEMGREP_BASELINE_COMMIT` | unset | Scopes a run to what changed since a commit (`--baseline-commit`). Useful for "what did this branch add" — not a substitute for the full audit. |
| `SEMGREP_TIMEOUT` | semgrep default | Per-rule-per-file timeout; raise only if the log shows timeouts. |

## Reference files

- `references/semgrep-packs.md` — the verified registry packs (name, rule count, what it
  covers, when to load it), which common-looking names do **not** exist, the per-language and
  per-config-surface selection table, and the fully offline path. Read at step 3.
- `references/triage-playbook.md` — per finding class: what confirms it, what refutes it, the
  standard false positives, and the fix. Read at step 6.
- `references/report-template.md` — the report skeleton and the per-finding contract. Read at
  step 9.
