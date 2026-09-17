#!/usr/bin/env bash
# watch.sh — the one PR-change watcher for the GitHub agent skills.
#
# At start it sweeps every open PR that qualifies — authored by $AUTHOR
# (default @me) and created within $PR_DAYS days (default 7), never drafts —
# and queues each head. Then it notices when a qualifying PR gets a new head —
# through GitHub webhook deliveries when it can, polling when it can't — and
# queues that too. It never acts on a queued head itself. Which skill handles
# it is decided by the agent running /pr-watcher: it drains the queue and
# invokes that skill per PR. (A detached shell process cannot invoke a skill;
# only a live agent can. See ../SKILL.md.)
#
# Modes:
#   (default)                    watch forever: sweep, then webhook or poll, queuing changes
#   --sweep                      queue every qualifying open head now, then exit
#   --enqueue REPO PR SHA [VIA]  append one change; deduped by repo#pr@sha
#   --drain                      print pending items as JSON lines and clear them
#   --status                     one line: mode, pending, seen, pid
#   --stop                       stop the running watcher
#
# Event mode uses `gh webhook forward` (the official cli/gh-webhook extension):
# a temporary webhook streamed over a websocket, no public endpoint. Creating
# it needs admin on the repo. Every failure on that path — extension not
# installable, no admin rights, forwarders dying later — logs a WARNING and
# degrades to polling, which needs no special permission. The watcher never
# exits just because events are unavailable, and a slow fallback poll runs even
# when events are healthy, because the forwarder has no delivery guarantee.
#
# Env: REPOS / OWNERS / DAYS (as every skill script; default: the current repo),
# AUTHOR (which PRs qualify, default @me; `anyone` for no author filter),
# PR_DAYS (PRs created within this many days qualify, default 7; 0 for no age
# filter), SWEEP=0 to skip the start-up sweep and only queue what changes
# afterwards, POLL_INTERVAL (polling-mode gap, default 300s), FALLBACK_SWEEP
# (event-mode safety-net poll, default 1800s), STATE_DIR (queue and ledger
# live here, default ~/.cache/generic-coding-agents/pr-watcher).
set -uo pipefail

DAYS="${DAYS:-30}"
AUTHOR="${AUTHOR:-@me}"
PR_DAYS="${PR_DAYS:-7}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
FALLBACK_SWEEP="${FALLBACK_SWEEP:-1800}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/generic-coding-agents/pr-watcher}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
RECEIVER="$SCRIPT_DIR/webhook-receiver.py"

QUEUE="$STATE_DIR/queue.jsonl"     # pending changes, one JSON object per line
SEEN="$STATE_DIR/seen"             # every repo#pr@sha ever queued or seeded
MODE_FILE="$STATE_DIR/mode"        # events | polling | stopped
PID_FILE="$STATE_DIR/watch.pid"
LOCK="$STATE_DIR/lock"             # mkdir lock: macOS bash has no flock
mkdir -p "$STATE_DIR"

log()  { printf '[pr-watcher] %s\n' "$*" >&2; }
warn() { printf '[pr-watcher] WARNING: %s\n' "$*" >&2; }

# Target repos (REPOS / OWNERS / the current checkout) and $CUTOFF, $DAYS days
# ago, both come from the shared library every GitHub skill uses.
SHARED=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" 2>/dev/null && pwd)
if [[ -z "$SHARED" || ! -f "$SHARED/repo-targets.sh" ]]; then
  echo "ERROR: the shared script folder is missing — expected it next to this skill at skills/shared/." >&2
  echo "       Re-vendor the skills repo (it ships skills/shared/ alongside every skill)." >&2
  exit 2
fi
. "$SHARED/repo-targets.sh"
PR_SINCE=$(ts_days_ago "$PR_DAYS" +%Y-%m-%d)

# --- queue primitives ---------------------------------------------------------
# Enqueues arrive from the receiver's threads and from the poll loop at once, so
# the seen-check and the append are done under a lock.

lock()   { local i=0; until mkdir "$LOCK" 2>/dev/null; do sleep 0.05; i=$((i+1)); [[ $i -gt 200 ]] && { rm -rf "$LOCK"; }; done; }
unlock() { rmdir "$LOCK" 2>/dev/null; }

# Idempotent: a head that was already queued or seeded is a no-op.
enqueue() { # repo pr sha [via]
  local key="$1#$2@$3" via="${4:-manual}"
  # Sweep and poll only ever see qualifying heads. A webhook delivery is for
  # any PR in the repo, so it gets the same test before it can queue anything.
  if [[ "$via" = webhook ]] && ! heads "$1" | awk -F'\t' -v n="$2" '$1==n{f=1} END{exit !f}'; then
    log "ignored $1#$2 @ ${3:0:7}: does not qualify (AUTHOR=$AUTHOR PR_DAYS=$PR_DAYS)"
    return 0
  fi
  lock
  if grep -qxF "$key" "$SEEN" 2>/dev/null; then unlock; return 0; fi
  echo "$key" >>"$SEEN"
  printf '{"ts":"%s","repo":"%s","pr":%s,"sha":"%s","via":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$via" >>"$QUEUE"
  unlock
  log "queued $1#$2 @ ${3:0:7} (via $via)"
}

# Print everything pending and clear it, atomically with respect to enqueues.
drain() {
  lock
  if [[ -s "$QUEUE" ]]; then cat "$QUEUE"; : >"$QUEUE"; fi
  unlock
}

status() {
  local mode pending seen pid alive=no
  mode=$(cat "$MODE_FILE" 2>/dev/null || echo stopped)
  # grep -c prints 0 *and* exits 1 on an empty file, so no `|| echo 0` here.
  pending=$(grep -c . "$QUEUE" 2>/dev/null); pending=${pending:-0}
  seen=$(grep -c . "$SEEN" 2>/dev/null);     seen=${seen:-0}
  pid=$(cat "$PID_FILE" 2>/dev/null || echo -)
  [[ "$pid" != - ]] && kill -0 "$pid" 2>/dev/null && alive=yes
  echo "mode=$mode pending=$pending seen=$seen pid=$pid alive=$alive"
}

# The qualifying open PR heads of one repo, as "pr<TAB>sha" lines. This is
# the one definition of "qualifies": open, not a draft, authored by $AUTHOR
# (@me = the gh-authenticated user) unless AUTHOR=anyone, and created within
# $PR_DAYS days unless PR_DAYS=0.
heads() { # repo
  local args=(-R "$1" --state open --limit 500 --json number,isDraft,headRefOid)
  [[ "$AUTHOR" != anyone ]] && args+=(--author "$AUTHOR")
  [[ "$PR_DAYS" -gt 0 ]] && args+=(--search "created:>=$PR_SINCE")
  gh pr list "${args[@]}" \
    --jq '.[] | select(.isDraft | not) | [(.number|tostring), .headRefOid] | @tsv' 2>/dev/null
}

# Queue every qualifying current head, tagged with how it got there. Dedup
# makes already-seen heads no-ops, so this is the start-up sweep, the polling
# step and the safety net under event mode, all in one.
enqueue_heads() { # via
  local repo n sha
  for repo in "${REPO_LIST[@]}"; do
    while IFS=$'\t' read -r n sha; do
      [[ -n "${n:-}" ]] && enqueue "$repo" "$n" "$sha" "$1"
    done < <(heads "$repo")
  done
}
sweep() { enqueue_heads sweep; }
poll()  { enqueue_heads poll; }

# SWEEP=0: mark every qualifying head as seen without queuing it, so only
# what changes from here on is queued.
seed() {
  local repo n sha
  for repo in "${REPO_LIST[@]}"; do
    while IFS=$'\t' read -r n sha; do
      [[ -n "${n:-}" ]] || continue
      lock; grep -qxF "$repo#$n@$sha" "$SEEN" 2>/dev/null || echo "$repo#$n@$sha" >>"$SEEN"; unlock
    done < <(heads "$repo")
  done
}

load_repos() {
  local repo
  REPO_LIST=()
  while IFS= read -r repo; do [[ -n "$repo" ]] && REPO_LIST+=("$repo"); done < <(resolve_repos)
  [[ ${#REPO_LIST[@]} -gt 0 ]] || exit 2
}

# --- event mode ---------------------------------------------------------------

FORWARD_PIDS=()
FORWARD_REPOS=()
RECEIVER_PID=""
RUN_DIR=""

SLEEP_PID=""

# Interruptible sleep. A plain `sleep N` in the foreground defers every trap
# until N elapses (bash runs traps only between foreground commands), so a
# --stop would take up to FALLBACK_SWEEP to land. `wait` is interruptible.
snooze() { { sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID"; } 2>/dev/null; SLEEP_PID=""; }   # group: hides the "Terminated" job notice on stop

# Runs once, whichever of EXIT / INT / TERM gets there first.
cleanup() {
  trap - EXIT INT TERM
  local pid repo i
  [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
  for pid in "${FORWARD_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
  # `gh webhook forward` is supposed to delete its temporary hook on exit and
  # in practice often doesn't make it in time. The watcher knows which repos it
  # registered on, so it removes any forwarder hook left behind itself.
  if [[ ${#FORWARD_PIDS[@]} -gt 0 ]]; then
    for i in 1 2 3 4 5; do any_forwarder_alive || break; sleep 1; done
    for repo in "${REPO_LIST[@]:-}"; do
      [[ -n "$repo" ]] || continue
      for pid in $(gh api "repos/$repo/hooks"                      --jq '.[] | select(.config.url | contains("webhook-forwarder.github.com")) | .id' 2>/dev/null); do
        gh api -X DELETE "repos/$repo/hooks/$pid" >/dev/null 2>&1 && log "removed leftover forwarder hook $pid on $repo"
      done
    done
  fi
  echo stopped >"$MODE_FILE"
  rm -f "$PID_FILE"
  [[ -n "$RUN_DIR" ]] && rm -rf "$RUN_DIR"
}

# A TERM handler that only cleans up would let the loop resume afterwards.
on_signal() { cleanup; exit 143; }

# The gh-webhook extension, installed on demand. Returns 1 (not fatal) if it
# cannot be made available — the caller degrades to polling.
ensure_extension() {
  if gh extension list 2>/dev/null | grep -q 'gh-webhook'; then return 0; fi
  log "installing the gh-webhook extension (cli/gh-webhook)"
  if gh extension install cli/gh-webhook >/dev/null 2>&1; then return 0; fi
  warn "could not install cli/gh-webhook"
  return 1
}

start_receiver() {
  local port_file="$RUN_DIR/port" i
  python3 "$RECEIVER" --port-file "$port_file" --on-change "$SELF" --enqueue \
    >>"$RUN_DIR/receiver.log" 2>&1 &
  RECEIVER_PID=$!
  for i in $(seq 1 50); do           # up to ~5s for the port to be written
    [[ -s "$port_file" ]] && { PORT=$(cat "$port_file"); return 0; }
    kill -0 "$RECEIVER_PID" 2>/dev/null || { warn "receiver exited immediately:"; tail -5 "$RUN_DIR/receiver.log" >&2; return 1; }
    sleep 0.1
  done
  warn "receiver never reported a port"
  return 1
}

# One forwarder per repo. Succeeds if at least one comes up; repos whose
# forwarder failed stay covered by the fallback poll.
start_forwarders() {
  local repo live=0 i
  for repo in "${REPO_LIST[@]}"; do
    gh webhook forward --repo="$repo" --events=push,pull_request \
      --url="http://127.0.0.1:$PORT/hook" >>"$RUN_DIR/forward-${repo//\//_}.log" 2>&1 &
    FORWARD_PIDS+=("$!")
    FORWARD_REPOS+=("$repo")
  done
  # Creating the webhook is the step that fails on missing admin rights, and
  # it fails within a second or two. Grace period, then check.
  snooze 10
  for i in "${!FORWARD_PIDS[@]}"; do
    if kill -0 "${FORWARD_PIDS[$i]}" 2>/dev/null; then
      live=$((live + 1)); log "events live for ${FORWARD_REPOS[$i]}"
    else
      warn "webhook forwarding failed for ${FORWARD_REPOS[$i]} (usually: no admin rights on the repo). Reason:"
      sed -n '1,5p' "$RUN_DIR/forward-${FORWARD_REPOS[$i]//\//_}.log" >&2
    fi
  done
  [[ $live -gt 0 ]]
}

any_forwarder_alive() {
  local pid
  for pid in "${FORWARD_PIDS[@]:-}"; do kill -0 "$pid" 2>/dev/null && return 0; done
  return 1
}

watch() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "ERROR: a watcher is already running (pid $(cat "$PID_FILE")). Use --stop first." >&2
    exit 1
  fi
  load_repos

  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pr-watcher.XXXXXX")
  echo $$ >"$PID_FILE"
  trap cleanup EXIT
  trap on_signal INT TERM
  log "targets: ${REPO_LIST[*]}"
  log "qualifying: open, non-draft, author=$AUTHOR, created within ${PR_DAYS}d"
  log "queue: $QUEUE"

  if [[ "${SWEEP:-1}" = 1 ]]; then
    local before after
    before=$(grep -c . "$QUEUE" 2>/dev/null); before=${before:-0}
    sweep
    after=$(grep -c . "$QUEUE" 2>/dev/null); after=${after:-0}
    log "SWEEP=done — $((after - before)) qualifying heads queued, $after pending in total"
  else
    seed
    log "SWEEP=skipped — $(grep -c . "$SEEN" 2>/dev/null || echo 0) heads marked seen; only changes from here on are queued"
  fi

  local mode=polling
  if ensure_extension && start_receiver && start_forwarders; then mode=events; fi
  echo "$mode" >"$MODE_FILE"

  if [[ "$mode" = events ]]; then
    log "MODE=events — queuing on push/pull_request deliveries; safety-net poll every ${FALLBACK_SWEEP}s"
    while true; do
      snooze "$FALLBACK_SWEEP"
      if ! any_forwarder_alive; then
        warn "all webhook forwarders have died — degrading to polling every ${POLL_INTERVAL}s"
        echo polling >"$MODE_FILE"
        break
      fi
      poll
    done
  fi

  log "MODE=polling — checking heads every ${POLL_INTERVAL}s"
  while true; do
    snooze "$POLL_INTERVAL"
    poll
  done
}

# --- entry points -------------------------------------------------------------

case "${1:-}" in
  "")          watch ;;
  --sweep)     load_repos; sweep ;;
  --enqueue)   shift; [[ $# -ge 3 ]] || { echo "usage: $0 --enqueue REPO PR SHA [VIA]" >&2; exit 2; }; enqueue "$@" ;;
  --drain)     drain ;;
  --status)    status ;;
  --stop)
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      pid=$(cat "$PID_FILE"); kill "$pid"
      for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      if kill -0 "$pid" 2>/dev/null; then
        warn "watcher $pid did not exit within 20s; not forcing it (a kill -9 would leave the webhook behind)"; exit 1
      fi
      log "stopped watcher $pid"
    else
      log "no watcher running"
    fi ;;
  *) echo "usage: $0 [--sweep | --enqueue REPO PR SHA [VIA] | --drain | --status | --stop]" >&2; exit 2 ;;
esac
