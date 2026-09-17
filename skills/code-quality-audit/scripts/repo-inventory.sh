#!/usr/bin/env bash
# code-quality-audit: deterministic, read-only inventory of a repository's code quality signals.
#
#   scripts/repo-inventory.sh [--repo <dir>] [--out <dir>] [--exclude "dir1 dir2"] [--no-analyzers]
#
# Runs, in order: git facts → import graph (DAG check) → endpoints + auth + dead-endpoint
# candidates → duplicate blocks → installed analyzers (eslint/tsc/mypy/ruff/knip/vulture/
# jscpd/madge/audit; skipped with --no-analyzers, never installs anything, never --fix) →
# DIGEST.md. Nothing in the repo is modified; the output directory is the only thing written.
# Defaults: --repo . and --out ./code-quality-audit-<name>-<date> next to the repo (not inside it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="."; OUT=""; EXCL=""; ANALYZERS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --exclude) EXCL="$2"; shift 2;;
    --no-analyzers) ANALYZERS=0; shift;;
    -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "no such directory: $REPO" >&2; exit 2; }
NAME="$(basename "$REPO")"
[ -z "$OUT" ] && OUT="$(dirname "$REPO")/code-quality-audit-${NAME}-$(date +%Y-%m-%d)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
case "$OUT" in "$REPO"/*) echo "note: output dir is inside the repo; add it to .gitignore or delete it after the review" >&2;; esac
# shellcheck disable=SC2086  # EXARGS is intentionally word-split
EXARGS=""; [ -n "$EXCL" ] && EXARGS="--exclude $EXCL"
echo "repo=$REPO out=$OUT"

echo "== git =="
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  {
    echo "remote: $(git -C "$REPO" remote get-url origin 2>/dev/null || echo none)"
    echo "branch: $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "head: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
    echo "commits: $(git -C "$REPO" rev-list --count HEAD 2>/dev/null)"
    echo "first commit: $(git -C "$REPO" log --reverse --format=%as 2>/dev/null | head -1)"
    echo "last commit: $(git -C "$REPO" log -1 --format=%as 2>/dev/null)"
    echo "authors (last 90d): $(git -C "$REPO" log --since=90.days --format=%an 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    echo "dirty: $(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ') paths"
    echo; echo "hot files (last 200 commits):"
    git -C "$REPO" log -200 --name-only --format= 2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn | head -15
  } > "$OUT/git.txt"
  sed -n '1,8p' "$OUT/git.txt"
  # branch protection is read-only via gh; missing gh / no permission is fine
  if command -v gh >/dev/null 2>&1; then
    slug=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#^(git@|ssh://[^@/]+@|https?://)[^/:]+[:/]##; s#/$##; s#\.git$##')
    def=$(git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##'); [ -z "$def" ] && def=main
    if [[ "$slug" =~ ^[^/]+/[^/]+$ ]]; then
      gh api "repos/$slug/branches/$def/protection" > "$OUT/branch-protection.json" 2>/dev/null \
        && echo "  branch protection on $def: read (see branch-protection.json)" \
        || { echo '{"error":"not readable (no protection, no permission, or not GitHub)"}' > "$OUT/branch-protection.json"; echo "  branch protection: not readable"; }
    fi
  fi
else
  echo "not a git repository" | tee "$OUT/git.txt"
fi

echo "== import graph (Q8) =="
python3 "$HERE/import-graph.py" --repo "$REPO" --out "$OUT" $EXARGS | tee "$OUT/import-graph.txt"
echo "== endpoints (Q3/Q4) =="
python3 "$HERE/find-endpoints.py" --repo "$REPO" --out "$OUT" $EXARGS | tee "$OUT/endpoints.txt"
echo "== duplicate blocks (Q5) =="
python3 "$HERE/dup-blocks.py" --repo "$REPO" --out "$OUT" $EXARGS | tee "$OUT/dup-blocks.txt"
if [ "$ANALYZERS" = 1 ]; then
  echo "== installed analyzers =="
  bash "$HERE/run-analyzers.sh" --repo "$REPO" --out "$OUT"
fi
echo "== digest =="
python3 "$HERE/quality-digest.py" "$REPO" "$OUT"
echo
echo "Read $OUT/DIGEST.md first; the JSON and tool-*.txt next to it are the evidence."
