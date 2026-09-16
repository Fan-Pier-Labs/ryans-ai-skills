#!/usr/bin/env bash
# repo-targets.sh — sourced library: which repos a script works on, and the
# date arithmetic that goes with it. Shared by every GitHub-scoped skill
# (auto-reviewer, ci-runner, dependency-updater, pr-demo-media, pr-watcher).
#
# Usage, from a script in skills/<name>/scripts/:
#
#   DAYS="${DAYS:-7}"                        # the skill's own default, before sourcing
#   SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" && pwd)
#   . "$SHARED/repo-targets.sh"
#   for repo in $(resolve_repos); do ... done
#
# Provides:
#   ts_days_ago <days> [date-format]   UTC timestamp N days ago (BSD or GNU date)
#   CUTOFF                             ISO-8601 UTC, $DAYS days ago (default 30)
#   resolve_repos                      one "owner/repo" per line; exit 2 if unresolvable
#
# Sourcing it must never exit the caller on its own, so it sets no shell options.

# UTC timestamp N days ago, in either date(1) dialect.
ts_days_ago() { # <days> [format, default +%Y-%m-%dT%H:%M:%SZ]
  local days="$1" fmt="${2:-+%Y-%m-%dT%H:%M:%SZ}"
  if date -u -v-1d +%s >/dev/null 2>&1; then
    date -u -v-"${days}"d "$fmt"          # BSD / macOS
  else
    date -u -d "-${days} days" "$fmt"     # GNU
  fi
}

# ISO-8601 UTC timestamps compare correctly as strings, so callers compare
# commit/comment timestamps against $CUTOFF with [[ "$a" < "$b" ]].
CUTOFF="${CUTOFF:-$(ts_days_ago "${DAYS:-30}")}"

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
