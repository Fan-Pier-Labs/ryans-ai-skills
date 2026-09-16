# House style for skills in this repo

Every skill in this repo follows the same shape. A new one should be
indistinguishable in form from the existing ones — read two of them
(`auto-reviewer`, `pr-watcher`) before writing yours.

## Layout

```
skills/<name>/
  SKILL.md              # required — the whole skill, for the agent
  references/*.md       # optional — checklists, templates, recipes the SKILL.md links to
  scripts/*.sh|*.py     # only for deterministic discovery/inventory; read-only
  README.md             # only if design notes don't fit in SKILL.md (ci-runner has one)
  evals/evals.json      # optional — trigger/behaviour evals

skills/shared/          # not a skill (no SKILL.md) — the one copy of whatever
                        # two or more skills need; see skills/shared/README.md
```

Markdown first. A skill is a procedure the model follows; scripts exist
where the same shell would be re-derived on every run (finding candidate
PRs, listing an account's resources) and the result must be identical
each time. If in doubt, no script.

## Frontmatter

```yaml
---
name: <name>            # identical to the directory name; this is the /slash-command
description: <what it does, in one or two sentences>. Use whenever the user asks to <trigger phrase>, "<trigger phrase>", <trigger phrase>, or <situation>.
---
```

The `description` is the only thing the harness reads to decide whether
to load the skill. Put the trigger phrases in it verbatim, including the
casual ones ("run the video agent", "freshen packages"). Say what the
skill does *not* cover when a neighbouring skill covers it (sec-ops vs
infra-audit both do this).

## Body sections, in the usual order

1. **Title + one paragraph**: what it does, what it never does (merges,
   deletes, writes to a provider).
2. **Which repos / Which account** — reuse this paragraph verbatim for
   anything GitHub-scoped:

   > By default every script targets **the repo you are currently in**
   > (resolved from `git remote get-url origin`). It never enumerates the
   > user's GitHub account. To widen the scope, set `REPOS='owner/repo ...'`
   > or `OWNERS='org user ...'` (owners are expanded to their repos pushed
   > within `DAYS`). If the script exits with `could not determine the
   > target repo`, **ask the user which repo(s) or org(s) to target** and
   > re-run with `REPOS` or `OWNERS` set — do not guess, and do not scan
   > their account.

3. **The procedure**, numbered, each step with the exact command in a
   fenced block. Say what output to expect and what to do on each outcome.
   Steps the model must not skim get told so ("this is the point of the
   skill, don't skim it").
4. **Single-PR invocation** — required if pr-watcher should dispatch it.
   The contract: given `repo`, `pr`, `head sha`, (a) skip the discovery
   sweep, (b) the one command that checks the idempotency rule for this
   head (usually a marker-comment lookup), (c) the one-PR procedure.
5. **Report** — what to say at the end, and in what order.
6. **Guardrails** — bulleted, each one a hard rule: what it writes, what it
   never does, the cost cap, the idempotency rule.
7. **Tuning** — env vars, with defaults.

## Conventions the whole repo shares

- **Markers**: every comment posted to GitHub starts with
  `<!-- generic-coding-agents:<name> sha:<head_sha> -->`. Discovery
  compares the marker against the PR's latest commit; nothing is posted
  twice for one head.
- **Never a second copy**: anything a second skill needs goes in
  `skills/shared/` and the skill reaches it by a relative symlink, by
  sourcing it, or through a wrapper holding only that skill's defaults —
  never by copying the file. `resolve_repos` and the "which repos"
  paragraph above come from `shared/repo-targets.sh`; a skill that sweeps
  open PRs wraps `shared/find-pr-candidates.sh` instead of writing its own
  loop. A shared script takes **arguments**, not a set of env vars the
  caller exports — a flag the call site spells out beats a knob defined
  elsewhere. Read `skills/shared/README.md` before adding a script.
- **Env**: `REPOS`, `OWNERS`, `DAYS`, `MARKER` on every discovery script;
  `STATE_DIR` under `~/.cache/generic-coding-agents/<name>` if the skill
  keeps state.
- **Scripts**: `#!/usr/bin/env bash`, `set -euo pipefail`, executable bit
  set, read-only against GitHub / cloud providers, exit 2 with
  `could not determine the target repo` when the repo can't be resolved.
  One JSON line per result on stdout, diagnostics on stderr.
- **Write surfaces are enumerated**: the README's conventions section
  lists exactly what each skill writes (comments only; statuses + one
  upserted comment; branches + PRs; nothing). Add the new skill to that
  list.
- **No personal references.** No names, GitHub logins, emails, account
  ids, company hostnames, or org slugs anywhere in the skill. Generic
  placeholders (`owner/repo`, `<name>`, `example.com`).
- **Audit skills never write to a provider or a server.** Inventory is
  read-only, the on-box collectors only read, every change is a
  recommendation with a snapshot-first, two-confirmation gate.

## README wiring

Three edits, every time:

1. A row in the skills table: `| [<name>](skills/<name>/SKILL.md) | what it does | cadence |`.
   Cadence is one of: `on demand`, `continuous loop, ~N min`, `while the
   session runs`, `on demand / weekly`, `every ~N min, or on PR events via pr-watcher`.
2. The name appended to the `for s in …` install loop.
3. The skill count in the README's first sentence, and the composition
   paragraph at the end if the skill feeds or consumes another one.
