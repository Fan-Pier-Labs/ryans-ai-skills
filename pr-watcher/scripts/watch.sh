#!/usr/bin/env bash
# watch.sh — the one PR-change watcher for the GitHub agent skills.
#
# Notices when an open, non-draft PR in the target repos gets a new head —
# through GitHub webhook deliveries when it can, polling when it can't — and
# appends the change to a queue file. It never acts on a change itself. Which
# skill handles a changed PR is decided by the agent running /pr-watcher: it
# drains the queue and invokes that skill per PR. (A detached shell process
# cannot invoke a skill; only a live agent can. See ../SKILL.md.)
#
# Modes:
#   (default)                    watch forever: seed, webhook or poll, enqueue changes
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
# POLL_INTERVAL (polling-mode gap, default 300s), FALLBACK_SWEEP (event-mode
# safety-net poll, default 1800s), STATE_DIR (queue and ledger live here,
# default ~/.cache/generic-coding-agents/pr-watcher), ENQUEUE_EXISTING=1 to
# queue every current head at start instead of only what changes afterwards.
set -uo pipefail

DAYS="${DAYS:-30}"
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

if date -u -v-1d +%s >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

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

# --- queue primitives ---------------------------------------------------------
# Enqueues arrive from the receiver's threads and from the poll loop at once, so
# the seen-check and the append are done under a lock.

lock()   { local i=0; until mkdir "$LOCK" 2>/dev/null; do sleep 0.05; i=$((i+1)); [[ $i -gt 200 ]] && { rm -rf "$LOCK"; }; done; }
unlock() { rmdir "$LOCK" 2>/dev/null; }

# Idempotent: a head that was already queued or seeded is a no-op.
enqueue() { # repo pr sha [via]
  local key="$1#$2@$3" via="${4:-manual}"
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

# Open non-draft PR heads for one repo, as "pr<TAB>sha" lines.
heads() { # repo
  gh pr list -R "$1" --state open --json number,isDraft,headRefOid \
    --jq '.[] | select(.isDraft | not) | [(.number|tostring), .headRefOid] | @tsv' 2>/dev/null
}

# Enqueue every current head; dedup makes unchanged ones no-ops, so this is
# both the polling step and the safety net under event mode.
poll() {
  local repo n sha
  for repo in "${REPO_LIST[@]}"; do
    while IFS=$'\t' read -r n sha; do
      [[ -n "${n:-}" ]] && enqueue "$repo" "$n" "$sha" poll
    done < <(heads "$repo")
  done
}

# Mark every current head as seen without queuing it. The watcher reports
# changes; the backlog is the target skill's own discovery script's job (it
# knows which PRs actually need work), and /pr-watcher runs that on start.
seed() {
  local repo n sha
  for repo in "${REPO_LIST[@]}"; do
    while IFS=$'\t' read -r n sha; do
      [[ -z "${n:-}" ]] && continue
      if [[ "${ENQUEUE_EXISTING:-0}" = 1 ]]; then
        enqueue "$repo" "$n" "$sha" seed
      else
        lock; grep -qxF "$repo#$n@$sha" "$SEEN" 2>/dev/null || echo "$repo#$n@$sha" >>"$SEEN"; unlock
      fi
    done < <(heads "$repo")
  done
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
  local repo
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "ERROR: a watcher is already running (pid $(cat "$PID_FILE")). Use --stop first." >&2
    exit 1
  fi
  REPO_LIST=()
  while IFS= read -r repo; do [[ -n "$repo" ]] && REPO_LIST+=("$repo"); done < <(resolve_repos)
  [[ ${#REPO_LIST[@]} -gt 0 ]] || exit 2

  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pr-watcher.XXXXXX")
  echo $$ >"$PID_FILE"
  trap cleanup EXIT
  trap on_signal INT TERM
  log "targets: ${REPO_LIST[*]}"
  log "queue: $QUEUE"

  seed
  log "seeded $(grep -c . "$SEEN" 2>/dev/null || echo 0) current heads; only changes from here on are queued"

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
  *) echo "usage: $0 [--enqueue REPO PR SHA [VIA] | --drain | --status | --stop]" >&2; exit 2 ;;
esac
