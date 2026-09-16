#!/usr/bin/env bash
# find-pr-candidates.sh — the one PR-discovery sweep, shared by every skill that
# acts on open pull requests (auto-reviewer, pr-demo-media, …). Read-only: it
# never writes anything to GitHub, so it is safe to run at any time.
#
# Emits one JSON object per line for every open, non-draft PR in the target
# repos that:
#   - has had commits within the last $DAYS days, and
#   - matches $PATH_FILTER, if one is set, and
#   - has no feedback newer than its latest commit — a comment carrying $MARKER
#     (or $EXTRA_MARKER), plus human reviews when $COUNT_REVIEWS=1.
#
#   {repo, number, title, url, head_sha, last_commit[, <MATCH_FIELD>: [...]]}
#
# Skills wrap this with their own defaults rather than calling it directly; see
# skills/auto-reviewer/scripts/find-review-candidates.sh for the pattern.
#
# Env:
#   REPOS / OWNERS   target repos (default: the current repo, see repo-targets.sh)
#   DAYS             only PRs with commits this recent (default 7)
#   MARKER           required — the comment marker meaning "already handled"
#   EXTRA_MARKER     optional second substring that also counts as handled
#   COUNT_REVIEWS    1 = a human review also counts as feedback (default 0)
#   PATH_FILTER      optional jq regex; the PR must touch a file matching it
#   MATCH_FIELD      name of the emitted matched-path array (default matched_files)
set -uo pipefail

DAYS="${DAYS:-7}"
MARKER="${MARKER:-}"
EXTRA_MARKER="${EXTRA_MARKER:-}"
COUNT_REVIEWS="${COUNT_REVIEWS:-0}"
PATH_FILTER="${PATH_FILTER:-}"
MATCH_FIELD="${MATCH_FIELD:-matched_files}"

if [[ -z "$MARKER" ]]; then
  echo "ERROR: MARKER is required — without it every PR looks unhandled and would be acted on twice." >&2
  exit 2
fi

SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SHARED/repo-targets.sh"

fields=number,title,url,headRefOid,commits
[[ -n "$PATH_FILTER" ]] && fields="$fields,files"

repos=$(resolve_repos) || exit $?

for repo in $repos; do
  prs=$(gh pr list -R "$repo" --state open --json number,isDraft \
          --jq '.[] | select(.isDraft | not) | .number' 2>/dev/null) || continue

  for n in $prs; do
    info=$(gh pr view "$n" -R "$repo" --json "$fields" 2>/dev/null) || continue
    last_commit=$(jq -r '[.commits[].committedDate] | max // ""' <<<"$info")
    [[ -z "$last_commit" ]] && continue
    # ISO-8601 UTC timestamps compare correctly as strings.
    if [[ "$last_commit" < "$CUTOFF" ]]; then continue; fi

    matched="[]"
    if [[ -n "$PATH_FILTER" ]]; then
      matched=$(jq -c --arg re "$PATH_FILTER" '[.files[].path | select(test($re))]' <<<"$info")
      [[ "$matched" == "[]" ]] && continue
    fi

    last_marker=$(gh api "repos/$repo/issues/$n/comments" --paginate 2>/dev/null \
                    | jq -r --arg m "$MARKER" --arg m2 "$EXTRA_MARKER" \
                        '.[] | select((.body | contains($m)) or ($m2 != "" and (.body | contains($m2)))) | .created_at' \
                    | sort | tail -1)
    last_review=""
    if [[ "$COUNT_REVIEWS" = 1 ]]; then
      last_review=$(gh api "repos/$repo/pulls/$n/reviews" --paginate \
                      --jq '.[].submitted_at // empty' 2>/dev/null | sort | tail -1)
    fi
    latest_feedback=$(printf '%s\n%s\n' "${last_review:-}" "${last_marker:-}" | sort | tail -1)

    if [[ -n "$latest_feedback" && "$latest_feedback" > "$last_commit" ]]; then
      continue
    fi

    jq -c --arg repo "$repo" --arg last_commit "$last_commit" \
          --arg field "$MATCH_FIELD" --argjson matched "$matched" \
          --arg filtered "${PATH_FILTER:+1}" \
      '{repo: $repo, number: .number, title: .title, url: .url,
        head_sha: .headRefOid, last_commit: $last_commit}
       + (if $filtered == "" then {} else {($field): $matched} end)' <<<"$info"
  done
done
