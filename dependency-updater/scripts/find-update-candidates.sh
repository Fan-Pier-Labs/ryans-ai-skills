#!/usr/bin/env bash
# find-update-candidates.sh — the target repos (default: the current repo; or
# REPOS; or every repo in OWNERS with activity in the last $DAYS days, default 30,
# excluding forks and archived repos).
#
# Emits one JSON line per repo: {repo, pushedAt, open_update_pr}
# where open_update_pr is the number of an existing open deps/auto-update-* PR, or null.
set -uo pipefail

DAYS="${DAYS:-30}"

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

# Target repos, one "owner/repo" per line. Precedence:
#   REPOS   space-separated owner/repo slugs (used as given)
#   OWNERS  space-separated GitHub users/orgs, expanded to repos pushed within $DAYS
#   else    the repo of the current working directory (its `origin` remote)
# Nothing is ever enumerated from the user's GitHub account. If the current
# repo cannot be determined, exit 2 with a message — the agent should ask the
# user which repo(s) to target and re-run with REPOS or OWNERS set.
resolve_repos() {
  if [[ -n "${REPOS:-}" ]]; then
    printf '%s\n' $REPOS
  elif [[ -n "${OWNERS:-}" ]]; then
    for owner in $OWNERS; do
      gh repo list "$owner" --limit 300 --json nameWithOwner,pushedAt \
        --jq ".[] | select(.pushedAt >= \"$CUTOFF\") | .nameWithOwner" || true
    done
  else
    local url slug
    url=$(git remote get-url origin 2>/dev/null) || url=""
    # git@host:owner/repo.git | https://host/owner/repo(.git) | ssh://git@host/owner/repo
    slug=$(sed -E 's#^(git@|ssh://[^@/]+@|https?://)[^/:]+[:/]##; s#/$##; s#\.git$##' <<<"$url")
    if [[ -z "$url" || ! "$slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
      echo "ERROR: could not determine the target repo from 'git remote get-url origin' in $PWD (got: '${url:-nothing}')." >&2
      echo "       Ask the user which repo(s) to target, then re-run with REPOS='owner/repo ...' or OWNERS='org user ...'." >&2
      exit 2
    fi
    echo "$slug"
  fi
}

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
