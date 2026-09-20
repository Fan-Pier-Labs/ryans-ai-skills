# skills/shared

**Not a skill** — there is no `SKILL.md` here, so nothing loads it as one. This
is the one copy of the scripts more than one skill needs, sitting next to the
skills so that it travels with them: `.claude/skills` is a symlink to `skills/`,
and repos that vendor this one copy `skills/*` wholesale, so `shared/` lands
beside every skill in both places and `../../shared/<file>` always resolves.

| File | Used by | What it is |
| --- | --- | --- |
| `repo-targets.sh` | auto-reviewer, ci-runner, dependency-updater, pr-demo-media, pr-watcher | Sourced library: `resolve_repos` (REPOS / OWNERS / the current checkout), `$CUTOFF`, `ts_days_ago` |
| `find-pr-candidates.sh` | auto-reviewer, pr-demo-media | The open-PR discovery sweep: `find-pr-candidates.sh [--touching <regex>] [--reviews-are-feedback] <marker>...` |
| `ec2-ssh-sweep.sh` | infra-audit, infra-cost-audit, sec-ops-audit | `discover` running EC2 instances, then `run` a read-only collector on each over SSH or SSM |
| `dependency-preflight.md` | code-quality-audit, sec-ops-audit, pr-demo-media, dependency-updater, enable-more-lint-or-ts-checks | Not a script — the contract for the tools a skill cannot run without: detect, ask once, then install or stop |

`dependency-preflight.md` is the one exception to "scripts": it is a rule several skills follow
rather than code they call. A skill reaches it the same way, by relative path
(`../shared/dependency-preflight.md`), and states its own gate inline in its SKILL.md — the
shared file holds the parts that are identical everywhere (what goes in the ask, ephemeral vs
project installs, what a no means) so five skills do not each invent a different answer.

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

A shared script a skill calls with its own arguments gets a **wrapper** at the
path that skill's SKILL.md documents, holding nothing but those arguments and an
`exec`, so the call site reads as a sentence:

```bash
exec "$SHARED/find-pr-candidates.sh" --reviews-are-feedback \
  "${MARKER:-generic-coding-agents:auto-reviewer}"
```

Arguments, not env vars: `--reviews-are-feedback` says what it does where you
read it. An exported knob three lines above the `exec` does not, and a reader
then has to go find the shared script to learn what the skill actually asked
for.

## Rules

- Nothing here writes to GitHub, a cloud provider, or a server. Same guarantee
  as the discovery scripts that call it.
- A change here changes every skill that uses it. Run the callers listed above
  before opening the PR; they are read-only, so running them is free.
- Only put something here once a **second** skill needs it. One caller means it
  belongs in that skill's own `scripts/`.
