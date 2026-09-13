#!/usr/bin/env bash
# ci-runner.sh — deterministic local CI for open PRs across configured GitHub owners.
#
# For each open, non-draft PR whose head SHA has no local-ci commit status yet:
#   clone shallow -> checkout pull/N/head -> run the repo's own GitHub workflows
#   locally (scripts/run-workflows.py; act if installed; stack heuristics as a
#   last resort) -> post commit status (context: local-ci) -> comment log tail
#   on failure.
#
# Stateless: the local-ci commit status on the head SHA is the "already ran"
# ledger — no local state files. A `pending` status alone (crashed run) does
# not count as ran. See README.md for event-driven and all-local alternatives.
#
# Env: OWNERS, DAYS (repo activity window, default 30), STATUS_CONTEXT, KEEP_WORK.
set -uo pipefail

# OWNERS: space-separated GitHub users/orgs to scan. Defaults to the
# authenticated `gh` user plus every org that account belongs to.
if [[ -z "${OWNERS:-}" ]]; then
  OWNERS=$( { gh api user --jq .login; gh api user/orgs --paginate --jq '.[].login'; } 2>/dev/null | tr '\n' ' ')
fi
OWNERS=($OWNERS)
DAYS="${DAYS:-30}"
STATUS_CONTEXT="${STATUS_CONTEXT:-local-ci}"
MARKER="<!-- generic-coding-agents:ci-runner -->"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/generic-coding-agents/ci-runner}"   # tooling only (venv), not run state
WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ci-runner.XXXXXX")
SUMMARY=()

mkdir -p "$CACHE_DIR"
trap '[[ "${KEEP_WORK:-0}" = 1 ]] || rm -rf "$WORK_ROOT"' EXIT

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

log() { printf '[ci-runner] %s\n' "$*" >&2; }

# Bootstrap a venv with PyYAML for the workflow interpreter (one-time).
ensure_python() {
  local py="$CACHE_DIR/venv/bin/python"
  [[ -x "$py" ]] && "$py" -c 'import yaml' 2>/dev/null && return 0
  python3 -m venv "$CACHE_DIR/venv" >/dev/null 2>&1 \
    && "$CACHE_DIR/venv/bin/pip" install --quiet pyyaml >/dev/null 2>&1 \
    && "$py" -c 'import yaml' 2>/dev/null
}

# True if a non-pending local-ci status already exists on this commit.
# (The combined-status endpoint returns the latest status per context, so this
# yields at most one line. Not grep -v: BSD grep -qv exits 0 on empty input.)
already_ran() { # repo sha
  [[ "${FORCE:-0}" = 1 ]] && return 1   # FORCE=1 re-runs already-processed heads
  local state
  state=$(gh api "repos/$1/commits/$2/status" \
    --jq ".statuses[] | select(.context == \"$STATUS_CONTEXT\") | .state" 2>/dev/null)
  [[ -n "$state" && "$state" != "pending" ]]
}

# --- stack-heuristic runners (fallback when a repo has no usable workflows) ---
# Each runs in the checked-out repo dir, appends to $1 (log file).

run_node() {
  local logf="$1" pm=npm install=(npm install)
  if   [[ -f bun.lock || -f bun.lockb ]] && command -v bun  >/dev/null; then pm=bun;  install=(bun install)
  elif [[ -f pnpm-lock.yaml ]] && command -v pnpm >/dev/null;           then pm=pnpm; install=(pnpm install --frozen-lockfile)
  elif [[ -f yarn.lock ]] && command -v yarn >/dev/null;                then pm=yarn; install=(yarn install --frozen-lockfile)
  elif [[ -f package-lock.json ]];                                      then pm=npm;  install=(npm ci)
  fi
  echo "== install ($pm)" >>"$logf"
  "${install[@]}" >>"$logf" 2>&1 || { echo "== install failed" >>"$logf"; return 1; }
  local s
  for s in lint typecheck build test; do
    if jq -e --arg s "$s" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
      echo "== $pm run $s" >>"$logf"
      "$pm" run "$s" >>"$logf" 2>&1 || { echo "== $s failed" >>"$logf"; return 1; }
    fi
  done
}

run_python() {
  local logf="$1"
  echo "== python venv + install" >>"$logf"
  python3 -m venv .ci-venv >>"$logf" 2>&1 || return 1
  # shellcheck disable=SC1091
  source .ci-venv/bin/activate
  pip install --quiet --upgrade pip >>"$logf" 2>&1
  if [[ -f requirements.txt ]]; then pip install -r requirements.txt >>"$logf" 2>&1 || return 1; fi
  if [[ -f pyproject.toml ]];   then pip install -e . >>"$logf" 2>&1 || pip install . >>"$logf" 2>&1 || return 1; fi
  if find . -path ./.ci-venv -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -print 2>/dev/null | grep -q .; then
    pip install --quiet pytest >>"$logf" 2>&1
    echo "== pytest" >>"$logf"
    python -m pytest -x -q >>"$logf" 2>&1 || return 1
  fi
}

run_ci_steps() {
  local logf="$1" rc
  if [[ -d .github/workflows ]]; then
    # Preferred: run the repo's own workflows, the way GitHub would.
    if command -v act >/dev/null && docker info >/dev/null 2>&1; then
      echo "== act pull_request (real workflows, containerized)" >>"$logf"
      act pull_request --pull=false >>"$logf" 2>&1
      return $?
    fi
    if ensure_python; then
      echo "== run-workflows.py --event pull_request (workflows on host)" >>"$logf"
      "$CACHE_DIR/venv/bin/python" "$SCRIPT_DIR/run-workflows.py" --event pull_request . >>"$logf" 2>&1
      rc=$?
      if [[ $rc -ne 42 ]]; then return $rc; fi   # 42 = no pull_request workflows
      echo "== no pull_request-triggered workflows; falling back to heuristics" >>"$logf"
    else
      echo "== WARN: could not bootstrap python venv; falling back to heuristics" >>"$logf"
    fi
  fi
  if   [[ -f package.json ]];                            then run_node "$logf"
  elif [[ -f pyproject.toml || -f requirements.txt ]];   then run_python "$logf"
  elif [[ -f Cargo.toml ]]; then
    { echo "== cargo build/test" >>"$logf"; cargo build >>"$logf" 2>&1 && cargo test >>"$logf" 2>&1; }
  elif [[ -f go.mod ]]; then
    { echo "== go build/vet/test" >>"$logf"; go build ./... >>"$logf" 2>&1 && go vet ./... >>"$logf" 2>&1 && go test ./... >>"$logf" 2>&1; }
  else
    return 42   # no recognizable stack
  fi
}

# --- GitHub reporting ---------------------------------------------------------

post_status() { # repo sha state description
  gh api -X POST "repos/$1/statuses/$2" \
    -f state="$3" -f context="$STATUS_CONTEXT" -f description="$4" >/dev/null 2>&1 \
    || log "WARN: could not post status on $1@${2:0:7}"
}

upsert_comment() { # repo pr body
  local repo="$1" n="$2" body="$3" cid
  cid=$(gh api "repos/$repo/issues/$n/comments" --paginate \
          --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" 2>/dev/null | head -1)
  if [[ -n "$cid" ]]; then
    gh api -X PATCH "repos/$repo/issues/comments/$cid" -f body="$body" >/dev/null 2>&1
  else
    gh pr comment "$n" -R "$repo" --body "$body" >/dev/null 2>&1
  fi
}

# --- per-PR run ---------------------------------------------------------------

run_pr() { # repo pr_number head_sha
  local repo="$1" n="$2" sha="$3"
  local key dir logf started elapsed
  if already_ran "$repo" "$sha"; then return 0; fi

  log "running $repo#$n @ ${sha:0:7}"
  key="${repo//\//_}-pr$n"
  dir="$WORK_ROOT/$key"
  logf="$WORK_ROOT/$key.log"
  : >"$logf"

  if ! gh repo clone "$repo" "$dir" -- --depth 50 --quiet >>"$logf" 2>&1; then
    log "clone failed for $repo"; return 1
  fi
  if ! git -C "$dir" fetch --depth 50 --quiet origin "pull/$n/head:ci-pr-$n" \
     || ! git -C "$dir" checkout --quiet "ci-pr-$n"; then
    log "checkout failed for $repo#$n"; return 1
  fi
  sha=$(git -C "$dir" rev-parse HEAD)   # head may have moved since listing
  if [[ "$sha" != "$3" ]] && already_ran "$repo" "$sha"; then return 0; fi

  post_status "$repo" "$sha" pending "local CI running"
  started=$SECONDS
  ( cd "$dir" && run_ci_steps "$logf" ); local rc=$?
  elapsed=$(( SECONDS - started ))

  if [[ $rc -eq 42 ]]; then
    post_status "$repo" "$sha" success "local CI: no workflows or recognizable stack, skipped"
    SUMMARY+=("$repo#$n  ${sha:0:7}  NO_STACK  ${elapsed}s")
  elif [[ $rc -eq 0 ]]; then
    post_status "$repo" "$sha" success "local CI passed in ${elapsed}s"
    # If a failure comment exists from an earlier commit, flip it to green.
    if gh api "repos/$repo/issues/$n/comments" --paginate \
         --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" 2>/dev/null | grep -q .; then
      upsert_comment "$repo" "$n" "$MARKER
✅ **Local CI passed** at \`${sha:0:7}\` (${elapsed}s). Earlier failure resolved."
    fi
    SUMMARY+=("$repo#$n  ${sha:0:7}  PASS  ${elapsed}s")
  else
    post_status "$repo" "$sha" failure "local CI failed in ${elapsed}s"
    upsert_comment "$repo" "$n" "$MARKER
❌ **Local CI failed** at \`${sha:0:7}\` (${elapsed}s). Log tail:

\`\`\`
$(tail -c 6000 "$logf" | tail -n 80 | LC_ALL=C sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g')
\`\`\`"
    SUMMARY+=("$repo#$n  ${sha:0:7}  FAIL  ${elapsed}s")
  fi
  [[ "${KEEP_WORK:-0}" = 1 ]] || rm -rf "$dir"
}

# --- sweep --------------------------------------------------------------------

for owner in "${OWNERS[@]}"; do
  repos=$(gh repo list "$owner" --limit 300 --json nameWithOwner,pushedAt \
            --jq ".[] | select(.pushedAt >= \"$CUTOFF\") | .nameWithOwner") || continue
  for repo in $repos; do
    if [[ -n "${ONLY:-}" && "$repo" != *"$ONLY"* ]]; then continue; fi
    while IFS=$'\t' read -r n sha; do
      [[ -z "${n:-}" ]] && continue
      run_pr "$repo" "$n" "$sha"
    done < <(gh pr list -R "$repo" --state open --json number,isDraft,headRefOid \
               --jq '.[] | select(.isDraft | not) | [.number, .headRefOid] | @tsv' 2>/dev/null)
  done
done

echo
echo "=== ci-runner sweep summary ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="
if [[ ${#SUMMARY[@]} -eq 0 ]]; then
  echo "nothing to run — every open PR head already has a $STATUS_CONTEXT status"
else
  printf '%s\n' "${SUMMARY[@]}"
fi
