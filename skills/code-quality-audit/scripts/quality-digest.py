#!/usr/bin/env python3
"""Scan the repo for the mechanical evidence behind the fifteen code-quality questions and
write <out>/inventory.json plus <out>/DIGEST.md.

  scripts/quality-digest.py <repo> <out>

Reads the JSON written by import-graph.py, find-endpoints.py and dup-blocks.py from <out>
when present, and lists any tool-*.txt written by run-analyzers.sh. Pure read of local
files; nothing is executed. Secret matches are printed redacted (first 4 chars only).
"""
import json, os, re, sys, datetime, collections, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _repo_files import list_files, is_source, is_test, language_of, read_text  # noqa: E402

root = os.path.abspath(sys.argv[1]); out = os.path.abspath(sys.argv[2]); os.makedirs(out, exist_ok=True)
files = list_files(root)
texts = {}
def T(f):
    if f not in texts:
        texts[f] = read_text(root, f) or ""
    return texts[f]
def base(f): return f.rsplit("/", 1)[-1]
def exists(*names): return [f for f in files if base(f) in names]
def glob_re(rx): 
    r = re.compile(rx); return [f for f in files if r.search(f)]
def L(n):
    try: return json.load(open(os.path.join(out, n)))
    except Exception: return None

inv = {"repo": root, "date": str(datetime.date.today()), "files": len(files)}

# ---------- stack ----------
src = [f for f in files if is_source(f)]
lang_files = collections.Counter(language_of(f) for f in src)
lang_lines = collections.Counter()
line_count = {}
for f in src:
    n = T(f).count("\n") + 1; line_count[f] = n; lang_lines[language_of(f)] += n
inv["languages"] = {l: {"files": c, "lines": lang_lines[l]} for l, c in lang_files.most_common()}
primary = [l for l, _ in lang_files.most_common(3)]
manifests = {"package.json": exists("package.json"), "pyproject.toml": exists("pyproject.toml"), "requirements.txt": glob_re(r"(^|/)requirements[\w.-]*\.txt$"),
             "setup.py": exists("setup.py"), "Pipfile": exists("Pipfile"), "go.mod": exists("go.mod"), "Cargo.toml": exists("Cargo.toml"),
             "Gemfile": exists("Gemfile"), "pom.xml": exists("pom.xml"), "build.gradle": glob_re(r"build\.gradle(\.kts)?$"), "composer.json": exists("composer.json"),
             "*.csproj": glob_re(r"\.csproj$"), "pubspec.yaml": exists("pubspec.yaml"), "Package.swift": exists("Package.swift")}
inv["manifests"] = {k: v for k, v in manifests.items() if v}
pkg = {}
for f in manifests["package.json"][:10]:
    try: pkg[f] = json.loads(T(f))
    except Exception: pkg[f] = {}
def dep_names():
    names = set()
    for p in pkg.values():
        for k in ("dependencies", "devDependencies", "peerDependencies"):
            names |= set((p.get(k) or {}).keys())
    for f in manifests["pyproject.toml"] + manifests["requirements.txt"] + manifests["Pipfile"] + manifests["setup.py"]:
        names |= set(re.findall(r"^\s*\"?([A-Za-z][\w.-]+)", T(f), re.M))
    for f in manifests["Gemfile"]:
        names |= set(re.findall(r"gem\s+['\"]([\w-]+)", T(f)))
    for f in manifests["go.mod"]:
        names |= set(re.findall(r"^\s*([\w./-]+)\s+v", T(f), re.M))
    return names
deps = dep_names()
pyproject_txt = "\n".join(T(f) for f in manifests["pyproject.toml"])
setupcfg_txt = "\n".join(T(f) for f in exists("setup.cfg"))
pkg_scripts = {}
for f, p in pkg.items():
    for k, v in (p.get("scripts") or {}).items():
        pkg_scripts[f"{f}:{k}"] = v
scripts_blob = "\n".join(f"{k}: {v}" for k, v in pkg_scripts.items())
make_blob = "\n".join(T(f) for f in exists("Makefile", "justfile", "Justfile", "Taskfile.yml", "tox.ini", "noxfile.py"))

# ---------- Q1 lint / type / format tooling ----------
def cfg(name, found, kind):
    return {"tool": name, "kind": kind, "config": found[:5]}
tooling = []
tooling.append(cfg("eslint", glob_re(r"(^|/)(\.eslintrc(\.\w+)?|eslint\.config\.\w+)$") + [f for f, p in pkg.items() if "eslintConfig" in p], "lint"))
tooling.append(cfg("biome", glob_re(r"(^|/)biome\.jsonc?$"), "lint+format"))
tooling.append(cfg("prettier", glob_re(r"(^|/)(\.prettierrc(\.\w+)?|prettier\.config\.\w+)$") + [f for f, p in pkg.items() if "prettier" in p], "format"))
ts_cfgs = glob_re(r"(^|/)tsconfig(\.\w+)?\.json$")
tooling.append(cfg("typescript (tsconfig)", ts_cfgs, "types"))
tooling.append(cfg("mypy", glob_re(r"(^|/)\.?mypy\.ini$") + (["pyproject.toml [tool.mypy]"] if "[tool.mypy]" in pyproject_txt else []) + (["setup.cfg [mypy]"] if "[mypy]" in setupcfg_txt else []), "types"))
tooling.append(cfg("pyright/pylance", exists("pyrightconfig.json") + (["pyproject.toml [tool.pyright]"] if "[tool.pyright]" in pyproject_txt else []), "types"))
tooling.append(cfg("ruff", glob_re(r"(^|/)\.?ruff\.toml$") + (["pyproject.toml [tool.ruff]"] if "[tool.ruff" in pyproject_txt else []), "lint+format"))
tooling.append(cfg("flake8", exists(".flake8") + (["setup.cfg [flake8]"] if "[flake8]" in setupcfg_txt else []) + exists("tox.ini") if "[flake8]" in "\n".join(T(f) for f in exists("tox.ini")) else exists(".flake8") + (["setup.cfg [flake8]"] if "[flake8]" in setupcfg_txt else []), "lint"))
tooling.append(cfg("pylint", glob_re(r"(^|/)\.?pylintrc$") + (["pyproject.toml [tool.pylint"] if "[tool.pylint" in pyproject_txt else []), "lint"))
tooling.append(cfg("black", ["pyproject.toml [tool.black]"] if "[tool.black]" in pyproject_txt else [], "format"))
tooling.append(cfg("isort", ["pyproject.toml [tool.isort]"] if "[tool.isort]" in pyproject_txt else exists(".isort.cfg"), "format"))
tooling.append(cfg("golangci-lint", glob_re(r"(^|/)\.golangci\.ya?ml$"), "lint"))
tooling.append(cfg("staticcheck", glob_re(r"(^|/)staticcheck\.conf$"), "lint"))
tooling.append(cfg("clippy/rustfmt", exists("clippy.toml", "rustfmt.toml", ".rustfmt.toml"), "lint+format"))
tooling.append(cfg("rubocop", glob_re(r"(^|/)\.rubocop\.ya?ml$"), "lint+format"))
tooling.append(cfg("sorbet/rbs", glob_re(r"(^|/)sorbet/config$") + glob_re(r"\.rbs$")[:1], "types"))
tooling.append(cfg("checkstyle/spotbugs/pmd", glob_re(r"checkstyle[\w-]*\.xml$|spotbugs[\w-]*\.xml$|pmd[\w-]*\.xml$"), "lint"))
tooling.append(cfg("detekt/ktlint", glob_re(r"detekt[\w-]*\.ya?ml$|\.editorconfig$") if "kotlin" in lang_files else [], "lint"))
tooling.append(cfg("phpstan/psalm", glob_re(r"(^|/)(phpstan\.neon(\.dist)?|psalm\.xml)$"), "types"))
tooling.append(cfg("swiftlint", glob_re(r"(^|/)\.swiftlint\.ya?ml$"), "lint"))
tooling.append(cfg("dotnet analyzers (.editorconfig dotnet_* rules)", [f for f in exists(".editorconfig") if "dotnet_" in T(f)], "lint"))
tooling.append(cfg("pre-commit", exists(".pre-commit-config.yaml"), "hook"))
tooling.append(cfg("husky/lint-staged", glob_re(r"(^|/)\.husky/") + [f for f, p in pkg.items() if "lint-staged" in p or "husky" in (p.get("devDependencies") or {})], "hook"))
tooling.append(cfg(".editorconfig", exists(".editorconfig"), "format"))
tooling = [t for t in tooling if t["config"]]
inv["tooling"] = tooling
wired = {}
for tool_kw in ("eslint", "biome", "prettier", "tsc", "mypy", "pyright", "ruff", "flake8", "pylint", "black", "golangci", "staticcheck", "clippy", "rubocop", "vet", "pytest", "jest", "vitest", "mocha", "go test", "cargo test", "rspec", "phpunit", "dotnet test", "gradle test", "mvn test"):
    where = []
    if re.search(r"\b" + re.escape(tool_kw) + r"\b", scripts_blob): where.append("package.json scripts")
    if re.search(r"\b" + re.escape(tool_kw) + r"\b", make_blob): where.append("Makefile/tox/nox/just")
    if where: wired[tool_kw] = where
inv["tooling_wired"] = wired
ts_strict = None
for f in ts_cfgs[:6]:
    t = re.sub(r"//.*|/\*.*?\*/", "", T(f), flags=re.S)
    m = re.search(r"\"strict\"\s*:\s*(true|false)", t)
    if m: ts_strict = (ts_strict or {}); ts_strict[f] = m.group(1) == "true"
    elif re.search(r"\"noImplicitAny\"\s*:\s*true", t): ts_strict = (ts_strict or {}); ts_strict[f] = "noImplicitAny only"
inv["ts_strict"] = ts_strict

# ---------- Q6 / Q7 tests ----------
test_files = [f for f in src if is_test(f)]
INTEG_RE = re.compile(r"supertest|TestClient\(|AsyncClient\(|testcontainers|@playwright/test|from playwright|cypress|selenium|webdriver|"
                      r"pytest\.mark\.(integration|e2e)|httptest\.NewServer|WebApplicationFactory|@SpringBootTest|MockMvc|rack/test|capybara|"
                      r"requests\.(get|post)\(\s*[f'\"]https?://(localhost|127\.0\.0\.1)|docker[- ]compose|localstack|pg_tmp|sqlite3\.connect|"
                      r"create_engine\(|mongomock|moto|nock\(|msw\b|@testing-library/react|render\(<", re.I)
integ_by_name = [f for f in test_files if re.search(r"(^|/)(integration|e2e|api|acceptance|functional|system)[^/]*/|\.(int|integration|e2e)\.", f, re.I)]
integ_by_content = [f for f in test_files if f not in integ_by_name and INTEG_RE.search(T(f))]
integration = integ_by_name + integ_by_content
unit = [f for f in test_files if f not in integration]
test_frameworks = sorted(d for d in ("jest", "vitest", "mocha", "jasmine", "ava", "@playwright/test", "cypress", "supertest", "pytest", "pytest-django",
                                     "unittest", "hypothesis", "rspec", "minitest", "testify", "ginkgo", "junit", "xunit", "nunit", "phpunit", "@testing-library/react") if d in deps)
if any(f.endswith("_test.go") for f in test_files): test_frameworks.append("go testing")
if any("import unittest" in T(f) for f in test_files[:200]): test_frameworks.append("unittest")
inv["tests"] = {"test_files": len(test_files), "unit_like": len(unit), "integration_like": len(integration), "integration_examples": integration[:15],
                "frameworks": sorted(set(test_frameworks)), "test_dirs": sorted({f.split("/")[0] + "/…" if "/" in f else f for f in test_files})[:10],
                "source_files_non_test": len(src) - len(test_files),
                "coverage_config": glob_re(r"(^|/)(\.coveragerc|codecov\.ya?ml|\.nycrc(\.\w+)?|jest\.config\.\w+|vitest\.config\.\w+)$")[:5]}

# ---------- Q10 CI ----------
ci = {"github_workflows": glob_re(r"^\.github/workflows/[^/]+\.ya?ml$"), "other": glob_re(r"(^|/)(\.gitlab-ci\.yml|\.circleci/config\.yml|Jenkinsfile|bitbucket-pipelines\.yml|azure-pipelines\.yml|\.travis\.yml|cloudbuild\.ya?ml|\.buildkite/)")}
gates = {}
for wf in ci["github_workflows"] + ci["other"]:
    t = T(wf)
    gates[wf] = {"on_pull_request": bool(re.search(r"pull_request|merge_request|pr:", t)),
                 "lint": bool(re.search(r"\b(eslint|biome|ruff|flake8|pylint|golangci|rubocop|clippy|lint)\b", t, re.I)),
                 "typecheck": bool(re.search(r"\b(tsc|mypy|pyright|typecheck|type-check)\b", t, re.I)),
                 "tests": bool(re.search(r"\b(pytest|jest|vitest|mocha|go test|cargo test|rspec|npm test|yarn test|pnpm test|dotnet test|gradle test|mvn test|phpunit|test)\b", t, re.I)),
                 "format": bool(re.search(r"\b(prettier|black|gofmt|rustfmt|ruff format|format:check|--check)\b", t, re.I)),
                 "audit": bool(re.search(r"\b(npm audit|pip-audit|cargo audit|govulncheck|trivy|snyk|dependabot|dependency-review|codeql|semgrep|bandit)\b", t, re.I)),
                 "coverage": bool(re.search(r"--coverage|--cov\b|cov-fail-under|coverageThreshold|codecov|coveralls|jacoco|llvm-cov|tarpaulin|-covermode|-coverprofile", t, re.I)),
                 "integration": bool(re.search(r"playwright|cypress|test:e2e|test:integration|testcontainers|docker[- ]compose|pytest.*(-m|--)\s*\w*(integration|e2e)|SpringBootTest", t, re.I)),
                 "continue_on_error": bool(re.search(r"continue-on-error:\s*true", t, re.I)),
                 "path_filtered": bool(re.search(r"^\s*paths(-ignore)?:", t, re.M))}
ci["gates"] = gates
ci["dependabot_or_renovate"] = glob_re(r"(^|/)(\.github/dependabot\.ya?ml|renovate\.json5?|\.renovaterc(\.json)?)$")
inv["ci"] = ci

# ---------- Q17 coverage config and thresholds ----------
COV_THRESHOLD_RE = [
    ("jest coverageThreshold", r"coverageThreshold[\s\S]{0,400}?(?:lines|branches|statements|functions)\s*:\s*(\d+)"),
    ("vitest coverage.thresholds", r"thresholds\s*:\s*\{[\s\S]{0,300}?(?:lines|branches)\s*:\s*(\d+)"),
    ("pytest --cov-fail-under", r"--cov-fail-under[= ](\d+)"),
    ("coverage.py fail_under", r"fail_under\s*=\s*(\d+)"),
    ("simplecov minimum_coverage", r"minimum_coverage\s+(\d+)"),
    ("coverlet Threshold", r"/p:Threshold=(\d+)"),
    ("cargo-llvm-cov fail-under", r"--fail-under-lines\s+(\d+)"),
    ("nyc/c8 check-coverage", r"(?:lines|branches)\s*[:=]\s*(\d+)"),   # only applied to .nycrc/.c8rc below
]
cov_cfg = glob_re(r"(^|/)(\.coveragerc|codecov\.ya?ml|\.codecov\.ya?ml|\.nycrc(\.\w+)?|\.c8rc(\.\w+)?)$")
cov_reports = glob_re(r"(^|/)(coverage\.xml|lcov\.info|coverage-final\.json|\.coverage|cobertura[\w-]*\.xml|jacocoTestReport\.xml)$")
cov_search_files = [f for f in files if base(f) in (
    "package.json", "pyproject.toml", "setup.cfg", "tox.ini", "pytest.ini", ".coveragerc", "Makefile", "justfile",
    "jest.config.js", "jest.config.ts", "jest.config.mjs", "jest.config.cjs", "vitest.config.ts", "vitest.config.js",
    "vitest.config.mts", "vite.config.ts", "spec_helper.rb", "rails_helper.rb", "build.gradle", "build.gradle.kts",
    ".nycrc", ".nycrc.json", "package-lock.json" if False else "package.json") or f.endswith((".csproj",))]
cov_search_files = sorted(set(cov_search_files)) + ci["github_workflows"] + ci["other"]
thresholds = []
for f in cov_search_files:
    t = T(f)
    if not t:
        continue
    for name, rx in COV_THRESHOLD_RE:
        if name.startswith("nyc/c8") and not re.search(r"\.(nycrc|c8rc)", f):
            continue          # the generic lines:/branches: shape would shadow vitest and jest
        for m in re.finditer(rx, t):
            thresholds.append({"file": f, "kind": name, "value": int(m.group(1))})
            break
seen_thr = set(); deduped = []
for t_ in thresholds:
    k = (t_["file"], t_["value"])
    if k in seen_thr:
        continue
    seen_thr.add(k); deduped.append(t_)
thresholds = deduped
jacoco_rule = [f for f in files if base(f) in ("build.gradle", "build.gradle.kts", "pom.xml") and re.search(r"jacocoTestCoverageVerification|<limit>", T(f))]
vitest_provider = any("@vitest/coverage" in json.dumps(p.get("devDependencies", {}) or {}) for p in pkg.values())
cov_config_keys = [f for f in cov_search_files if re.search(r"(vitest|vite|jest)\.config|package\.json$", f)
                   and re.search(r"coverage\s*:|collectCoverage|coverageThreshold|coverageReporters", T(f))]
cov_tooling = sorted({k for k, v in {
    "@vitest/coverage-*": vitest_provider,
    "vitest coverage configured (provider package NOT in devDependencies — the run cannot collect)":
        bool(cov_config_keys) and not vitest_provider and "vitest" in deps,
    "jest (built-in coverage)": "jest" in deps, "nyc": "nyc" in deps, "c8": "c8" in deps,
    "pytest-cov": any("pytest-cov" in n for n in deps) or "pytest-cov" in pyproject_txt or "--cov" in pyproject_txt + setupcfg_txt,
    "coverage.py": "coverage" in deps, "simplecov": "simplecov" in deps,
    "jacoco": bool(jacoco_rule) or any("jacoco" in T(f).lower() for f in manifests.get("build.gradle", [])),
    "coverlet": any("coverlet" in T(f) for f in glob_re(r"\.csproj$")),
    "cargo-llvm-cov / tarpaulin": bool(glob_re(r"(^|/)(llvm-cov|tarpaulin)\.toml$")) or "cargo-tarpaulin" in deps,
    "go (built-in -cover)": bool(manifests.get("go.mod")),
}.items() if v})
inv["coverage"] = {"config_files": cov_cfg, "committed_reports": cov_reports, "tooling": cov_tooling,
                   "thresholds": thresholds, "jacoco_verification_rule": jacoco_rule,
                   "max_threshold": max([x["value"] for x in thresholds], default=None),
                   "min_threshold": min([x["value"] for x in thresholds], default=None)}

# ---------- Q12 secrets ----------
SECRET_PATTERNS = [("AWS access key id", r"\bAKIA[0-9A-Z]{16}\b"), ("Stripe live key", r"\bsk_live_[0-9a-zA-Z]{16,}"), ("Stripe test key", r"\bsk_test_[0-9a-zA-Z]{16,}"),
                   ("private key block", r"-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY"), ("GitHub token", r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"),
                   ("Slack token", r"\bxox[abpr]-[0-9A-Za-z-]{10,}"), ("Google API key", r"\bAIza[0-9A-Za-z_-]{35}\b"), ("SendGrid key", r"\bSG\.[\w-]{20,}\.[\w-]{20,}"),
                   ("OpenAI/Anthropic-style key", r"\bsk-(ant-)?[A-Za-z0-9_-]{30,}"), ("JWT literal", r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\."),
                   ("connection string with password", r"\b(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqp)://[^:/\s'\"]+:[^@/\s'\"]{4,}@"),
                   ("hard-coded credential assignment", r"(?i)\b(password|passwd|secret|api_?key|access_?token|auth_?token|private_?key)\b\s*[:=]\s*['\"][^'\"\s]{8,}['\"]")]
FALSE_RE = re.compile(r"(?i)example|changeme|change_me|placeholder|your[_-]|xxx|dummy|fake|sample|<[^>]+>|\$\{|\{\{|process\.env|os\.environ|getenv|\*\*\*|redacted|todo|password_hash|hashed", re.I)
secrets = []
for f in files:
    if is_test(f) and "fixture" in f: continue
    t = T(f)
    if not t or f.endswith((".md", ".lock")): continue
    for name, rx in SECRET_PATTERNS:
        for m in re.finditer(rx, t):
            line = t.count("\n", 0, m.start()) + 1
            raw = t.split("\n")[line - 1]
            if name.startswith("hard-coded") and FALSE_RE.search(raw): continue
            if name == "AWS access key id" and "EXAMPLE" in m.group(0): continue
            secrets.append({"file": f, "line": line, "pattern": name, "redacted": m.group(0)[:4] + "…" + ("*" * min(8, len(m.group(0)) - 4))})
            if len(secrets) > 80: break
env_committed = [f for f in files if re.search(r"(^|/)\.env(\.[\w-]+)?$", f) and not re.search(r"\.(example|sample|template|dist|schema)$", f)]
inv["secrets"] = {"matches": secrets[:80], "env_files_committed": env_committed, "gitignore_has_env": any(re.search(r"^\s*\.env", T(f), re.M) for f in exists(".gitignore"))}

# ---------- Q13 lockfiles / pinning ----------
locks = {"package.json": glob_re(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|bun\.lock)$"),
         "python": glob_re(r"(^|/)(poetry\.lock|uv\.lock|Pipfile\.lock|pdm\.lock|requirements[\w.-]*\.txt)$"),
         "go.mod": exists("go.sum"), "Cargo.toml": exists("Cargo.lock"), "Gemfile": exists("Gemfile.lock"), "composer.json": exists("composer.lock"), "pubspec.yaml": exists("pubspec.lock")}
req_pinned = None
for f in manifests["requirements.txt"]:
    lines = [l.strip() for l in T(f).split("\n") if l.strip() and not l.startswith(("#", "-"))]
    if lines:
        req_pinned = req_pinned or {}
        req_pinned[f] = f"{sum(1 for l in lines if '==' in l)}/{len(lines)} pinned with =="
inv["lockfiles"] = {"present": {k: v for k, v in locks.items() if v}, "manifest_without_lock": [m for m in ("package.json", "go.mod", "Cargo.toml", "Gemfile", "composer.json", "pubspec.yaml") if manifests.get(m) and not locks.get(m)]
                    + (["python (pyproject/requirements without poetry/uv/pip lock)"] if (manifests["pyproject.toml"] or manifests["setup.py"]) and not glob_re(r"(^|/)(poetry\.lock|uv\.lock|Pipfile\.lock|pdm\.lock)$") and not manifests["requirements.txt"] else []),
                    "requirements_pinning": req_pinned}

# ---------- Q14 big files ----------
big = sorted([(f, n) for f, n in line_count.items() if n > 1000 and not is_test(f)], key=lambda x: -x[1])
inv["big_files"] = {"over_1000": big[:40], "over_500_count": sum(1 for f, n in line_count.items() if n > 500 and not is_test(f)), "largest": sorted(line_count.items(), key=lambda x: -x[1])[:10]}

# ---------- Q15 swallowed errors ----------
SWALLOW = [("empty catch (js/java/c#/php)", re.compile(r"catch\s*(\([^)]*\))?\s*\{\s*(//[^\n]*|/\*.*?\*/)?\s*\}", re.S)),
           ("promise .catch(() => {})", re.compile(r"\.catch\(\s*(\(\s*\w*\s*\)|\w+)\s*=>\s*(\{\s*\}|null|undefined|\{\})\s*\)")),
           ("bare except:", re.compile(r"^\s*except\s*:\s*(#.*)?$", re.M)),
           ("except ...: pass", re.compile(r"^\s*except\b[^\n]*:\s*(#.*)?\n\s*(pass|\.\.\.|return(\s+None)?|continue)\s*(#.*)?$", re.M)),
           ("rescue nil / empty rescue", re.compile(r"^\s*rescue\b[^\n]*(=>\s*\w+)?\s*\n\s*(nil|end)\s*$|rescue\s+nil", re.M)),
           ("go: error discarded", re.compile(r"^\s*_\s*(,\s*_\s*)*(:?=)\s*[\w.]+\(.*\)\s*$|if\s+err\s*!=\s*nil\s*\{\s*\}", re.M)),
           ("rust: .unwrap()/.expect() in non-test code", re.compile(r"\.unwrap\(\)|\.expect\("))]
swallowed = collections.defaultdict(list); swallow_counts = collections.Counter()
for f in src:
    if is_test(f): continue
    lang = language_of(f); t = T(f)
    for name, rx in SWALLOW:
        if name.startswith("go") and lang != "go": continue
        if name.startswith("rust") and lang != "rust": continue
        if name.startswith(("bare", "except")) and lang != "python": continue
        if name.startswith("rescue") and lang != "ruby": continue
        if name.startswith(("empty catch", "promise")) and lang not in ("javascript", "typescript", "java", "kotlin", "csharp", "php", "swift", "dart", "scala"): continue
        for m in rx.finditer(t):
            swallow_counts[name] += 1
            if len(swallowed[name]) < 25:
                swallowed[name].append(f"{f}:{t.count(chr(10), 0, m.start()) + 1}")
inv["swallowed_errors"] = {"counts": dict(swallow_counts), "examples": dict(swallowed)}

# ---------- Q19 real time in tests · Q20 change detectors ----------
# Durations are normalised to milliseconds so the per-run cost can be summed. Unit defaults follow
# each API: python/ruby/shell sleep take seconds, the JS and JVM ones milliseconds.
SLEEP_PATTERNS = [
    ("waitForTimeout", re.compile(r"waitForTimeout\(\s*([0-9_]+)"), 1),
    ("cy.wait(ms)", re.compile(r"cy\.wait\(\s*([0-9_]+)\s*\)"), 1),
    ("setTimeout in a promise", re.compile(r"setTimeout\(\s*(?:resolve|res|done|r)\s*,\s*([0-9_]+)"), 1),
    ("sleep()/delay() helper", re.compile(r"\b(?:await\s+)?(?:sleep|delay|wait)\(\s*([0-9_]+)\s*\)"), 1),
    ("time.sleep", re.compile(r"(?:time|asyncio)\.sleep\(\s*([0-9.]+)"), 1000),
    ("Thread.sleep", re.compile(r"Thread\.sleep\(\s*([0-9_]+)"), 1),
    ("thread::sleep", re.compile(r"thread::sleep\(.*?([0-9_]+)"), 1),
]
GO_SLEEP = re.compile(r"time\.Sleep\(\s*([0-9.]*)\s*\*?\s*time\.(Nanosecond|Microsecond|Millisecond|Second|Minute)")
GO_UNIT_MS = {"Nanosecond": 1e-6, "Microsecond": 1e-3, "Millisecond": 1, "Second": 1000, "Minute": 60000}
FAKE_CLOCK_RE = re.compile(
    r"useFakeTimers|advanceTimersByTime|installFakeTimers|fake-timers|sinon\.useFakeTimers|page\.clock|cy\.clock\(|"
    r"freeze_time|freezegun|time[-_]machine|pytest[-_]freezer|MockClock|Timecop|travel_to|travel\(|"
    r"clockwork|benbjohnson/clock|testing/synctest|synctest\.|FakeTimeProvider|TimeProvider|"
    r"tokio::time::(?:pause|advance)|Clock\.fixed|FrozenClock|ManualClock", re.I)
RETRY_RE = re.compile(r"\bretries\s*[:=]\s*[1-9]|--retries[= ][1-9]|rerun-?failures|reruns\s*[:=]\s*[1-9]|"
                      r"flaky\s*[:=]\s*true|test\.retry\(|@retry\b|RetryingTest", re.I)
CLOCK_CALL_RE = re.compile(r"Date\.now\(\)|new Date\(\s*\)|time\.time\(\)|datetime\.(?:now|utcnow)\(|"
                           r"time\.Now\(\)|Instant\.now\(|DateTime\.(?:Now|UtcNow)|Time\.now\b|SystemTime::now")
# No \b anchors: these appear as BACKOFF_SECONDS, is_expired, cacheAge — an underscore is a word
# character, so a trailing \b would miss exactly the spellings this needs to catch.
TIME_BEHAVIOUR_RE = re.compile(r"(?i)(expir|\bttl\b|ttl[_A-Z]|backoff|back_off|debounc|throttl|schedul|cron|"
                               r"rate[_ -]?limit|session[_ -]?timeout|cache[_ -]?age|retry_?(after|delay|interval))")

sleeps = []
for f in test_files:
    t = T(f)
    for name, rx, mult in SLEEP_PATTERNS:
        for m in rx.finditer(t):
            try: val = float(m.group(1).replace("_", ""))
            except ValueError: continue
            ms = val * mult
            if ms < 25:      # a 0-10ms yield is not a wait for real-world time
                continue
            sleeps.append({"file": f, "line": t.count("\n", 0, m.start()) + 1, "kind": name, "ms": int(ms)})
    for m in GO_SLEEP.finditer(t):
        n = float(m.group(1).replace("_", "")) if m.group(1) else 1.0
        sleeps.append({"file": f, "line": t.count("\n", 0, m.start()) + 1, "kind": "time.Sleep",
                       "ms": int(n * GO_UNIT_MS[m.group(2)])})
sleeps.sort(key=lambda x: -x["ms"])
fake_clock = sorted({f for f in files if FAKE_CLOCK_RE.search(T(f))})
retries = [f"{f}:{T(f).count(chr(10), 0, m.start()) + 1}" for f in files if not is_test(f) or True
           for m in [RETRY_RE.search(T(f))] if m][:12]
prod_src = [f for f in src if not is_test(f)]
clock_calls = sum(len(CLOCK_CALL_RE.findall(T(f))) for f in prod_src)
clock_files = [f for f in prod_src if CLOCK_CALL_RE.search(T(f))]
time_behaviour = sorted({f for f in prod_src if TIME_BEHAVIOUR_RE.search(T(f))})
inv["real_time_in_tests"] = {
    "fixed_sleeps": len(sleeps), "total_ms_per_run": sum(x["ms"] for x in sleeps),
    "worst": sleeps[:20], "by_kind": dict(collections.Counter(x["kind"] for x in sleeps)),
    "fake_clock_tooling_files": fake_clock, "retry_config": retries,
    "direct_clock_calls_in_source": clock_calls, "source_files_calling_the_clock": clock_files[:20],
    "source_files_with_time_dependent_behaviour": time_behaviour[:25]}

# --- Q20 change detectors
SNAP_FILE_RE = re.compile(r"(^|/)__snapshots__/|\.snap$|(^|/)(__file_snapshots__|snapshots)/|\.approved\.|\.golden$|(^|/)testdata/.*\.(golden|json|txt)$")
# `.snap` is on the generated-file exclude list that keeps line counts honest, so snapshots are not
# in `files` at all. For this question they ARE the evidence, so ask git for them directly.
_all_tracked = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
_tracked = [x for x in _all_tracked.stdout.decode("utf-8", "replace").split("\0") if x] if _all_tracked.returncode == 0 else files
snap_files = [f for f in _tracked if SNAP_FILE_RE.search(f) and "node_modules" not in f]
def _lines(rel):
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            return fh.read().count(b"\n") + 1
    except OSError:
        return 0
snap_sizes = sorted(((f, _lines(f)) for f in snap_files), key=lambda x: -x[1])
inline_snaps = sum(len(re.findall(r"toMatchInlineSnapshot|toMatchSnapshot|assert_match_snapshot|"
                                  r"snapshot\(|Approvals\.|verify\(.*golden", T(f))) for f in test_files)
update_habit = []
for k, v in pkg_scripts.items():
    if re.search(r"(-u\b|--update-snapshots?|--snapshot-update|UPDATE_SNAPSHOTS|--approve)", v):
        update_habit.append(f"{k}: {v[:80]}")
for wf in ci["github_workflows"] + ci["other"]:
    if re.search(r"(-u\b|--update-snapshots?|--snapshot-update)", T(wf)):
        update_habit.append(f"{wf}: CI regenerates snapshots")
MOCK_ASSERT_RE = re.compile(r"toHaveBeenCalled|toBeCalled|assert_called|assert_has_calls|"
                            r"sinon\.assert|verify\(|\.received\(|Mockito\.verify|mock_calls", re.I)
OUTCOME_ASSERT_RE = re.compile(r"toEqual|toBe\(|toStrictEqual|toMatchObject|assertEqual|assert\s+\w+\s*==|"
                               r"expect\(.*\)\.to(?!HaveBeenCalled)|assert\.(Equal|True|NoError)|should\s*==|"
                               r"assertThat", re.I)
mock_only = []
for f in test_files:
    t = T(f)
    m_calls = len(MOCK_ASSERT_RE.findall(t)); o_calls = len(OUTCOME_ASSERT_RE.findall(t))
    if m_calls >= 3 and o_calls <= max(1, m_calls // 6):
        mock_only.append({"file": f, "mock_assertions": m_calls, "outcome_assertions": o_calls})
mock_only.sort(key=lambda x: -x["mock_assertions"])

# lockstep churn: how often a test file changes in the same commit as the source it covers
def commits_for(path):
    r = subprocess.run(["git", "-C", root, "log", "--format=%H", "--", path], capture_output=True, text=True)
    return set(r.stdout.split()) if r.returncode == 0 else set()
lockstep = []
src_by_stem = {}
for f in prod_src:
    src_by_stem.setdefault(re.sub(r"\.\w+$", "", f.rsplit("/", 1)[-1]).lower(), []).append(f)
for tf in test_files:
    stem = re.sub(r"\.(test|spec)\b.*$|\.\w+$", "", tf.rsplit("/", 1)[-1], flags=re.I).lower()
    stem = re.sub(r"^test_", "", stem)
    cands = src_by_stem.get(stem) or []
    if len(cands) != 1:
        continue
    sf = cands[0]
    tc, sc = commits_for(tf), commits_for(sf)
    if len(sc) < 4:
        continue
    both = len(tc & sc)
    ratio = both / len(sc)
    if ratio >= 0.6:
        lockstep.append({"test": tf, "source": sf, "source_commits": len(sc), "together": both,
                         "ratio": round(ratio, 2),
                         "has_snapshot_or_mock": bool(re.search(r"toMatchSnapshot|toMatchInlineSnapshot", T(tf))) or
                                                any(x["file"] == tf for x in mock_only)})
lockstep.sort(key=lambda x: (-x["ratio"], -x["source_commits"]))
inv["change_detectors"] = {
    "snapshot_files": len(snap_files), "largest_snapshots": snap_sizes[:10],
    "snapshot_assertions_in_tests": inline_snaps, "update_snapshot_habit": update_habit,
    "mock_assertion_heavy_files": mock_only[:15], "lockstep_candidates": lockstep[:15]}

# ---------- Q2 dead-code signals ----------
todo = collections.Counter(); todo_files = collections.Counter()
commented_code = []
for f in src:
    t = T(f)
    for m in re.finditer(r"\b(TODO|FIXME|HACK|XXX|DEPRECATED)\b", t):
        todo[m.group(1)] += 1; todo_files[f] += 1
    lines = t.split("\n"); run = 0; start = 0
    lang = language_of(f)
    cm = re.compile(r"^\s*(//|#)\s*(.*)$")
    for i, l in enumerate(lines, 1):
        m = cm.match(l)
        codey = bool(m and re.search(r"[;{}()=]\s*$|^\s*(def|return|if|for|while|import|from|const|let|var|function|class|self\.|this\.)\b", m.group(2) or "") and not re.match(r"^\s*(TODO|NOTE|eslint|type:|noqa|pylint|prettier|@)", m.group(2) or ""))
        if codey:
            run += 1; start = start or i
        else:
            if run >= 5: commented_code.append(f"{f}:{start}-{i-1} ({run} lines)")
            run = 0; start = 0
    if run >= 5: commented_code.append(f"{f}:{start}-{len(lines)} ({run} lines)")
# unreferenced top-level definitions / exports (candidates only)
defs = []
name_rx_cache = {}
ENTRY_RE = re.compile(r"(^|/)(main|app|server|index|cli|manage|wsgi|asgi|conftest|setup|settings|urls|__main__|routes?|handler|lambda_function)\.\w+$")
for f in src:
    if is_test(f) or ENTRY_RE.search(f): continue
    t = T(f); lang = language_of(f)
    names = []
    if lang == "python":
        names = re.findall(r"^(?:def|class)\s+([A-Za-z]\w{3,})\s*[(:]", t, re.M)
    elif lang in ("javascript", "typescript"):
        names = re.findall(r"^export\s+(?:default\s+)?(?:async\s+)?(?:function\*?|class|const|let|var|enum)\s+([A-Za-z_$]\w{3,})", t, re.M)
        for grp in re.findall(r"^export\s*\{([^}]*)\}", t, re.M):
            names += [p.strip().split(" as ")[-1].strip() for p in grp.split(",") if p.strip()]
    elif lang == "go":
        names = re.findall(r"^func\s+(?:\([^)]*\)\s*)?([A-Z]\w{3,})\s*\(", t, re.M)
    elif lang == "ruby":
        names = re.findall(r"^\s*def\s+(?:self\.)?([a-z_]\w{3,})", t, re.M)
    for n in set(names):
        if n.startswith("_") or n.lower() in ("main", "setup", "init", "index", "default", "handler", "props", "state", "types"): continue
        defs.append((f, n))
if len(defs) <= 4000:
    blob_by_file = {f: T(f) for f in src}
    unref = []
    for f, n in defs:
        rx = re.compile(r"(?<![\w$])" + re.escape(n) + r"(?![\w$])")
        hits = 0
        for g, t in blob_by_file.items():
            if g == f: continue
            if rx.search(t): hits = 1; break
        if not hits:
            # also allow references in non-source files (templates, yaml, html)
            if any(rx.search(T(g)) for g in files if not is_source(g) and g != f and g.endswith((".html", ".yml", ".yaml", ".json", ".toml", ".jinja", ".j2", ".erb", ".vue", ".svelte", ".md"))):
                continue
            unref.append(f"{f}: {n}")
    inv["dead_code"] = {"todo_counts": dict(todo), "todo_top_files": todo_files.most_common(8), "commented_out_code_runs": commented_code[:30],
                        "unreferenced_definitions_candidates": unref[:80], "unreferenced_definitions_total": len(unref), "definitions_checked": len(defs)}
else:
    inv["dead_code"] = {"todo_counts": dict(todo), "todo_top_files": todo_files.most_common(8), "commented_out_code_runs": commented_code[:30],
                        "unreferenced_definitions_candidates": [], "unreferenced_definitions_total": None, "definitions_checked": len(defs), "note": "too many definitions for the naive cross-reference; use knip/vulture/deadcode"}

# ---------- Q9 types ----------
types = {}
if "typescript" in lang_files or "javascript" in lang_files:
    js_only = lang_files.get("javascript", 0); ts = lang_files.get("typescript", 0)
    any_count = ig = 0
    for f in src:
        if language_of(f) == "typescript" and not is_test(f):
            t = T(f); any_count += len(re.findall(r"(?<![\w$])any(?![\w$])", re.sub(r"//.*|/\*.*?\*/", "", t, flags=re.S))); ig += len(re.findall(r"@ts-(ignore|nocheck)", t))
    types["typescript"] = {"ts_files": ts, "js_files": js_only, "strict": ts_strict, "any_occurrences_non_test": any_count, "ts_ignore": ig}
if "python" in lang_files:
    total = annotated = ignores = 0
    for f in src:
        if language_of(f) != "python" or is_test(f): continue
        t = T(f)
        for m in re.finditer(r"^\s*(?:async\s+)?def\s+\w+\s*\(([^)]*)\)\s*(->)?", t, re.M):
            total += 1
            params = m.group(1); non_self = [p for p in params.split(",") if p.strip() and p.strip().split(":")[0].strip() not in ("self", "cls")]
            if m.group(2) or any(":" in p for p in non_self): annotated += 1
        ignores += len(re.findall(r"#\s*type:\s*ignore", t))
    types["python"] = {"functions": total, "annotated": annotated, "annotated_pct": round(100.0 * annotated / total, 1) if total else None, "type_ignore": ignores,
                       "py_typed": bool(exists("py.typed")), "checker_config": [t_["tool"] for t_ in tooling if t_["tool"] in ("mypy", "pyright/pylance")]}
for l in ("go", "rust", "java", "kotlin", "csharp", "swift", "scala", "dart"):
    if l in lang_files: types[l] = "statically typed by language"
if "ruby" in lang_files: types["ruby"] = {"sorbet_or_rbs": bool([t_ for t_ in tooling if t_["tool"] == "sorbet/rbs"])}
if "php" in lang_files: types["php"] = {"strict_types_files": sum(1 for f in src if language_of(f) == "php" and "declare(strict_types=1)" in T(f)), "php_files": lang_files["php"]}
inv["types"] = types

# ---------- README ----------
readme = glob_re(r"^readme(\.\w+)?$|^README(\.\w+)?$")
rt = T(readme[0]).lower() if readme else ""
inv["readme"] = {"file": readme[0] if readme else None, "lines": rt.count("\n") if rt else 0,
                 "mentions": {k: bool(re.search(v, rt)) for k, v in {"install/setup": r"install|setup|getting started|prerequisite", "run/start": r"\brun\b|start|serve|docker compose|make dev|npm run dev", "test": r"\btest", "env vars": r"\.env|environment variable|env var", "architecture": r"architecture|structure|overview|how it works"}.items()},
                 "claude_md": exists("CLAUDE.md"), "contributing": glob_re(r"^CONTRIBUTING(\.\w+)?$"), "docs_dir": bool(glob_re(r"^docs?/"))}

# ---------- from the other scripts ----------
ig = L("import-graph.json"); ep = L("endpoints.json"); dup = L("dup-blocks.json")
tools = sorted(x for x in os.listdir(out) if x.startswith("tool-") and x.endswith(".txt"))
inv["analyzer_outputs"] = tools
with open(os.path.join(out, "inventory.json"), "w") as fh:
    json.dump(inv, fh, indent=1, default=str)

# ---------- DIGEST.md ----------
md = [f"# Code quality inventory — `{root}` — {inv['date']}", "",
      "Mechanical evidence for the twenty questions in `references/quality-checklist.md`. Every line here is a pointer: open the file before you cite it. "
      "Suggested answers are mechanical and can be wrong in both directions.", ""]
def sec(t): md.extend(["", f"## {t}", ""])
def yesno(b): return "yes" if b else "NO"

sec("Stack")
md.append("| Language | Files | Lines |"); md.append("|---|---|---|")
for l, d in inv["languages"].items(): md.append(f"| {l} | {d['files']} | {d['lines']} |")
md.append(""); md.append("Manifests: " + (", ".join(f"`{k}` ×{len(v)}" for k, v in inv["manifests"].items()) or "none found"))
md.append(f"Source files (non-test): {inv['tests']['source_files_non_test']} · test files: {inv['tests']['test_files']}")

sec("Q1. Lint / type-check / format tooling (recommended: yes, and enforced)")
if tooling:
    md.append("| Tool | Kind | Config |"); md.append("|---|---|---|")
    for t_ in tooling: md.append(f"| {t_['tool']} | {t_['kind']} | {', '.join(t_['config'])} |")
else:
    md.append("**No lint/type/format configuration found.**")
md.append(""); md.append("Wired into scripts: " + (", ".join(f"`{k}` ({'; '.join(v)})" for k, v in wired.items()) or "**nothing** — no lint/type/test command in package.json scripts, Makefile, tox or nox"))
lint_for = {"python": ("ruff", "flake8", "pylint"), "typescript": ("eslint", "biome"), "javascript": ("eslint", "biome"), "go": ("golangci-lint", "staticcheck"), "rust": ("clippy/rustfmt",), "ruby": ("rubocop",), "java": ("checkstyle/spotbugs/pmd",), "kotlin": ("detekt/ktlint",), "php": ("phpstan/psalm",), "swift": ("swiftlint",), "csharp": ("dotnet analyzers (.editorconfig dotnet_* rules)",)}
type_for = {"python": ("mypy", "pyright/pylance"), "typescript": ("typescript (tsconfig)",), "javascript": ("typescript (tsconfig)",), "ruby": ("sorbet/rbs",), "php": ("phpstan/psalm",)}
have = {t_["tool"] for t_ in tooling}
for l in primary:
    if l in lint_for: md.append(f"- {l}: linter {yesno(any(x in have for x in lint_for[l]))}" + (f", type checker {yesno(any(x in have for x in type_for[l]))}" if l in type_for else ", statically typed by language"))
if ts_strict is not None: md.append(f"- tsconfig strict: {ts_strict}")

sec("Q2. Dead code (recommended: none)")
dc = inv["dead_code"]
md.append(f"- TODO/FIXME/HACK/XXX/DEPRECATED markers: {dict(dc['todo_counts']) or 0}" + (f" — top files: {', '.join(f'{f} ({n})' for f, n in dc['todo_top_files'][:5])}" if dc["todo_top_files"] else ""))
md.append(f"- Commented-out code runs (≥5 code-looking comment lines): {len(dc['commented_out_code_runs'])}" + (" — " + "; ".join(dc["commented_out_code_runs"][:8]) if dc["commented_out_code_runs"] else ""))
if dc.get("unreferenced_definitions_total") is not None:
    md.append(f"- Top-level definitions/exports with no reference anywhere else in the repo: **{dc['unreferenced_definitions_total']}** of {dc['definitions_checked']} checked (candidates — frameworks call handlers by convention; verify each):")
    for x in dc["unreferenced_definitions_candidates"][:40]: md.append(f"  - {x}")
else:
    md.append(f"- {dc.get('note')}")
md.append("- Tool runs (knip / ts-prune / vulture / deadcode / cargo-machete): " + (", ".join(t for t in tools if re.search(r"knip|prune|vulture|deadcode|machete", t)) or "none — run `scripts/run-analyzers.sh`"))

sec("Q3. Endpoints require authentication (recommended: yes, where the app has auth) · Q4. Dead endpoints (recommended: none)")
if ep and ep["summary"]["total"]:
    s = ep["summary"]
    md.append(f"Frameworks: {', '.join(ep['frameworks'])} · endpoints: {s['total']} · router mounts resolved {s['mounts_resolved']}/{s['mounts_total']}")
    md.append(f"Auth status: {s['by_auth']} · global auth evidence: {s['global_auth_evidence']}")
    if ep["global_auth"]:
        md.append(""); md.append("Global / app-level auth evidence (confirm what it covers and what is excluded):")
        for g in ep["global_auth"][:10]: md.append(f"- {g['file']}:{g['line']} — {g['kind']}: `{g['text']}`")
    md.append(""); md.append("| Auth | Method | Path | Where | Refs (prod+test) | Prefix refs | Evidence |"); md.append("|---|---|---|---|---|---|---|")
    for e in ep["endpoints"][:150]:
        refs = "n/a" if e["references"] == -1 else f"{e['references_prod']}+{e['references_test']}"
        md.append(f"| {'**' + e['auth'] + '**' if e['auth'] == 'none-seen' else e['auth']} | {e['method']} | `{e['path']}` | {e['file']}:{e['line']} | {refs} | {e['prefix_references']} | {e['auth_evidence'][:70].replace('|', '/')} |")
    if s["total"] > 150: md.append(f"… {s['total'] - 150} more in endpoints.json")
    md.append(""); md.append(f"- **none-seen**: {s['by_auth']['none-seen']} endpoint(s) with nothing auth-looking on the route, its router, or its mount. If the app has global auth middleware these may be fine; if not, each is a finding.")
    md.append(f"- **No references anywhere** (full path): {s['no_references']}; not even by static prefix: {s['no_references_even_by_prefix']}. These are dead-endpoint candidates; check OpenAPI consumers, mobile apps, cron/webhooks, and other repos before calling one dead.")
else:
    md.append("No HTTP endpoints detected (or no supported framework). If the app has an API, say what framework it uses and find the routes by hand. Q3/Q4 may be N/A for a library or CLI.")

sec("Q5. Duplicate code (recommended: none)")
if dup:
    md.append(f"- Window {dup['window']} normalised lines · files scanned {dup['files_scanned']} · production duplication ≈ **{dup['duplication_pct']['prod']}%** ({dup['duplicated_lines']['prod']} of {dup['normalized_lines']['prod']} lines), tests ≈ {dup['duplication_pct']['test']}%")
    md.append(f"- {dup['groups']} duplicate group(s); largest:")
    for r in dup["largest_groups"][:15]:
        md.append(f"  - {r['normalized_lines']} lines ×{r['copies']}: " + ", ".join(f"{e['file']}:{e['start_line']}-{e['end_line']}" for e in r["locations"][:4]) + f" — `{r['snippet'][:60]}`")
    md.append("- jscpd / pylint duplicate-code run: " + (", ".join(t for t in tools if "jscpd" in t or "pylint" in t) or "none"))
else:
    md.append("dup-blocks.json missing — run `scripts/dup-blocks.py`.")

sec("Q6. Unit tests (recommended: yes) · Q7. Integration tests (recommended: yes)")
ts_ = inv["tests"]
md.append(f"- Test files: {ts_['test_files']} against {ts_['source_files_non_test']} source files · frameworks: {', '.join(ts_['frameworks']) or 'none detected in deps'}")
md.append(f"- Unit-like: {ts_['unit_like']} · integration-like (by directory name or by content: HTTP client, DB, browser, containers): {ts_['integration_like']}")
for x in ts_["integration_examples"][:10]: md.append(f"  - {x}")
md.append(f"- Coverage config: {', '.join(ts_['coverage_config']) or 'none'}")
md.append("- Whether the suite passes is not known from this scan; run it (unit only unless it needs no external service).")

sec("Q8. Dependency graph is a DAG (recommended: yes)")
if ig:
    md.append(f"- {ig['nodes']} files, {ig['edges']} intra-repo edges ({ig['languages']}) · unresolved relative imports: {ig['unresolved_relative_imports']}")
    md.append(f"- Acyclic: **{yesno(ig['acyclic'])}** · cycle groups: {ig['cycle_count']} · files in cycles: {ig['files_in_cycles']} · largest group: {ig['largest_cycle']} · self-imports: {len(ig['self_imports'])}")
    for c in ig["cycles"][:12]: md.append("  - " + " ↔ ".join(c[:6]) + (f" (+{len(c) - 6} more)" if len(c) > 6 else ""))
    md.append("- Highest fan-in (everything depends on these): " + ", ".join(f"{f} ({n})" for f, n in ig["top_fan_in"][:6]))
    md.append("- Fan-out ≥ 20 (god modules): " + (", ".join(ig["high_fan_out_files"][:10]) or "none"))
    md.append("- madge / Go and Rust compilers: " + (", ".join(t for t in tools if "madge" in t) or "madge not run; Go/Rust reject cycles at compile time"))
else:
    md.append("import-graph.json missing — run `scripts/import-graph.py`.")

sec("Q9. Types (recommended: yes)")
for l, d in types.items(): md.append(f"- {l}: {d}")
if not types: md.append("- no typed-language evidence")

sec("Q10. CI exists and gates every PR: lint, types, unit tests, integration, coverage (recommended: yes, blocking)")
if gates:
    md.append("| Workflow | on PR | lint | typecheck | unit tests | integration | coverage | format | audit | continue-on-error | path filter |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for wf, g in gates.items():
        md.append(f"| {wf} | {yesno(g['on_pull_request'])} | {yesno(g['lint'])} | {yesno(g['typecheck'])} | {yesno(g['tests'])} | "
                  f"{yesno(g['integration'])} | {yesno(g['coverage'])} | {yesno(g['format'])} | {yesno(g['audit'])} | "
                  f"{'**yes**' if g['continue_on_error'] else 'no'} | {'yes — confirm a merged PR actually ran the steps' if g['path_filtered'] else 'no'} |")
else:
    md.append("**No CI configuration found** (.github/workflows, GitLab, CircleCI, Jenkins, Bitbucket, Azure, Buildkite).")
md.append(f"- Dependabot/Renovate: {', '.join(ci['dependabot_or_renovate']) or 'none'}")
md.append("- Whether any of this is **required** (rather than advisory) is branch protection — see Q18 below, which reads the same API.")
if gates:
    missing = [k for k in ("lint", "typecheck", "tests", "integration", "coverage") if not any(g.get(k) for g in gates.values())]
    onpr = [w for w, g in gates.items() if g["on_pull_request"]]
    md.append(f"- Workflows triggering on pull requests: {', '.join(onpr) or '**none — CI runs only after merge**'}")
    md.append(f"- Gates absent from every workflow: {', '.join(missing) if missing else 'none — all five present somewhere'}")
    md.append("- A `continue-on-error: true` or a `paths:` filter above means a green check may have run nothing; confirm on a recent merged PR.")

sec("Q11. Committed secrets (recommended: none)")
sc = inv["secrets"]
md.append(f"- Pattern matches: **{len(sc['matches'])}**" + (" (redacted; verify each — test fixtures and docs produce false positives):" if sc["matches"] else ""))
for m in sc["matches"][:30]: md.append(f"  - {m['file']}:{m['line']} — {m['pattern']} `{m['redacted']}`")
md.append(f"- `.env` files tracked in git: {', '.join(sc['env_files_committed']) or 'none'} · .gitignore covers .env: {yesno(sc['gitignore_has_env'])}")
md.append("- History is not scanned here: `git log -p -S <fragment>` or gitleaks/trufflehog for a real answer.")

sec("Q12. Lockfile committed and dependencies audited (recommended: yes)")
lk = inv["lockfiles"]
md.append("- Lockfiles: " + (", ".join(f"{k}: {', '.join(v)}" for k, v in lk["present"].items()) or "none"))
md.append("- Manifests without a lockfile: " + (", ".join(lk["manifest_without_lock"]) or "none"))
if lk["requirements_pinning"]: md.append("- requirements pinning: " + "; ".join(f"{k} {v}" for k, v in lk["requirements_pinning"].items()))
md.append("- Audit runs: " + (", ".join(t for t in tools if re.search(r"audit|vulncheck", t)) or "none — run-analyzers.sh runs npm audit / pip-audit / cargo audit / govulncheck when installed"))

sec("Q13. Oversized files (recommended: none over 1000 lines)")
bf = inv["big_files"]
md.append(f"- Non-test source files over 1000 lines: **{len(bf['over_1000'])}** · over 500: {bf['over_500_count']}")
for f, n in bf["over_1000"][:20]: md.append(f"  - {f}: {n} lines")
md.append("- Largest overall: " + ", ".join(f"{f} ({n})" for f, n in bf["largest"][:5]))

sec("Q14. Swallowed errors (recommended: none)")
se = inv["swallowed_errors"]
md.append(f"- Counts: {se['counts'] or 'none found'}")
for k, v in se["examples"].items(): md.append(f"  - {k}: " + ", ".join(v[:10]) + (f" … (+{se['counts'][k] - 10})" if se["counts"][k] > 10 else ""))

sec("Q15. README documents setup, run, test (recommended: yes)")
rd = inv["readme"]
md.append(f"- README: {rd['file'] or '**missing**'} ({rd['lines']} lines) · mentions: {rd['mentions']} · CLAUDE.md: {yesno(rd['claude_md'])} · CONTRIBUTING: {yesno(rd['contributing'])} · docs/: {yesno(rd['docs_dir'])}")

sec("Q16. Baseline ESLint rule coverage (recommended: 100%)")
md.append("Not computed here: it needs the repo's *effective* config. Run `npx --no-install eslint --print-config <a real .ts file>` and the coverage snippet in `references/quality-checklist.md` §Q16 against `references/eslint-baseline.config.mjs` (105 rules)." if ("typescript" in lang_files or "javascript" in lang_files) else "N/A — no TypeScript/JavaScript in this repo; Q1 covers the equivalent for " + ", ".join(primary) + ".")

sec("Q17. Test coverage >= 80% on lines and branches, threshold enforced (recommended: yes)")
cv = inv["coverage"]
md.append(f"- Coverage tooling present: {', '.join(cv['tooling']) or '**none found**'}")
md.append(f"- Coverage config files: {', '.join(cv['config_files']) or 'none'}")
if cv["thresholds"]:
    md.append(f"- **Thresholds configured** (highest {cv['max_threshold']}%):")
    for t_ in cv["thresholds"][:10]:
        md.append(f"  - {t_['file']}: {t_['kind']} = {t_['value']}%")
else:
    md.append("- **No coverage threshold found anywhere** — nothing fails the build when coverage drops.")
if cv["jacoco_verification_rule"]:
    md.append(f"- jacoco verification rule in: {', '.join(cv['jacoco_verification_rule'])}")
if cv["committed_reports"]:
    md.append(f"- Coverage reports committed (usually should be gitignored): {', '.join(cv['committed_reports'][:5])}")
md.append(f"- CI runs coverage: {yesno(any(g.get('coverage') for g in gates.values())) if gates else 'no CI found'}")
if cv["thresholds"] and not cv["tooling"]:
    md.append("- **A threshold is configured but no coverage provider was found** — the run either fails or silently reports nothing. Check this first.")
low = [t_ for t_ in cv["thresholds"] if t_["value"] < 80]
if low:
    md.append("- **Thresholds below the recommended 80%** (each sets the real floor for its own package): "
              + ", ".join(f"{t_['file']} at {t_['value']}%" for t_ in low))
md.append("- **The percentage is not computed here.** Run the suite with coverage on (`references/quality-checklist.md` §Q17), record lines *and* branches, read the include/exclude list, and get per-file numbers so the report can name the lowest-covered files that matter. Never estimate it.")

sec("Q18. Force-push and deletion blocked on the default branch (recommended: yes)")
bp = L("branch-protection.json")
rs = L("rulesets.json")
if isinstance(bp, dict) and bp and "error" not in bp:
    def en(k):
        v = bp.get(k) or {}
        return bool(v.get("enabled")) if isinstance(v, dict) else False
    md.append(f"- Force-push allowed: **{'YES — finding' if en('allow_force_pushes') else 'no (blocked)'}**")
    md.append(f"- Deletion allowed: **{'YES — finding' if en('allow_deletions') else 'no (blocked)'}**")
    md.append(f"- Binds admins (`enforce_admins`): **{'yes' if en('enforce_admins') else 'NO — protection does not apply to admins'}**")
    checks = ((bp.get("required_status_checks") or {}).get("contexts") or [])
    md.append(f"- Required status checks: {', '.join(checks) if checks else '**none**'} (Q10)")
elif isinstance(bp, dict) and "error" in bp:
    md.append(f"- Classic branch protection: **not readable** — {str(bp['error'])[:160]}")
    md.append("  A `Branch not protected` 404 is not a tooling problem: it means the default branch is unprotected, which is the finding.")
else:
    md.append("- Classic branch protection: not read (no `gh`, or not a GitHub remote). Run the Q18 commands, or ask.")
if isinstance(rs, list):
    if not rs:
        md.append("- Rulesets: **none** — classic protection above is the only mechanism.")
    for r in rs[:10]:
        md.append(f"  - ruleset `{r.get('name')}` target={r.get('target')} enforcement={r.get('enforcement')}")
    if rs:
        md.append("  - Read each ruleset's `rules[].type` for `non_fast_forward` (the force-push block) and `deletion`, and its `bypass_actors` — a standing bypass makes the rule decorative for those actors.")
md.append("- Also worth asking, outside this repo: can org members delete repositories, and does a second copy of this history exist anywhere?")

sec("Q19. Tests do not wait on real-world time; the clock is faked (recommended: yes)")
rt = inv["real_time_in_tests"]
tot = rt["total_ms_per_run"]
md.append(f"- **Fixed sleeps in tests: {rt['fixed_sleeps']}**, totalling **{tot/1000:.1f} s per run** "
          f"({rt['by_kind'] or 'none'})")
for x in rt["worst"][:12]:
    md.append(f"  - {x['ms']:>6} ms  {x['file']}:{x['line']}  ({x['kind']})")
md.append(f"- Clock-faking tooling seen in: {', '.join(rt['fake_clock_tooling_files'][:8]) or '**nowhere in the repo**'}")
if rt["retry_config"]:
    md.append(f"- Retry configuration present ({len(rt['retry_config'])} site(s)): {', '.join(rt['retry_config'][:6])} — check whether it exists to absorb timing flakiness")
md.append(f"- Source files calling the clock directly: **{len(rt['source_files_calling_the_clock'])}** ({rt['direct_clock_calls_in_source']} calls) — time cannot be faked where it is not injected")
if rt["source_files_with_time_dependent_behaviour"] and not rt["fake_clock_tooling_files"]:
    md.append("- **Time-dependent behaviour with no clock-faking anywhere** — expiry/TTL/backoff/scheduling logic in "
              + ", ".join(rt["source_files_with_time_dependent_behaviour"][:8])
              + ". Nobody tests a 30-day expiry by waiting, so check whether these paths are tested at all (cross-reference Q17 per-file numbers).")
md.append("- A poll with a deadline is **not** a finding; only a fixed duration is. Confirm the list above against the runner's own slowest-test output before reporting it.")

sec("Q20. No change-detector tests (recommended: none)")
cd_ = inv["change_detectors"]
md.append(f"- Snapshot / golden files: **{cd_['snapshot_files']}** · snapshot assertions in tests: {cd_['snapshot_assertions_in_tests']}")
for f, n in cd_["largest_snapshots"][:8]:
    md.append(f"  - {n:>6} lines  {f}" + ("   ← nobody reads a diff this size" if n > 300 else ""))
if cd_["update_snapshot_habit"]:
    md.append("- **Snapshots are regenerated by a script or CI** (approval by regeneration, not review): " + "; ".join(cd_["update_snapshot_habit"][:5]))
if cd_["mock_assertion_heavy_files"]:
    md.append("- Test files whose assertions are mostly about **calls rather than outcomes**:")
    for x in cd_["mock_assertion_heavy_files"][:8]:
        md.append(f"  - {x['file']}: {x['mock_assertions']} mock assertions vs {x['outcome_assertions']} outcome assertions")
else:
    md.append("- No test file is dominated by mock-call assertions.")
if cd_["lockstep_candidates"]:
    md.append("- **Lockstep churn** — test files changing in the same commits as the source they cover. A test coupled to behaviour changes rarely; one coupled to implementation changes every time. Candidates, not verdicts: open them before calling it.")
    md.append("")
    md.append("| Test | Source | Source commits | Changed together | Ratio | Snapshot/mock |")
    md.append("|---|---|---|---|---|---|")
    for x in cd_["lockstep_candidates"][:10]:
        md.append(f"| {x['test']} | {x['source']} | {x['source_commits']} | {x['together']} | **{x['ratio']}** | {'yes' if x['has_snapshot_or_mock'] else 'no'} |")
else:
    md.append("- Lockstep churn: no test/source pair changes together in 60%+ of the source's commits (or the history is too short to tell).")
md.append("- The shape no tool finds: a test that computes its expected value with the code under test. Read the largest test files for that.")

sec("Analyzer outputs present")
md.append(", ".join(f"`{t}`" for t in tools) if tools else "none — run `scripts/run-analyzers.sh --repo <repo> --out <out>` for eslint/tsc/mypy/ruff/knip/vulture/jscpd/madge/audit output.")

with open(os.path.join(out, "DIGEST.md"), "w") as fh:
    fh.write("\n".join(md) + "\n")
print(f"wrote {out}/inventory.json and {out}/DIGEST.md")
