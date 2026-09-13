#!/usr/bin/env bash
# find-update-candidates.sh — repos in the configured owners with activity in the
# last $DAYS days (default 30), excluding forks and archived repos.
#
# Emits one JSON line per repo: {repo, pushedAt, open_update_pr}
# where open_update_pr is the number of an existing open deps/auto-update-* PR, or null.
set -uo pipefail

OWNERS=(${OWNERS:-Fan-Pier-Labs ryanhugh})
DAYS="${DAYS:-30}"

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

for owner in "${OWNERS[@]}"; do
  gh repo list "$owner" --limit 300 --source --no-archived \
      --json nameWithOwner,pushedAt \
      --jq ".[] | select(.pushedAt >= \"$CUTOFF\")" | jq -c '.' |
  while read -r row; do
    repo=$(jq -r '.nameWithOwner' <<<"$row")
    pushed=$(jq -r '.pushedAt' <<<"$row")
    open_pr=$(gh pr list -R "$repo" --state open --json number,headRefName \
                --jq '[.[] | select(.headRefName | startswith("deps/auto-update"))][0].number // empty' 2>/dev/null)
    jq -cn --arg repo "$repo" --arg pushed "$pushed" --arg pr "${open_pr:-}" \
      '{repo: $repo, pushedAt: $pushed, open_update_pr: (if $pr == "" then null else ($pr | tonumber) end)}'
  done
done
