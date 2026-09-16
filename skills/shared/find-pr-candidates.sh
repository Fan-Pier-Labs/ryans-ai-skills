#!/usr/bin/env bash
# find-pr-candidates.sh — the open-PR discovery sweep, shared by every skill that
# acts on pull requests. Read-only: it never writes anything to GitHub, so it is
# safe to run at any time.
#
#   find-pr-candidates.sh [--touching <regex>] [--reviews-are-feedback] <marker>...
#
#     <marker>                 a comment containing this text means the PR's
#                              current head was already handled — skip it.
#                              Pass more than one if older versions of the skill
#                              used a different marker.
#     --touching <regex>       only PRs that change a matching file; the matches
#                              are emitted as `matched_files`
#     --reviews-are-feedback   a human review also counts as handled, so the
#                              skill doesn't pile on after a person has replied
#
# Emits one JSON object per line for every open, non-draft PR in the target
# repos with commits in the last $DAYS days that no marker (and no review, with
# the flag) is newer than:
#
#   {repo, number, title, url, head_sha, last_commit[, matched_files: [...]]}
#
# Skills call this through a wrapper holding their own arguments — see
# skills/auto-reviewer/scripts/find-review-candidates.sh.
#
# Env: REPOS / OWNERS (default: the current repo, see repo-targets.sh), DAYS.
set -uo pipefail

DAYS="${DAYS:-7}"
TOUCHING=""
REVIEWS_ARE_FEEDBACK=0
MARKERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --touching)             TOUCHING="$2"; shift 2;;
    --reviews-are-feedback) REVIEWS_ARE_FEEDBACK=1; shift;;
    -h|--help)              sed -n '2,25p' "$0"; exit 0;;
    -*)                     echo "unknown option: $1" >&2; exit 2;;
    *)                      MARKERS+=("$1"); shift;;
  esac
done

if [[ ${#MARKERS[@]} -eq 0 ]]; then
  echo "ERROR: give at least one marker — without it every PR looks unhandled and would be acted on twice." >&2
  echo "       usage: find-pr-candidates.sh [--touching <regex>] [--reviews-are-feedback] <marker>..." >&2
  exit 2
fi

SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SHARED/repo-targets.sh"

# One jq filter that picks out every comment carrying any of the markers.
markers_json=$(printf '%s\n' "${MARKERS[@]}" | jq -R . | jq -sc .)

fields=number,title,url,headRefOid,commits
[[ -n "$TOUCHING" ]] && fields="$fields,files"

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
    if [[ -n "$TOUCHING" ]]; then
      matched=$(jq -c --arg re "$TOUCHING" '[.files[].path | select(test($re))]' <<<"$info")
      [[ "$matched" == "[]" ]] && continue
    fi

    last_marker=$(gh api "repos/$repo/issues/$n/comments" --paginate 2>/dev/null \
                    | jq -r --argjson markers "$markers_json" \
                        '.[] | select([.body | contains($markers[])] | any) | .created_at' \
                    | sort | tail -1)
    last_review=""
    if [[ "$REVIEWS_ARE_FEEDBACK" = 1 ]]; then
      last_review=$(gh api "repos/$repo/pulls/$n/reviews" --paginate \
                      --jq '.[].submitted_at // empty' 2>/dev/null | sort | tail -1)
    fi
    latest_feedback=$(printf '%s\n%s\n' "${last_review:-}" "${last_marker:-}" | sort | tail -1)

    if [[ -n "$latest_feedback" && "$latest_feedback" > "$last_commit" ]]; then
      continue
    fi

    jq -c --arg repo "$repo" --arg last_commit "$last_commit" \
          --argjson matched "$matched" --arg touching "${TOUCHING:+1}" \
      '{repo: $repo, number: .number, title: .title, url: .url,
        head_sha: .headRefOid, last_commit: $last_commit}
       + (if $touching == "" then {} else {matched_files: $matched} end)' <<<"$info"
  done
done
