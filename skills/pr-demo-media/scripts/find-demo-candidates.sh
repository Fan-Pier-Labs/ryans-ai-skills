#!/usr/bin/env bash
# find-demo-candidates.sh — discovery for the pr-demo-media agent.
#
# Emits one JSON line per open, non-draft PR (in the target repos, with commits
# within $DAYS days) that touches frontend-looking files and has no demo-marker
# comment newer than its latest commit:
#   {repo, number, title, url, head_sha, last_commit, matched_files: [...]}
#
# The frontend test is a heuristic (extensions + path hints); the agent makes
# the final call. The sweep itself is ../../shared/find-pr-candidates.sh, shared
# with the other PR skills; this file is just pr-demo-media's arguments to it.
#
# Env: REPOS / OWNERS (default: the current repo, see shared/repo-targets.sh),
# DAYS (default 7), MARKER.
set -uo pipefail

SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" 2>/dev/null && pwd)
if [[ -z "$SHARED" || ! -x "$SHARED/find-pr-candidates.sh" ]]; then
  echo "ERROR: the shared script folder is missing — expected it next to this skill at skills/shared/." >&2
  echo "       Re-vendor the skills repo (it ships skills/shared/ alongside every skill)." >&2
  exit 2
fi

export DAYS="${DAYS:-7}"

FRONTEND='(\.(tsx|jsx|vue|svelte|astro|html|css|scss|less)$)|(^|/)(frontend|client|web|www|app|site|ui|renderer|components|pages|views|src/routes)(/.*)?\.(ts|js|mjs)$'

# The second marker is the "Automated demo" comment older repo-local demo
# skills posted; a PR they already demoed should not be demoed again.
exec "$SHARED/find-pr-candidates.sh" --touching "$FRONTEND" \
  "${MARKER:-generic-coding-agents:pr-demo-media}" '**Automated demo**'
