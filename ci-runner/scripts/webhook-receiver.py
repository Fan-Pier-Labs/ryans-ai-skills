#!/usr/bin/env python3
"""Turn GitHub webhook deliveries into ci-runner --run-one calls.

Reads deliveries forwarded by `gh webhook forward` (which POSTs them to this
local server over a websocket-backed tunnel, so no public endpoint is needed)
and runs the affected PR immediately instead of waiting for the next sweep.

Binds an ephemeral port and writes it to --port-file, so the supervisor
(watch.sh) can point the forwarder at us without racing for a fixed port.

Stdlib only: this runs before/without the PyYAML venv the interpreter uses.
"""

import json
import os
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer

RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci-runner.sh")

# PR actions that produce a new head worth testing. "synchronize" is a push to
# the PR branch; "ready_for_review" matters because sweeps skip drafts.
PR_ACTIONS = {"opened", "synchronize", "reopened", "ready_for_review"}

_inflight: set[tuple[str, str]] = set()
_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"[webhook] {msg}", file=sys.stderr, flush=True)


def run_one(repo: str, number: str, sha: str) -> None:
    """Run one PR, never two of the same PR at once."""
    key = (repo, str(number))
    with _lock:
        if key in _inflight:
            log(f"{repo}#{number} already running, skipping duplicate delivery")
            return
        _inflight.add(key)
    try:
        log(f"{repo}#{number} @ {sha[:7]} -> ci-runner --run-one")
        subprocess.run([RUNNER, "--run-one", repo, str(number), sha], check=False)
    except Exception as exc:  # a receiver thread must never die on one delivery
        log(f"ERROR running {repo}#{number}: {exc}")
    finally:
        with _lock:
            _inflight.discard(key)


def pulls_for_sha(repo: str, sha: str) -> list[tuple[str, str]]:
    """Open non-draft PRs whose head is this commit (for `push` deliveries)."""
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits/{sha}/pulls",
             "--jq", '.[] | select(.state == "open") | select(.draft | not) '
                     '| [(.number|tostring), .head.sha] | @tsv'],
            capture_output=True, text=True, timeout=30,
        )
        rows = []
        for line in out.stdout.splitlines():
            if "\t" in line:
                n, head = line.split("\t", 1)
                rows.append((n, head))
        return rows
    except Exception as exc:
        log(f"ERROR resolving PRs for {repo}@{sha[:7]}: {exc}")
        return []


def dispatch(event: str, payload: dict, pool: ThreadPoolExecutor) -> None:
    repo = (payload.get("repository") or {}).get("full_name")
    if not repo:
        return

    if event == "pull_request":
        action = payload.get("action")
        if action not in PR_ACTIONS:
            return
        pr = payload.get("pull_request") or {}
        if pr.get("draft"):
            return
        number, sha = pr.get("number"), (pr.get("head") or {}).get("sha")
        if number and sha:
            pool.submit(run_one, repo, str(number), sha)

    elif event == "push":
        sha = payload.get("after")
        # 000...0 is a branch deletion; nothing to test.
        if not sha or set(sha) == {"0"}:
            return
        for number, head in pulls_for_sha(repo, sha):
            pool.submit(run_one, repo, number, head)


def make_handler(pool: ThreadPoolExecutor):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 (BaseHTTPRequestHandler's naming)
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            event = self.headers.get("X-GitHub-Event", "")
            # Ack before doing any work: the forwarder should not wait on CI.
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b"accepted")
            try:
                dispatch(event, json.loads(raw or b"{}"), pool)
            except Exception as exc:
                log(f"ERROR handling {event!r} delivery: {exc}")

        def log_message(self, *args):  # silence per-request stderr noise
            pass

    return Handler


def main() -> int:
    port_file = None
    jobs = int(os.environ.get("JOBS", "4"))
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a == "--port-file" and i + 1 < len(argv):
            port_file = argv[i + 1]

    pool = ThreadPoolExecutor(max_workers=jobs)
    server = HTTPServer(("127.0.0.1", 0), make_handler(pool))
    port = server.server_address[1]
    if port_file:
        with open(port_file, "w") as fh:
            fh.write(str(port))
    log(f"listening on 127.0.0.1:{port} (max {jobs} concurrent jobs)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
