# Semgrep rule packs: what exists, what each one is for

Every pack below was resolved against the live registry with semgrep **1.177.0**. The counts are
the rules Semgrep reported loading for that pack — they move as the registry moves, so treat
them as orders of magnitude, not as figures to quote in a report.

Packs are combined by repeating the flag:

```bash
semgrep scan --config p/default --config p/python --config p/secrets --metrics=off .
```

A name that is not in the registry fails the whole run with exit **7** and
`Failed to download configuration from https://semgrep.dev/c/p/<name> HTTP 404`. That is a typo
in your command, not a finding.

## Start here, every audit

| Pack | ~Rules | What it is |
|---|---|---|
| `p/default` | 290 | The curated cross-language set: the rules Semgrep is willing to stand behind as likely-real. This is the baseline. |
| `p/secrets` | 37 | Credentials and keys in the working tree. |
| `p/gitleaks` | 174 | The gitleaks credential patterns, ported. Overlaps `p/secrets`; run both and dedupe. |
| `p/owasp-top-ten` | 152 | Mapped to OWASP categories — useful because the report is usually read in that frame. |
| `p/cwe-top-25` | 64 | The CWE Top 25, same reasoning. |
| `p/security-audit` | 79 | **Audit category.** Flags every use of a risky API so a human decides. Finds real bugs the curated set misses, and produces most of your refutes. `p/r2c-security-audit` is the same pack under its old name — load one, not both. |

## By language — load the ones the repo actually contains

| Language | Pack | ~Rules | Also consider |
|---|---|---|---|
| Python | `p/python` | 151 | `p/bandit` (90), `p/django` (27), `p/flask` (18) |
| JavaScript | `p/javascript` | 74 | `p/react` (4), `p/clientside-js` (6), `p/eslint` (12) |
| TypeScript | `p/typescript` | 74 | same as JavaScript |
| Go | `p/golang` | 42 | `p/gosec` (23) |
| Java | `p/java` | 60 | `p/findsecbugs` (285) |
| Ruby | `p/ruby` | 45 | `p/brakeman` (19) |
| PHP | `p/php` | 24 | `p/phpcs-security-audit` (9) |
| C# | `p/csharp` | 27 | Pro engine only for full C# support |
| Kotlin | `p/kotlin` | 10 | `p/mobsfscan` (163) for mobile |
| Swift | `p/swift` | 2 | `p/mobsfscan` (163) |
| Rust | `p/rust` | 1 | thin; `p/default` carries most of it |

`p/trailofbits` (41) is a cross-language set of high-signal rules from Trail of Bits — worth
adding to any audit that has the runtime budget.

## By configuration surface — load when those files exist

| Files present | Pack | ~Rules |
|---|---|---|
| `Dockerfile`, `*.dockerfile` | `p/dockerfile` (alias `p/docker`) | 7 |
| `*.tf`, `*.tfvars` | `p/terraform` | 63 |
| k8s manifests, Helm charts | `p/kubernetes` | 11 |
| `.github/workflows/*.yml` | `p/github-actions` | 12 |
| nginx configs | `p/nginx` | 7 |

## Narrow packs, for a focused second pass

`p/sql-injection` (13) · `p/xss` (8) · `p/command-injection` (21) · `p/insecure-transport` (17) ·
`p/jwt` (3) · `p/headless-browser` (15) · `p/comment` (20, flags TODO/FIXME/HACK — hygiene, not
security).

Two stubs that exist but carry almost nothing: `p/supply-chain` (1) and
`p/semgrep-misconfigurations` (1). Real SCA is Semgrep's paid Supply Chain product — use
`npm audit`, `pip-audit`, `osv-scanner` or Dependabot instead, and say so in the report.

## Names that look right and do not exist

Verified 404 on the registry: **`p/express`**, **`p/rails`**, **`p/html`**, **`p/bash`**,
**`p/gitlab-ci`**, **`p/nodejs-scan`**. Use the language pack instead (`p/javascript` for
Express, `p/ruby` + `p/brakeman` for Rails).

## `auto` versus named packs

`--config auto` fetches "rules tailored to this project" — and, in Semgrep's own words, *"will
log in to the Semgrep Registry with your project URL."* It is convenient and it is not a
superset of the packs above. Name the packs: the report can then list exactly what ran, and the
next audit is a re-run rather than a different scan.

## Fully offline

Rules are fetched over the network on every run unless you hand Semgrep local YAML. To scan a
codebase with no registry traffic at all, fetch once from a machine that may talk to the
registry:

```bash
for p in default python secrets; do
  curl -sSL "https://semgrep.dev/c/p/$p" -o "rules/$p.yaml"
done
semgrep scan --config rules/ --metrics=off --disable-version-check .
```

`--config` accepts a directory of `.yaml`/`.yml` files, so a vendored `rules/` directory (or the
repo's own `.semgrep/`) runs with no outbound connection. Note the date the rules were fetched
in the report — offline rules go stale silently.

## Language support

`semgrep scan --show-supported-languages` prints the list. As of 1.177 it covers apex, bash, c,
c#, c++, cairo, circom, clojure, dart, docker(file), elixir, go, gosu, hack, hcl, html, java,
javascript, json, jsonnet, julia, kotlin, lisp, lua, move, ocaml, php, powershell, promql,
proto, python, ql, r, regex, ruby, rust, scala, scheme, solidity, swift, terraform, typescript,
vue, xml and yaml. Apex, C# and Elixir need the Pro engine for full analysis. Anything not on
that list is outside this audit and the report says so.
