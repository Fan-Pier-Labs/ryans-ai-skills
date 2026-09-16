#!/usr/bin/env bash
# find-review-candidates.sh — deterministic discovery for the auto-reviewer agent.
#
# Emits one JSON object per line for every open, non-draft PR in the target
# repos that:
#   - has had commits within the last $DAYS days, and
#   - has no review and no auto-reviewer marker comment newer than its latest commit.
#
# A thin wrapper over ../../shared/find-pr-candidates.sh, which does the sweep
# for every PR skill; this file holds only what is specific to auto-reviewer.
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
export MARKER="${MARKER:-generic-coding-agents:auto-reviewer}"
export COUNT_REVIEWS=1          # a human review is feedback too; don't pile on

exec "$SHARED/find-pr-candidates.sh"
