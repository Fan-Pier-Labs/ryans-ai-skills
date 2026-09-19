#!/usr/bin/env bash
# code-quality-audit: run whichever linters / type checkers / dead-code / duplication / audit
# tools are ALREADY INSTALLED, read-only, and save their output next to the inventory.
#
#   scripts/run-analyzers.sh [--repo <dir>] [--out <dir>] [--check] [--no-network] [--only "eslint tsc"]
#
# Never installs anything (npx runs with --no-install), never passes --fix / --write, never
# modifies the repo. Each tool's output goes to <out>/tool-<name>[-<subdir>].txt with the
# exit code on the first line. Tools that are not installed are listed as skipped, each with
# the command that would install it.
#
# --check runs NOTHING. It only reports which analyzers this repo would use, which are
# present, and the exact install command for each missing one — the dependency preflight,
# so the audit asks once up front instead of stalling mid-run. See
# skills/shared/dependency-preflight.md for what to do with the answer.
# --no-network skips npm audit / pip-audit / cargo audit / govulncheck / bundle audit.
set -uo pipefail
REPO="."; OUT=""; NET=1; ONLY=""; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --check) CHECK=1; shift;;
    --no-network) NET=0; shift;;
    --only) ONLY="$2"; shift 2;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
REPO="$(cd "$REPO" && pwd)"; [ -z "$OUT" ] && OUT="$REPO/../code-quality-audit-$(basename "$REPO")-$(date +%Y-%m-%d)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SKIPPED=""; RAN=""; MISS="$OUT/.missing-tools"; : > "$MISS"
want() { [ -z "$ONLY" ] || [[ " $ONLY " == *" $1 "* ]]; }
has() { command -v "$1" >/dev/null 2>&1; }
npx_has() { (cd "$1" && npx --no-install "$2" --version >/dev/null 2>&1); }
run() {  # run <name> <dir> <cmd...>
  local name="$1" dir="$2"; shift 2
  local tag="$name"; [ "$dir" != "$REPO" ] && tag="$name-$(echo "${dir#$REPO/}" | tr '/' '_')"
  if [ "$CHECK" = 1 ]; then RAN="$RAN $tag"; return 0; fi   # --check never executes a tool
  local f="$OUT/tool-$tag.txt"
  echo "  run  $tag: $*"
  ( cd "$dir" && "$@" ) > "$f.body" 2>&1; local rc=$?
  { echo "# exit=$rc cmd: $* (in ${dir#$REPO/})"; head -c 400000 "$f.body"; } > "$f"; rm -f "$f.body"
  RAN="$RAN $tag(exit $rc)"
}
# skip <what is missing and what it would have answered> [<install command>]
skip() { SKIPPED="$SKIPPED | $1"; [ -n "${2:-}" ] && printf '%s\t%s\n' "$1" "$2" >> "$MISS"; return 0; }

# project dirs: the root plus any subdir (depth<=2) with a manifest, excluding vendored trees
DIRS=$({ echo "$REPO"; find "$REPO" -maxdepth 3 -mindepth 2 \( -name node_modules -o -name .git -o -name vendor -o -name .venv -o -name venv -o -name dist -o -name build \) -prune -o \
  \( -name package.json -o -name pyproject.toml -o -name requirements.txt -o -name setup.py -o -name Pipfile -o -name go.mod -o -name Cargo.toml -o -name Gemfile \) -print 2>/dev/null | xargs -n1 dirname 2>/dev/null; } | sort -u)

while IFS= read -r d; do
  [ -z "$d" ] && continue
  rel="${d#$REPO/}"; [ "$d" = "$REPO" ] && rel="."
  # ---- JS / TS ----
  if [ -f "$d/package.json" ]; then
    if want eslint; then
      if npx_has "$d" eslint; then run eslint "$d" npx --no-install eslint . -f unix --no-error-on-unmatched-pattern; else skip "eslint ($rel)" "npm i -D eslint"; fi
    fi
    if want tsc && ls "$d"/tsconfig*.json >/dev/null 2>&1; then
      if npx_has "$d" tsc; then run tsc "$d" npx --no-install tsc --noEmit -p "$d/tsconfig.json" --pretty false; else skip "tsc ($rel)" "npm i -D typescript"; fi
    fi
    if want knip; then
      if npx_has "$d" knip; then run knip "$d" npx --no-install knip --no-progress --reporter compact; else skip "knip ($rel) — dead exports/files/deps" "npm i -D knip"; fi
    fi
    if want ts-prune && ! npx_has "$d" knip; then
      if npx_has "$d" ts-prune; then run ts-prune "$d" npx --no-install ts-prune; else skip "ts-prune ($rel)" "npm i -D ts-prune"; fi
    fi
    if want madge; then
      src="$d/src"; [ -d "$src" ] || src="$d"
      if npx_has "$d" madge; then run madge "$d" npx --no-install madge --circular --extensions ts,tsx,js,jsx,mjs "$src"; else skip "madge ($rel) — cycles (import-graph.py covers this)" "npm i -D madge"; fi
    fi
    if want jscpd; then
      if npx_has "$d" jscpd; then run jscpd "$d" npx --no-install jscpd --silent --reporters console --min-tokens 50 --ignore '**/node_modules/**,**/dist/**,**/*.min.js' .; else skip "jscpd ($rel) — duplication (dup-blocks.py covers this)" "npm i -D jscpd"; fi
    fi
    if want audit && [ "$NET" = 1 ]; then
      if [ -f "$d/pnpm-lock.yaml" ] && has pnpm; then run npm-audit "$d" pnpm audit --audit-level high
      elif [ -f "$d/yarn.lock" ] && has yarn; then run npm-audit "$d" yarn audit --level high
      elif [ -f "$d/package-lock.json" ] && has npm; then run npm-audit "$d" npm audit --audit-level=high
      else skip "npm audit ($rel) — no lockfile or package manager"; fi
    fi
  fi
  # ---- Python ----
  # Pipfile counts: without it a Pipenv-managed repo got no Python analyzer at all — no ruff,
  # no mypy, no vulture — and the digest's own manifest list has always included it.
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ] || [ -f "$d/Pipfile" ] || ls "$d"/requirements*.txt >/dev/null 2>&1; then
    if want ruff; then if has ruff; then run ruff "$d" ruff check --no-fix --output-format concise .; else skip "ruff ($rel)" "pipx install ruff"; fi; fi
    if want mypy; then if has mypy; then run mypy "$d" mypy --ignore-missing-imports --no-error-summary . ; else skip "mypy ($rel)" "pipx install mypy"; fi; fi
    if want pyright; then if has pyright; then run pyright "$d" pyright --outputjson; else skip "pyright ($rel)" "pipx install pyright"; fi; fi
    if want vulture; then if has vulture; then run vulture "$d" vulture . --min-confidence 80 --exclude 'venv,.venv,node_modules,migrations'; else skip "vulture ($rel) — dead code" "pipx install vulture"; fi; fi
    if want pylint-dup; then if has pylint; then run pylint-dup "$d" pylint --disable=all --enable=duplicate-code --min-similarity-lines=8 --recursive=y .; else skip "pylint duplicate-code ($rel)" "pipx install pylint"; fi; fi
    if want bandit; then if has bandit; then run bandit "$d" bandit -q -r . -x ./tests,./test,./venv,./.venv -ll; else skip "bandit ($rel)" "pipx install bandit"; fi; fi
    if want audit && [ "$NET" = 1 ]; then
      if has pip-audit; then
        if [ -f "$d/requirements.txt" ]; then run pip-audit "$d" pip-audit -r requirements.txt --progress-spinner off
        elif [ -f "$d/pyproject.toml" ]; then run pip-audit "$d" pip-audit --progress-spinner off; fi
      else skip "pip-audit ($rel)" "pipx install pip-audit"; fi
    fi
  fi
  # ---- Go ----
  if [ -f "$d/go.mod" ]; then
    if want vet && has go; then run go-vet "$d" go vet ./...; fi
    if want golangci; then if has golangci-lint; then run golangci-lint "$d" golangci-lint run --timeout 5m; else skip "golangci-lint ($rel)" "brew install golangci-lint"; fi; fi
    if want staticcheck; then if has staticcheck; then run staticcheck "$d" staticcheck ./...; else skip "staticcheck ($rel)" "go install honnef.co/go/tools/cmd/staticcheck@latest"; fi; fi
    if want deadcode; then if has deadcode; then run deadcode "$d" deadcode ./...; else skip "deadcode ($rel) — golang.org/x/tools/cmd/deadcode" "go install golang.org/x/tools/cmd/deadcode@latest"; fi; fi
    if want audit && [ "$NET" = 1 ]; then if has govulncheck; then run govulncheck "$d" govulncheck ./...; else skip "govulncheck ($rel)" "go install golang.org/x/vuln/cmd/govulncheck@latest"; fi; fi
  fi
  # ---- Rust ----
  if [ -f "$d/Cargo.toml" ] && has cargo; then
    if want clippy; then run clippy "$d" cargo clippy --all-targets --quiet -- -D warnings; fi
    if want machete; then if has cargo-machete; then run cargo-machete "$d" cargo machete; else skip "cargo-machete ($rel) — unused deps" "cargo install cargo-machete"; fi; fi
    if want audit && [ "$NET" = 1 ]; then if has cargo-audit; then run cargo-audit "$d" cargo audit; else skip "cargo-audit ($rel)" "cargo install cargo-audit"; fi; fi
  fi
  # ---- Ruby ----
  if [ -f "$d/Gemfile" ]; then
    if want rubocop; then if has rubocop; then run rubocop "$d" rubocop --format simple; else skip "rubocop ($rel)" "gem install rubocop"; fi; fi
    if want audit && [ "$NET" = 1 ]; then if has bundle-audit || has bundler-audit; then run bundle-audit "$d" bundle audit check --update; else skip "bundler-audit ($rel)" "gem install bundler-audit"; fi; fi
  fi
done <<< "$DIRS"
if want gitleaks; then if has gitleaks; then run gitleaks "$REPO" gitleaks detect --source . --no-banner --redact -v; else skip "gitleaks — secret scan incl. history" "brew install gitleaks"; fi; fi
if want semgrep; then if has semgrep; then run semgrep "$REPO" semgrep scan --config auto --quiet --metrics=off; else skip "semgrep" "pipx install semgrep"; fi; fi

# The missing-tool list, one line per tool, deduped by install command, with the ephemeral
# equivalent where one exists — the block the audit pastes into its preflight question.
missing_block() {
  [ -s "$MISS" ] || { echo "  (none — every analyzer this repo needs is present)"; return; }
  # install command first: it is ASCII, so the columns line up (the "what it answers" text
  # carries em dashes, and printf pads by bytes).
  sort -u -t"$(printf '\t')" -k2,2 "$MISS" | awk -F"\t" '{
    one = ""
    if ($2 ~ /^npm i -D /)          { one = "(one-off: npx --yes " substr($2, 10) ")" }
    else if ($2 ~ /^pipx install /) { one = "(one-off: uvx " substr($2, 14) ")" }
    printf "  %-34s %-32s %s\n", $2, one, $1
  }'
}

if [ "$CHECK" = 1 ]; then
  {
    echo "== dependency preflight (--check): nothing was run =="
    echo "would run (installed):${RAN:- none}"
    echo "missing — each line is a tool this repo's languages call for:"
    missing_block
    grep -q "knip" "$MISS" 2>/dev/null && echo "  ^ knip has NO substitute for Q2's \"which files are dead\" half — a grep is not an answer."
    grep -q "vulture" "$MISS" 2>/dev/null && echo "  ^ vulture has NO substitute for Q2 on Python."
    echo
    echo "Ask the user once, listing the above, and install only on a yes."
    echo "See skills/shared/dependency-preflight.md. A no ends the audit; it does not start it degraded."
  } | tee "$OUT/preflight.txt"
  rm -f "$MISS"
  exit 0
fi

{
  echo "ran:${RAN:- none}"
  echo "skipped (not installed):${SKIPPED:- none}"
  if [ -s "$MISS" ]; then
    echo "install commands for the skipped tools:"
    missing_block
  fi
  # Q2 has no fallback worth reporting: without one of these, the "which files are dead"
  # half of the question is unanswered, and the report has to say so rather than substitute
  # a grep for it. Say so loudly — reaching this point means the preflight was skipped.
  case "$SKIPPED" in
    *knip*)    echo "Q2 needs knip for TS/JS dead files+exports: npm i -D knip   (or a one-off: npx --yes knip)" ;;
  esac
  case "$SKIPPED" in
    *vulture*) echo "Q2 needs vulture for Python dead code:      pipx install vulture   (or a one-off: uvx vulture .)" ;;
  esac
} | tee "$OUT/analyzers-summary.txt"
rm -f "$MISS"
