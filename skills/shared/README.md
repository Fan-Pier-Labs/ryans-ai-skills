# skills/shared

**Not a skill** — there is no `SKILL.md` here, so nothing loads it as one. This
is the one copy of the scripts more than one skill needs, sitting next to the
skills so that it travels with them: `.claude/skills` is a symlink to `skills/`,
and repos that vendor this one copy `skills/*` wholesale, so `shared/` lands
beside every skill in both places and `../../shared/<file>` always resolves.

| File | Used by | What it is |
| --- | --- | --- |
| `repo-targets.sh` | auto-reviewer, ci-runner, dependency-updater, pr-demo-media, pr-watcher | Sourced library: `resolve_repos` (REPOS / OWNERS / the current checkout), `$CUTOFF`, `ts_days_ago` |
| `find-pr-candidates.sh` | auto-reviewer, pr-demo-media | The open-PR discovery sweep, parameterized by marker / path filter / whether reviews count |
| `ec2-ssh-sweep.sh` | infra-audit, infra-cost-audit, sec-ops-audit | `discover` running EC2 instances, then `run` a read-only collector on each over SSH or SSM |

## How skills reach it

A whole executable is reached through a **relative symlink**, so the path each
SKILL.md documents (`scripts/ec2-ssh-sweep.sh`) keeps working:

```bash
ln -s ../../shared/ec2-ssh-sweep.sh skills/<name>/scripts/ec2-ssh-sweep.sh
```

A library is **sourced**, after resolving the folder from the script's own
location:

```bash
SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" 2>/dev/null && pwd)
if [[ -z "$SHARED" || ! -f "$SHARED/repo-targets.sh" ]]; then
  echo "ERROR: the shared script folder is missing — expected it next to this skill at skills/shared/." >&2
  echo "       Re-vendor the skills repo (it ships skills/shared/ alongside every skill)." >&2
  exit 2
fi
. "$SHARED/repo-targets.sh"
```

A shared script that needs per-skill defaults gets a **wrapper** at the path the
SKILL.md documents, holding nothing but those defaults and an `exec` — see
`skills/auto-reviewer/scripts/find-review-candidates.sh` (12 lines) and
`skills/pr-demo-media/scripts/find-demo-candidates.sh`.

## Rules

- Nothing here writes to GitHub, a cloud provider, or a server. Same guarantee
  as the discovery scripts that call it.
- A change here changes every skill that uses it. Run the callers listed above
  before opening the PR; they are read-only, so running them is free.
- Only put something here once a **second** skill needs it. One caller means it
  belongs in that skill's own `scripts/`.
