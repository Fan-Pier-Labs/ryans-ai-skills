---
name: pr-watcher
description: Watch the target repos for pull requests that get new commits — GitHub webhook deliveries when possible, polling otherwise — and run another skill on each changed PR. "/pr-watcher run /auto-reviewer" reviews every PR the moment it changes; "/pr-watcher run /ci-runner /auto-reviewer" does both from one watcher. One webhook, one queue, any number of skills, changed PRs handled in parallel. Use whenever the user wants a skill to react to PR activity instead of sweeping on a timer — "watch PRs and review them", "run CI when a PR changes", "start the watcher", "trigger X whenever a PR updates".
---

# PR Watcher

Two layers, and the seam between them is the whole design:

- **`scripts/watch.sh`** (a background process) notices when an open,
  non-draft PR gets a new head and appends it to a queue file. It never acts
  on the change and never writes to GitHub. Webhook deliveries when it can
  get them, polling when it can't (details below).
- **You** (the agent running this skill) drain that queue and invoke the
  target skill(s) on each changed PR — a subagent per PR, several at once.

The seam exists because **a detached shell process cannot invoke a skill;
only a live agent can.** So while no agent is running `/pr-watcher`, the queue
fills and nothing else happens. It persists on disk; the next `run` drains it.
The webhook buys low latency *within* a session — it cannot wake a session
that isn't there.

Why one watcher rather than one per skill: however many skills are attached,
there is one webhook on the repo, one forwarder, one poller. Three skills each
watching the same repo would triple all of that for the same events.

## Usage

```
/pr-watcher run /auto-reviewer                    # review every PR as it changes
/pr-watcher run /ci-runner /auto-reviewer         # CI and review, one watcher
/pr-watcher run /ci-runner /auto-reviewer /pr-demo-media
/pr-watcher status
/pr-watcher stop
```

Every target skill must be installed as a sibling of this one and have a
**"Single-PR invocation"** section in its `SKILL.md` — that section is the
contract this skill dispatches against. ci-runner, auto-reviewer and
pr-demo-media have one.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

## `run` — starting

1. **Resolve the targets.** Each `/name` must exist as `../name/SKILL.md`
   with a "Single-PR invocation" section. Read that section for each — it
   tells you the skill's idempotency rule and whether it needs a subagent at
   all. A missing skill is a hard stop: say which, don't substitute.

2. **Start the watcher** in the background and keep it running for the
   session:

   ```bash
   REPOS='owner/repo' scripts/watch.sh
   ```

   Wait for its `MODE=events` or `MODE=polling` line (allow ~30s; the first
   run may install the `gh-webhook` extension). Relay the mode to the user.
   If it is polling, relay the `WARNING` line verbatim — the usual cause is
   no admin rights on the repo, and the user should know events are not live.

3. **Catch up on the backlog.** The watcher seeds every current head as
   already-seen and queues only what changes afterwards — it does not know
   which existing PRs still need work. The target skill does: run its own
   discovery once and treat every result as a queued item for that skill.

   | Skill | Discovery |
   | --- | --- |
   | ci-runner | `ci-runner/scripts/ci-runner.sh --discover` (TSV: repo, pr, sha) |
   | auto-reviewer | `auto-reviewer/scripts/find-review-candidates.sh` (JSON lines) |
   | pr-demo-media | `pr-demo-media/scripts/find-demo-candidates.sh` (JSON lines) |

4. Enter the drain loop.

## The drain loop

Each tick:

1. `scripts/watch.sh --drain` prints every pending item as a JSON line
   (`{ts, repo, pr, sha, via}`) and clears the queue. Empty is normal.
2. For each item × each target skill, dispatch as below. Keep at most
   **`JOBS`** (default 3) subagents in flight; hold the rest and dispatch as
   slots free up — a finishing subagent re-invokes you, so no polling is
   needed for that.
3. Stay alive between ticks without a foreground sleep. Prefer a **Monitor**
   on the queue file (`~/.cache/generic-coding-agents/pr-watcher/queue.jsonl`
   growing) so a delivery wakes you immediately; fall back to
   `ScheduleWakeup` or `/loop` at 5–10 minutes as the heartbeat. The watcher
   keeps queuing either way.
4. After every non-empty tick, report one line per item: skill, PR, outcome
   (a link to what was posted, or `skipped: <reason>`).

## Dispatching one item

**Deterministic skills need no subagent.** ci-runner's per-PR command is a
shell call: run `ci-runner/scripts/ci-runner.sh --run-one REPO PR SHA` in the
background and count it against `JOBS`. Its `local-ci` commit status is the
result.

**Judgment skills get one subagent per PR** (general-purpose), with this
prompt — the "Single-PR invocation" section it points at does the rest:

```
Invoke the `<skill>` skill for exactly one pull request: <repo>#<pr>, head <sha>.
Follow that skill's "Single-PR invocation" section: skip its discovery sweep,
check its idempotency rule for this head first, then do its one-PR procedure.
All of the skill's guardrails apply (comment only / status only; never push,
merge, or close). Report in one line: what you posted (link) or why you skipped.
```

If the head moved between queueing and dispatch, the skill's own check will
see the newer head; the item for the newer head arrives later and is a no-op.
That is the intended outcome, not a bug to route around.

## `status`

`scripts/watch.sh --status` → `mode=events|polling|stopped pending=N seen=N
pid=P alive=yes|no`. Relay it. `alive=no` with `mode=events` means the
watcher died without cleaning up — start it again.

## `stop`

`scripts/watch.sh --stop`. On a clean exit `gh webhook forward` removes its
temporary hook from the repo. Pending items stay queued on disk for the next
`run`. After a hard kill (machine sleep, `kill -9`) a hook pointing at
`webhook-forwarder.github.com` can linger in the repo's webhook settings —
that is the residue, and it is safe to delete.

## Guardrails

- **The watcher writes nothing to GitHub.** Every write happens inside a
  target skill, under that skill's own rules and markers.
- **Never exceed `JOBS` subagents at once.** Each one is a full session's
  worth of tokens; the cap is the cost control.
- **Never handle one `repo#pr@sha` twice for one skill.** The skills'
  markers and statuses are the ledger; the watcher's `seen` file only stops
  re-queuing, it is not proof of completion.
- **Report the mode honestly.** Polling is a legitimate fallback; say so.
  Don't tell the user events are live unless the watcher printed
  `MODE=events`.

## Tuning

`REPOS` / `OWNERS` / `DAYS` as on every script in this repo. `JOBS`
(concurrent subagents, default 3). `POLL_INTERVAL` (polling-mode gap,
default 300s). `FALLBACK_SWEEP` (event-mode safety-net poll, default 1800s —
`gh webhook forward` has no delivery guarantee). `STATE_DIR` (queue, ledger,
pid; default `~/.cache/generic-coding-agents/pr-watcher`).
`ENQUEUE_EXISTING=1` queues every current head at start instead of seeding
them as seen — use it when you want the watcher, not the skills' discovery,
to define the backlog.
