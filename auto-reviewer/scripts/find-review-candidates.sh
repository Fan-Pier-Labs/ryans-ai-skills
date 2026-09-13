#!/usr/bin/env bash
# find-review-candidates.sh — deterministic discovery for the auto-reviewer agent.
#
# Emits one JSON object per line for every open, non-draft PR in the configured
# owners that:
#   - has had commits within the last $DAYS days, and
#   - has no review and no auto-reviewer marker comment newer than its latest commit.
#
# Env: OWNERS (default: authenticated gh user + their orgs), DAYS (default 7), MARKER.
set -uo pipefail

# OWNERS: space-separated GitHub users/orgs to scan. Defaults to the
# authenticated `gh` user plus every org that account belongs to.
if [[ -z "${OWNERS:-}" ]]; then
  OWNERS=$( { gh api user --jq .login; gh api user/orgs --paginate --jq '.[].login'; } 2>/dev/null | tr '\n' ' ')
fi
OWNERS=($OWNERS)
DAYS="${DAYS:-7}"
MARKER="${MARKER:-generic-coding-agents:auto-reviewer}"

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)          # BSD / macOS
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)     # GNU
fi

for owner in "${OWNERS[@]}"; do
  # Only repos pushed within the window can contain PRs with commits in the window.
  repos=$(gh repo list "$owner" --limit 300 --json nameWithOwner,pushedAt \
            --jq ".[] | select(.pushedAt >= \"$CUTOFF\") | .nameWithOwner") || continue

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
done
