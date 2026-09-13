#!/usr/bin/env bash
# find-demo-candidates.sh — discovery for the pr-demo-media agent.
#
# Emits one JSON line per open, non-draft PR (in owners' repos pushed within
# $DAYS days) that touches frontend-looking files and has no demo-marker
# comment newer than its latest commit:
#   {repo, number, title, url, head_sha, last_commit, frontend_files: [...]}
#
# The frontend test is a heuristic (extensions + path hints); the agent makes
# the final call. Env: OWNERS, DAYS (default 7), MARKER.
set -uo pipefail

OWNERS=(${OWNERS:-Fan-Pier-Labs ryanhugh})
DAYS="${DAYS:-7}"
MARKER="${MARKER:-generic-coding-agents:pr-demo-media}"

FRONTEND_RE='(\.(tsx|jsx|vue|svelte|astro|html|css|scss|less)$)|(^|/)(frontend|client|web|www|app|site|ui|renderer|components|pages|views|src/routes)(/.*)?\.(ts|js|mjs)$'

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

for owner in "${OWNERS[@]}"; do
  repos=$(gh repo list "$owner" --limit 300 --json nameWithOwner,pushedAt \
            --jq ".[] | select(.pushedAt >= \"$CUTOFF\") | .nameWithOwner") || continue

  for repo in $repos; do
    prs=$(gh pr list -R "$repo" --state open --json number,isDraft \
            --jq '.[] | select(.isDraft | not) | .number' 2>/dev/null) || continue

    for n in $prs; do
      info=$(gh pr view "$n" -R "$repo" --json number,title,url,headRefOid,commits,files 2>/dev/null) || continue
      last_commit=$(jq -r '[.commits[].committedDate] | max // ""' <<<"$info")
      [[ -z "$last_commit" ]] && continue
      if [[ "$last_commit" < "$CUTOFF" ]]; then continue; fi

      frontend=$(jq -c --arg re "$FRONTEND_RE" \
                   '[.files[].path | select(test($re))]' <<<"$info")
      [[ "$frontend" == "[]" ]] && continue

      # Skip if a demo (this agent's marker, or a legacy "Automated demo"
      # comment from repo-local demo skills) is newer than the last commit.
      last_demo=$(gh api "repos/$repo/issues/$n/comments" --paginate \
                    --jq ".[] | select((.body | contains(\"$MARKER\")) or (.body | contains(\"**Automated demo**\"))) | .created_at" 2>/dev/null \
                    | sort | tail -1)
      if [[ -n "${last_demo:-}" && "$last_demo" > "$last_commit" ]]; then
        continue
      fi

      jq -c --arg repo "$repo" --arg last_commit "$last_commit" --argjson fe "$frontend" \
        '{repo: $repo, number: .number, title: .title, url: .url,
          head_sha: .headRefOid, last_commit: $last_commit, frontend_files: $fe}' <<<"$info"
    done
  done
done
