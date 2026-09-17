#!/usr/bin/env bash
# find-update-candidates.sh — the target repos (default: the current repo; or
# REPOS; or every repo in OWNERS with activity in the last $DAYS days, default 30,
# excluding forks and archived repos).
#
# Emits one JSON line per repo: {repo, pushedAt, open_update_pr}
# where open_update_pr is the number of an existing open deps/auto-update-* PR, or null.
set -uo pipefail

DAYS="${DAYS:-30}"

# Target repos (REPOS / OWNERS / the current checkout) and $CUTOFF, $DAYS days
# ago, both come from the shared library every GitHub skill uses.
SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" 2>/dev/null && pwd)
if [[ -z "$SHARED" || ! -f "$SHARED/repo-targets.sh" ]]; then
  echo "ERROR: the shared script folder is missing — expected it next to this skill at skills/shared/." >&2
  echo "       Re-vendor the skills repo (it ships skills/shared/ alongside every skill)." >&2
  exit 2
fi
. "$SHARED/repo-targets.sh"

repos=$(resolve_repos) || exit $?

for repo in $repos; do
  meta=$(gh repo view "$repo" --json nameWithOwner,pushedAt,isFork,isArchived 2>/dev/null) || continue
  # Fork/archived exclusion only applies when expanding OWNERS; a repo named
  # explicitly (REPOS or the current checkout) is always a candidate.
  if [[ -z "${REPOS:-}" && -n "${OWNERS:-}" ]]; then
    [[ $(jq -r '.isFork or .isArchived' <<<"$meta") == true ]] && continue
  fi
  pushed=$(jq -r '.pushedAt' <<<"$meta")
  open_pr=$(gh pr list -R "$repo" --state open --json number,headRefName \
              --jq '[.[] | select(.headRefName | startswith("deps/auto-update"))][0].number // empty' 2>/dev/null)
  jq -cn --arg repo "$repo" --arg pushed "$pushed" --arg pr "${open_pr:-}" \
    '{repo: $repo, pushedAt: $pushed, open_update_pr: (if $pr == "" then null else ($pr | tonumber) end)}'
done
