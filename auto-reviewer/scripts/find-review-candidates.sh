#!/usr/bin/env bash
# find-review-candidates.sh — deterministic discovery for the auto-reviewer agent.
#
# Emits one JSON object per line for every open, non-draft PR in the target
# repos that:
#   - has had commits within the last $DAYS days, and
#   - has no review and no auto-reviewer marker comment newer than its latest commit.
#
# Env: REPOS / OWNERS (default: the current repo, see resolve_repos), DAYS (default 7), MARKER.
set -uo pipefail

DAYS="${DAYS:-7}"
MARKER="${MARKER:-generic-coding-agents:auto-reviewer}"

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)          # BSD / macOS
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)     # GNU
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
  prs=$(gh pr list -R "$repo" --state open --json number,isDraft \
          --jq '.[] | select(.isDraft | not) | .number' 2>/dev/null) || continue

  for n in $prs; do
    info=$(gh pr view "$n" -R "$repo" --json number,title,url,headRefOid,commits 2>/dev/null) || continue
    last_commit=$(jq -r '[.commits[].committedDate] | max // ""' <<<"$info")
    [[ -z "$last_commit" ]] && continue
    # ISO-8601 UTC timestamps compare correctly as strings.
    if [[ "$last_commit" < "$CUTOFF" ]]; then continue; fi

    last_review=$(gh api "repos/$repo/pulls/$n/reviews" --paginate \
                    --jq '.[].submitted_at // empty' 2>/dev/null | sort | tail -1)
    last_marker=$(gh api "repos/$repo/issues/$n/comments" --paginate \
                    --jq ".[] | select(.body | contains(\"$MARKER\")) | .created_at" 2>/dev/null \
                    | sort | tail -1)
    latest_feedback=$(printf '%s\n%s\n' "${last_review:-}" "${last_marker:-}" | sort | tail -1)

    if [[ -n "$latest_feedback" && "$latest_feedback" > "$last_commit" ]]; then
      continue
    fi

    jq -c --arg repo "$repo" --arg last_commit "$last_commit" \
      '{repo: $repo, number: .number, title: .title, url: .url,
        head_sha: .headRefOid, last_commit: $last_commit}' <<<"$info"
  done
done
