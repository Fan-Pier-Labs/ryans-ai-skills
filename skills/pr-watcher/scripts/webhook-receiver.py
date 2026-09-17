#!/usr/bin/env python3
"""Turn GitHub webhook deliveries into `<on-change> REPO PR SHA VIA` calls.

Reads deliveries forwarded by `gh webhook forward` (which POSTs them to this
local server over a websocket-backed tunnel, so no public endpoint is needed)
and hands every changed PR head to the command given with --on-change — for
watch.sh that is `watch.sh --enqueue`, which is idempotent, so duplicate
deliveries for one head cost nothing. A merged PR is handed over too, as
`via=merged`, because "this landed" is work in its own right.

Binds an ephemeral port and writes it to --port-file, so the supervisor can
point the forwarder at us without racing for a fixed port. Stdlib only.
"""

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# PR actions that produce a head worth handling. "synchronize" is a push to
# the PR branch; "ready_for_review" matters because every skill skips drafts.
PR_ACTIONS = {"opened", "synchronize", "reopened", "ready_for_review"}


def log(msg: str) -> None:
    print(f"[webhook] {msg}", file=sys.stderr, flush=True)


def pulls_for_sha(repo: str, sha: str) -> list[tuple[str, str]]:
    """Open non-draft PRs whose head is this commit (for `push` deliveries)."""
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits/{sha}/pulls",
             "--jq", '.[] | select(.state == "open") | select(.draft | not) '
                     '| [(.number|tostring), .head.sha] | @tsv'],
            capture_output=True, text=True, timeout=30,
        )
        return [tuple(line.split("\t", 1)) for line in out.stdout.splitlines() if "\t" in line]
    except Exception as exc:
        log(f"ERROR resolving PRs for {repo}@{sha[:7]}: {exc}")
        return []


def dispatch(event: str, payload: dict, on_change: list[str]) -> None:
    repo = (payload.get("repository") or {}).get("full_name")
    if not repo:
        return
    items: list[tuple[str, str, str]] = []     # (pr, sha, via)

    if event == "pull_request":
        pr = payload.get("pull_request") or {}
        action, number = payload.get("action"), pr.get("number")
        if action in PR_ACTIONS and not pr.get("draft"):
            sha = (pr.get("head") or {}).get("sha")
            if number and sha:
                items.append((str(number), sha, "webhook"))
        elif action == "closed" and pr.get("merged") and number:
            # A merge is its own kind of work — what landed, not what to do
            # next to an open PR — and it is the delivery that replaces
            # auto-reviewer's old "list what merged since the last pass"
            # query. The merge commit is the dedup key, so one item per PR.
            sha = pr.get("merge_commit_sha") or (pr.get("head") or {}).get("sha")
            if sha:
                items.append((str(number), sha, "merged"))
    elif event == "push":
        sha = payload.get("after")
        if sha and set(sha) != {"0"}:          # 000…0 is a branch deletion
            items = [(n, s, "webhook") for n, s in pulls_for_sha(repo, sha)]

    for number, sha, via in items:
        try:
            subprocess.run([*on_change, repo, number, sha, via], check=False, timeout=60)
        except Exception as exc:               # one bad delivery must not kill the receiver
            log(f"ERROR handing off {repo}#{number}: {exc}")


def make_handler(on_change: list[str]):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 (BaseHTTPRequestHandler's naming)
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            event = self.headers.get("X-GitHub-Event", "")
            # Ack first: the forwarder should never wait on our work.
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b"accepted")
            try:
                dispatch(event, json.loads(raw or b"{}"), on_change)
            except Exception as exc:
                log(f"ERROR handling {event!r} delivery: {exc}")

        def log_message(self, *args):          # silence per-request stderr noise
            pass

    return Handler


def main() -> int:
    argv = sys.argv[1:]
    port_file = None
    on_change: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--port-file" and i + 1 < len(argv):
            port_file = argv[i + 1]; i += 2
        elif argv[i] == "--on-change":
            on_change = argv[i + 1:]; break    # everything after is the command
        else:
            i += 1
    if not on_change:
        log("usage: webhook-receiver.py [--port-file F] --on-change CMD [ARGS...]")
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(on_change))
    port = server.server_address[1]
    if port_file:
        with open(port_file, "w") as fh:
            fh.write(str(port))
    log(f"listening on 127.0.0.1:{port} -> {' '.join(on_change)}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
