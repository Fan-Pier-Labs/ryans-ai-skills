#!/usr/bin/env bash
# find-demo-candidates.sh — discovery for the pr-demo-media agent.
#
# Emits one JSON line per open, non-draft PR (in the target repos, with commits
# within $DAYS days) that touches frontend-looking files and has no demo-marker
# comment newer than its latest commit:
#   {repo, number, title, url, head_sha, last_commit, frontend_files: [...]}
#
# The frontend test is a heuristic (extensions + path hints); the agent makes
# the final call. A thin wrapper over ../../shared/find-pr-candidates.sh, which
# does the sweep for every PR skill; this file holds only what is specific to
# pr-demo-media.
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
export MARKER="${MARKER:-generic-coding-agents:pr-demo-media}"
# Legacy "Automated demo" comments from repo-local demo skills count as handled.
export EXTRA_MARKER='**Automated demo**'
export PATH_FILTER='(\.(tsx|jsx|vue|svelte|astro|html|css|scss|less)$)|(^|/)(frontend|client|web|www|app|site|ui|renderer|components|pages|views|src/routes)(/.*)?\.(ts|js|mjs)$'
export MATCH_FIELD=frontend_files

exec "$SHARED/find-pr-candidates.sh"
