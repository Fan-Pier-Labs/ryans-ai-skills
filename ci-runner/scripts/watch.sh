#!/usr/bin/env bash
# watch.sh — long-running front end for ci-runner: run CI when GitHub says
# something changed, instead of polling for it.
#
#   ./watch.sh                      # current repo
#   REPOS='owner/repo ...' ./watch.sh
#
# Event mode uses `gh webhook forward` (the official cli/gh-webhook extension),
# which creates a temporary webhook and streams deliveries over a websocket —
# no public endpoint required. webhook-receiver.py turns each delivery into a
# `ci-runner.sh --run-one` call.
#
# Creating that webhook needs admin on the repo. If anything in the event path
# fails — extension missing and uninstallable, no admin rights, forwarder dies —
# this logs a WARNING and degrades to interval polling, which needs no special
# permissions. It never exits just because events are unavailable.
#
# Even in event mode a slow fallback sweep keeps running: `gh webhook forward`
# is a development tool and does not guarantee delivery. The commit-status
# ledger makes the overlap harmless.
#
# Env: REPOS / OWNERS (default: current repo), JOBS (concurrent PRs, default 4),
# POLL_INTERVAL (polling-mode sweep gap, default 900s), FALLBACK_SWEEP (event-mode
# safety-net sweep gap, default 3600s), plus everything ci-runner.sh reads.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/ci-runner.sh"
RECEIVER="$SCRIPT_DIR/webhook-receiver.py"
JOBS="${JOBS:-4}"
POLL_INTERVAL="${POLL_INTERVAL:-900}"
FALLBACK_SWEEP="${FALLBACK_SWEEP:-3600}"
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ci-watch.XXXXXX")
FORWARD_PIDS=()
RECEIVER_PID=""

log()  { printf '[watch] %s\n' "$*" >&2; }
warn() { printf '[watch] WARNING: %s\n' "$*" >&2; }

cleanup() {
  local pid
  for pid in "${FORWARD_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

sweep() { JOBS="$JOBS" "$RUNNER" --sweep; }

# --- event mode setup ---------------------------------------------------------

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
  local port_file="$RUN_DIR/port"
  JOBS="$JOBS" python3 "$RECEIVER" --port-file "$port_file" >>"$RUN_DIR/receiver.log" 2>&1 &
  RECEIVER_PID=$!
  local i
  for i in $(seq 1 50); do           # up to ~5s for the port to be written
    [[ -s "$port_file" ]] && { PORT=$(cat "$port_file"); return 0; }
    kill -0 "$RECEIVER_PID" 2>/dev/null || { warn "receiver exited immediately:"; tail -5 "$RUN_DIR/receiver.log" >&2; return 1; }
    sleep 0.1
  done
  warn "receiver never reported a port"
  return 1
}

# Start one forwarder per repo. Succeeds if at least one comes up; repos whose
# forwarder failed stay covered by the fallback sweep.
start_forwarders() { # repos...
  local repo pid live=0 i
  for repo in "$@"; do
    gh webhook forward --repo="$repo" --events=push,pull_request \
      --url="http://127.0.0.1:$PORT/hook" >>"$RUN_DIR/forward-${repo//\//_}.log" 2>&1 &
    pid=$!
    FORWARD_PIDS+=("$pid")
    FORWARD_REPOS+=("$repo")
  done

  # Creating the webhook is the step that fails on missing admin rights, and it
  # fails within a second or two. Give them a grace period, then check.
  sleep 10

  for i in "${!FORWARD_PIDS[@]}"; do
    if kill -0 "${FORWARD_PIDS[$i]}" 2>/dev/null; then
      live=$((live + 1))
      log "events live for ${FORWARD_REPOS[$i]}"
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

# --- main ---------------------------------------------------------------------

# (a read loop, not mapfile: macOS ships bash 3.2)
REPO_LIST=()
while IFS= read -r line; do
  [[ -n "$line" ]] && REPO_LIST+=("$line")
done < <("$RUNNER" --repos)
if [[ ${#REPO_LIST[@]} -eq 0 ]]; then
  echo "ERROR: no target repos resolved. Set REPOS='owner/repo ...' or OWNERS='org ...'." >&2
  exit 2
fi
FORWARD_REPOS=()
log "targets: ${REPO_LIST[*]}  (jobs: $JOBS)"

# Catch up on anything that changed while nothing was watching, in both modes.
log "initial catch-up sweep"
sweep

MODE=polling
if ensure_extension && start_receiver && start_forwarders "${REPO_LIST[@]}"; then
  MODE=events
fi

if [[ "$MODE" = events ]]; then
  log "event mode: CI runs on push/pull_request deliveries; fallback sweep every ${FALLBACK_SWEEP}s"
  while true; do
    sleep "$FALLBACK_SWEEP"
    if ! any_forwarder_alive; then
      warn "all webhook forwarders have died — degrading to polling every ${POLL_INTERVAL}s"
      MODE=polling
      break
    fi
    log "fallback sweep (safety net for missed deliveries)"
    sweep
  done
fi

warn_once=1
while true; do
  if [[ $warn_once = 1 ]]; then
    log "polling mode: sweeping every ${POLL_INTERVAL}s"
    warn_once=0
  fi
  sleep "$POLL_INTERVAL"
  sweep
done
