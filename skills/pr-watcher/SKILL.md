---
name: pr-watcher
description: Run another skill on every qualifying pull request — first a catch-up sweep of the ones open now, then each one again the moment it gets new commits or merges (GitHub webhook deliveries; polling only as the fallback when a repo will not grant a webhook). This is how the background agents run continuously: none of them has a timer of its own. Qualifying means authored by the user and opened in the last 7 days unless told otherwise. "/pr-watcher run /auto-reviewer" reviews your open PRs now and every one as it changes; "/pr-watcher run /ci-runner /auto-reviewer" does both from one watcher. One webhook, one queue, any number of skills, PRs handled in parallel. Use whenever the user wants a skill to react to PR activity instead of sweeping on a timer — "watch PRs and review them", "run CI when a PR changes", "start the watcher", "trigger X whenever a PR updates".
---

# PR Watcher

Two layers, and the seam between them is the whole design:

- **`scripts/watch.sh`** (a background process) queues PR items to a file.
  At start it sweeps every open PR that qualifies (below) and queues each
  one; from then on it queues a qualifying PR again whenever it gets a new
  head **or merges**. It never acts on a queued item and never writes to
  GitHub. Webhook deliveries when it can get them, polling when it can't
  (details below).
- **You** (the agent running this skill) drain that queue and invoke the
  target skill(s) on each queued PR — a subagent per PR, several at once.

The seam exists because **a detached shell process cannot invoke a skill;
only a live agent can.** So while no agent is running `/pr-watcher`, the queue
fills and nothing else happens. It persists on disk; the next `run` drains it.
The webhook buys low latency *within* a session — it cannot wake a session
that isn't there. That is the one case where an interval sweep of a target
skill (cron over `ci-runner.sh`) still beats this: no session to deliver to.

Why one watcher rather than one per skill: however many skills are attached,
there is one webhook on the repo, one forwarder, one poller. Three skills each
watching the same repo would triple all of that for the same events.

## Usage

```
/pr-watcher run /auto-reviewer                    # review my open PRs now, then each as it changes
/pr-watcher run /ci-runner /auto-reviewer         # CI and review, one watcher
/pr-watcher run /ci-runner /auto-reviewer /pr-demo-media
/pr-watcher status
/pr-watcher stop
```

Widen or narrow the PRs in words — "everyone's PRs", "from the last month",
"only alice's" — and set `AUTHOR` / `PR_DAYS` on the watcher accordingly
(see **Which PRs qualify**).

Every target skill must be installed as a sibling of this one and have a
**"Single-PR invocation"** section in its `SKILL.md` — that section is the
contract this skill dispatches against. ci-runner, auto-reviewer and
pr-demo-media have one; auto-reviewer also has a **"Merged-PR invocation"**
section, which is what a merge event dispatches against.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

## Which PRs qualify

The watcher applies one rule everywhere — the start-up sweep, the poll, and
webhook deliveries alike — so a skill is never run on a PR the sweep would
not have found:

- open and not a draft;
- authored by **`AUTHOR`**, default `@me` (the `gh`-authenticated user).
  `AUTHOR=anyone` drops the author filter; any GitHub login narrows it;
- created within the last **`PR_DAYS`** days, default `7`. `PR_DAYS=0`
  drops the age filter.

The defaults are deliberate: these skills spend real tokens per PR, and the
PRs the user is working on this week are the ones worth spending on. Widen
only when the user says so.

A **merged** PR by `AUTHOR` qualifies too, whatever its age — `PR_DAYS` asks
what is worth working on now, and a PR opened months ago and merged today is
exactly the case a merge follow-up is for. Merged items are a different kind
of work, not another review; see [Item kinds](#item-kinds).

## `run` — starting

1. **Resolve the targets.** Each `/name` must exist as `../name/SKILL.md`
   with a "Single-PR invocation" section. Read that section for each — it
   tells you the skill's idempotency rule and whether it needs a subagent at
   all. Note which of them also has a "Merged-PR invocation" section; those
   are the only ones a `merged` item goes to. A missing skill is a hard stop:
   say which, don't substitute.

2. **Start the watcher** in the background and keep it running for the
   session, with `AUTHOR` / `PR_DAYS` only if the user asked for something
   other than the defaults:

   ```bash
   REPOS='owner/repo' scripts/watch.sh
   ```

   It sweeps first: its `SWEEP=done — N qualifying heads queued` line says
   how many open PRs it found. Relay that count — if it is 0, say so, and say
   what the filter was (author, window); the user may have meant a wider
   one. Then wait for its `MODE=events` or `MODE=polling` line (allow ~30s;
   the first run may install the `gh-webhook` extension). Relay the mode. If
   it is polling, relay the `WARNING` line verbatim — the usual cause is no
   admin rights on the repo, and the user should know events are not live.

3. **Enter the drain loop.** The first tick drains the sweep, so every
   qualifying open PR is handled before any change arrives. The queue does
   not know which of them a skill has already handled — the skill's own
   idempotency check does, and the dispatch step below runs it before
   spending anything.

## Item kinds

Every queued item carries a `kind`, and it decides which skills see it:

| `kind` | Queued when | Dispatched to |
| --- | --- | --- |
| `head` | a qualifying PR is open with a head nothing has handled yet — the start-up sweep, a `push` / `pull_request` delivery, or the fallback poll | every target skill, through its **"Single-PR invocation"** section |
| `merged` | a qualifying PR merges — the `pull_request` `closed` delivery, or `gh pr list --state merged` on the fallback path. `sha` is the merge commit | only skills with a **"Merged-PR invocation"** section. Today that is auto-reviewer (the issue it opens when a 🔴 finding merged unaddressed) |

A `merged` item dispatched to a skill without that section is a no-op, not an
error: say `skipped: <skill> has no merged-PR contract` and spend nothing.
Never review, run CI on, or demo a merged PR — it is closed, and the
comment channel with it.

## The drain loop

Each tick:

1. `scripts/watch.sh --drain` prints every pending item as a JSON line
   (`{ts, repo, pr, sha, kind, via}`) and clears the queue. Empty is normal.
2. For each item × each target skill that takes that `kind`, dispatch as
   below. Keep at most **`JOBS`** (default 3) subagents in flight; hold the
   rest and dispatch as slots free up — a finishing subagent re-invokes you,
   so no polling is needed for that.
3. Stay alive between ticks **without a timer of your own**. A **Monitor** on
   the queue file (`~/.cache/generic-coding-agents/pr-watcher/queue.jsonl`
   growing) is the mechanism: a delivery wakes you within seconds, and you
   spend nothing while the queue is quiet. Only if a Monitor is unavailable,
   fall back to `ScheduleWakeup` or `/loop` at 5–10 minutes — and say that you
   did, because it is a latency downgrade, not a preference. The watcher keeps
   queuing either way.
4. After every non-empty tick, report one line per item: skill, PR, outcome
   (a link to what was posted, or `skipped: <reason>`).

## Dispatching one item

**A `merged` item goes to one place.** Dispatch it only to target skills whose
`SKILL.md` has a "Merged-PR invocation" section, with this prompt; every other
skill skips it (see [Item kinds](#item-kinds)).

```
Invoke the `<skill>` skill for exactly one *merged* pull request: <repo>#<pr>,
merge commit <sha>. Follow that skill's "Merged-PR invocation" section and
nothing else — do not review, run, or demo a closed PR. Its idempotency rule
applies first. Report in one line: what you opened (link) or why you skipped.
```

**Deterministic skills need no subagent.** ci-runner's per-PR command is a
shell call: run `skills/ci-runner/scripts/ci-runner.sh --run-one REPO PR SHA` in the
background and count it against `JOBS`. Its `local-ci` commit status is the
result.

**Judgment skills get one subagent per PR** (general-purpose). Before
spawning it, run the skill's idempotency check yourself — the one command in
its "Single-PR invocation" section (a marker-comment lookup) — and if the
head is already handled, report `skipped: already handled` and spawn
nothing. After a sweep most items are exactly that, and a subagent that
starts up only to find the marker is the expensive way to learn it. Then, for
the rest, this prompt — the "Single-PR invocation" section it points at does
the rest:

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

`scripts/watch.sh --stop`. It waits up to 20s for the watcher to exit and
says whether it did. On the way out the watcher removes any temporary hook
(`webhook-forwarder.github.com`) it registered — `gh webhook forward` is
supposed to do that itself and in practice often dies first. Pending items
stay queued on disk for the next `run`.

Only a hard kill (`kill -9`, the machine dying) skips that cleanup; then a
forwarder hook can linger in the repo's webhook settings. The next `run`'s
stop will remove it, or delete it by hand — nothing else uses that URL.

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
- **Never add a timer on top.** The watcher is the clock. Re-running a target
  skill's own sweep on an interval while a watcher is up duplicates every
  query for nothing — the markers would stop the double post, but not the
  double spend.

## Tuning

`REPOS` / `OWNERS` / `DAYS` as on every script in this repo. `AUTHOR`
(default `@me`; `anyone` for no author filter) and `PR_DAYS` (default 7; 0
for no age filter) define which PRs qualify. `MERGED_DAYS` (default 1) is how
far back the merge query looks on the paths where a poll stands in for the
`closed` delivery — the start-up catch-up, a repo with no webhook, and the
safety-net poll. `SWEEP=0` skips the start-up sweep and marks the current
heads and recent merges as seen, so only later changes are queued.
`scripts/watch.sh --sweep` queues those same items on demand without starting
a watcher. `JOBS` (concurrent subagents, default 3).
`POLL_INTERVAL` (polling-mode gap, default 300s). `FALLBACK_SWEEP`
(event-mode safety-net poll, default 1800s — `gh webhook forward` has no
delivery guarantee). `STATE_DIR` (queue, ledger, pid; default
`~/.cache/generic-coding-agents/pr-watcher`).
