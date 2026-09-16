#!/usr/bin/env python3
"""run-workflows.py — execute a repo's GitHub Actions workflows on the local machine.

Reads .github/workflows/*.yml, selects workflows triggered by the given event
(default: pull_request), and runs their jobs' steps the way the GitHub runner
would: same step order, same env layering (workflow -> job -> step), same
working-directory defaults, same if:/continue-on-error semantics.

Fidelity notes (each is logged when it happens):
  - `uses:` steps for checkout/setup-*/cache/artifacts are no-ops — the repo is
    already checked out and the host toolchain is used. Other actions are
    skipped with a warning.
  - `${{ secrets.X }}` resolves to the host env var X, else empty string
    (matching how fork PRs see no secrets).
  - strategy.matrix runs the first combination only.
  - jobs needing `container:`/`services:` or a Windows runner are skipped.

Exit codes: 0 all jobs passed; 1 a job failed; 42 no workflow matches the event
(caller should fall back to stack heuristics).
"""
import argparse, fnmatch, glob, hashlib, os, re, subprocess, sys, tempfile, time

try:
    import yaml
except ImportError:
    print("run-workflows.py: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

NOOP_ACTIONS = ("actions/checkout", "actions/cache", "actions/upload-artifact",
                "actions/download-artifact", "actions/setup-node", "actions/setup-python",
                "actions/setup-go", "actions/setup-java", "oven-sh/setup-bun",
                "pnpm/action-setup", "codecov/codecov-action")
EXPR_RE = re.compile(r"\$\{\{\s*(.*?)\s*\}\}", re.S)


def log(msg):
    print(f"[workflows] {msg}", flush=True)


def load_workflows(repo, event):
    """Yield (path, parsed) for workflows triggered by `event`."""
    for path in sorted(glob.glob(os.path.join(repo, ".github/workflows/*.y*ml"))):
        try:
            wf = yaml.safe_load(open(path))
        except yaml.YAMLError as e:
            log(f"WARN: cannot parse {path}: {e}")
            continue
        if not isinstance(wf, dict):
            continue
        on = wf.get("on", wf.get(True))  # YAML 1.1 parses the key `on` as True
        triggers = [on] if isinstance(on, str) else (list(on) if isinstance(on, (list, dict)) else [])
        if event in triggers:
            yield path, wf


class Ctx:
    """Expression contexts for one job run."""

    def __init__(self, repo, event, env):
        head_sha = git(repo, "rev-parse", "HEAD")
        branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        remote = git(repo, "remote", "get-url", "origin")
        m = re.search(r"[:/]([^/:]+/[^/]+?)(\.git)?$", remote or "")
        self.github = {"sha": head_sha, "ref": f"refs/heads/{branch}", "ref_name": branch,
                       "repository": m.group(1) if m else "", "event_name": event,
                       "run_id": str(int(time.time())), "workspace": repo,
                       "actor": os.environ.get("USER", ""), "event": {}}
        self.runner = {"os": {"darwin": "macOS", "linux": "Linux"}.get(sys.platform[:6].rstrip("0123456789"), "macOS"),
                       "arch": "ARM64" if os.uname().machine == "arm64" else "X64",
                       "temp": tempfile.mkdtemp(prefix="runner-temp.")}
        self.env = env          # mutable: $GITHUB_ENV writes land here
        self.matrix = {}
        self.steps = {}         # id -> {"outcome": ..., "outputs": {...}}
        self.job_failed = False
        self.repo = repo

    def lookup(self, dotted):
        parts = dotted.split(".")
        root = {"github": self.github, "runner": self.runner, "env": self.env,
                "matrix": self.matrix, "steps": self.steps}.get(parts[0])
        if parts[0] == "secrets":
            return os.environ.get(parts[1], "") if len(parts) > 1 else ""
        cur = root
        for p in parts[1:]:
            if isinstance(cur, dict) and p in cur:
                cur = cur[p]
            else:
                return None
        return cur

    def eval(self, expr):
        """Evaluate one ${{ }} expression body. Handles the constructs seen in
        real workflows: literals, dotted lookups, ==/!=, ||/&&, a few functions."""
        expr = expr.strip()
        for op in ("||", "&&"):
            depth, inq = 0, False
            for i in range(len(expr)):
                c = expr[i]
                if c == "'":
                    inq = not inq
                elif not inq and c == "(":
                    depth += 1
                elif not inq and c == ")":
                    depth -= 1
                elif not inq and depth == 0 and expr[i:i + 2] == op:
                    lhs, rhs = self.eval(expr[:i]), lambda: self.eval(expr[i + 2:])
                    return (lhs or rhs()) if op == "||" else (lhs and rhs())
        for op in ("==", "!="):
            if op in expr:
                l, r = (self.eval(s) for s in expr.split(op, 1))
                return (l == r) if op == "==" else (l != r)
        if expr.startswith("'") and expr.endswith("'"):
            return expr[1:-1]
        if expr in ("true", "false"):
            return expr == "true"
        if re.fullmatch(r"-?\d+", expr):
            return int(expr)
        if expr == "always()":
            return True
        if expr == "failure()":
            return self.job_failed
        if expr in ("success()", "!failure()"):
            return not self.job_failed
        if expr == "cancelled()":
            return False
        m = re.fullmatch(r"hashFiles\((.*)\)", expr)
        if m:
            h = hashlib.sha256()
            for pat in re.findall(r"'([^']*)'", m.group(1)):
                for f in sorted(glob.glob(os.path.join(self.repo, pat), recursive=True)):
                    if os.path.isfile(f):
                        h.update(open(f, "rb").read())
            return h.hexdigest()
        if re.fullmatch(r"[\w.-]+", expr):
            v = self.lookup(expr)
            if v is None:
                log(f"WARN: unresolved expression '{expr}' -> ''")
                return ""
            return v
        log(f"WARN: unsupported expression '{expr}' -> ''")
        return ""

    def interpolate(self, text):
        if not isinstance(text, str):
            return text
        return EXPR_RE.sub(lambda m: str(self.eval(m.group(1))), text)

    def step_should_run(self, cond):
        """GitHub semantics: after a failure, only failure()/always() steps run."""
        if self.job_failed:
            return bool(cond) and ("failure()" in cond or "always()" in cond) and bool(self.eval(cond.strip()))
        if not cond:
            return True
        return bool(self.eval(str(cond).strip()))


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout.strip()


def read_kv_file(path):
    """Parse a $GITHUB_ENV/$GITHUB_OUTPUT file (KEY=VALUE and KEY<<EOF blocks)."""
    out, lines = {}, open(path).read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"([^=<\s]+)<<(\S+)$", lines[i])
        if m:
            key, eof, buf = m.group(1), m.group(2), []
            i += 1
            while i < len(lines) and lines[i] != eof:
                buf.append(lines[i]); i += 1
            out[key] = "\n".join(buf)
        elif "=" in lines[i]:
            k, v = lines[i].split("=", 1)
            out[k] = v
        i += 1
    return out


def run_step(ctx, step, job_defaults, job_env, base_dir, timeout_min):
    """Run one step. Returns outcome: 'success' | 'failure' | 'skipped' | 'noop'."""
    name = step.get("name") or step.get("uses") or (step.get("run", "")[:60].strip())
    cond = step.get("if")
    if not ctx.step_should_run(str(cond) if cond is not None else ""):
        why = f"if: {cond}" if cond is not None else "an earlier step failed"
        log(f"  - SKIP ({why}): {name}")
        return "skipped"

    if "uses" in step:
        uses = step["uses"]
        noop = uses.split("@")[0].rstrip("/").startswith(NOOP_ACTIONS)
        log(f"  - {'no-op' if noop else 'WARN: skipping unsupported action'}: {uses}")
        if step.get("id"):  # later steps may read steps.<id>.outcome
            ctx.steps[step["id"]] = {"outcome": "success" if noop else "skipped", "outputs": {}}
        return "success" if noop else "skipped"

    if "run" not in step:
        return "skipped"

    env = dict(os.environ)
    env.update({k: str(ctx.interpolate(v)) for k, v in job_env.items()})
    env.update({k: str(ctx.interpolate(v)) for k, v in (step.get("env") or {}).items()})
    tmp = {n: tempfile.mkstemp(prefix=f"gh-{n.lower()}.")[1]
           for n in ("GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_PATH", "GITHUB_STEP_SUMMARY")}
    env.update(tmp)
    env.update({"CI": "true", "NO_COLOR": "1", "GITHUB_ACTIONS": "true", "GITHUB_WORKSPACE": ctx.repo,
                "GITHUB_SHA": ctx.github["sha"], "GITHUB_REF": ctx.github["ref"],
                "GITHUB_REF_NAME": ctx.github["ref_name"], "GITHUB_REPOSITORY": ctx.github["repository"],
                "GITHUB_EVENT_NAME": ctx.github["event_name"], "RUNNER_TEMP": ctx.runner["temp"],
                "RUNNER_OS": ctx.runner["os"], "RUNNER_ARCH": ctx.runner["arch"]})

    wd = step.get("working-directory") or job_defaults.get("working-directory") or "."
    cwd = os.path.normpath(os.path.join(base_dir, ctx.interpolate(wd)))
    script = ctx.interpolate(step["run"])
    shell = step.get("shell") or job_defaults.get("shell") or "bash"
    cmd = {"bash": ["bash", "-e", "-c", script], "sh": ["sh", "-e", "-c", script],
           "python": [sys.executable, "-c", script]}.get(shell, ["bash", "-e", "-c", script])

    log(f"  - run: {name}  (dir: {os.path.relpath(cwd, base_dir)})")
    try:
        rc = subprocess.run(cmd, cwd=cwd, env=env, timeout=timeout_min * 60).returncode
    except subprocess.TimeoutExpired:
        log(f"    TIMEOUT after {timeout_min} minutes")
        rc = 124

    ctx.env.update(read_kv_file(tmp["GITHUB_ENV"]))
    job_env.update(read_kv_file(tmp["GITHUB_ENV"]))
    outputs = read_kv_file(tmp["GITHUB_OUTPUT"])
    summary = open(tmp["GITHUB_STEP_SUMMARY"]).read().strip()
    if summary:
        log(f"    step summary: {summary}")
    if step.get("id"):
        ctx.steps[step["id"]] = {"outcome": "success" if rc == 0 else "failure", "outputs": outputs}
    for f in tmp.values():
        os.unlink(f)
    return "success" if rc == 0 else "failure"


_docker_ok = None
def docker_available():
    global _docker_ok
    if _docker_ok is None:
        try:
            _docker_ok = subprocess.run(["docker", "info"], capture_output=True, timeout=20).returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            _docker_ok = False
    return _docker_ok


def run_job(repo, event, job_id, job, wf_env):
    runs_on = str(job.get("runs-on", ""))
    if "windows" in runs_on:
        log(f"SKIP job '{job_id}': needs a Windows runner")
        return "skipped"
    if job.get("container") or job.get("services"):
        log(f"SKIP job '{job_id}': needs container/services (Docker-backed runner)")
        return "skipped"
    # A job whose steps shell out to docker can never pass on a host without a
    # daemon — skipping (with this note) beats a permanently red status.
    if not docker_available() and any(re.search(r"\bdocker\b", str(s.get("run", "")))
                                      for s in job.get("steps") or []):
        log(f"SKIP job '{job_id}': steps invoke docker but Docker is not available on this host")
        return "skipped"

    job_env = dict(wf_env); job_env.update(job.get("env") or {})
    ctx = Ctx(repo, event, dict(job_env))
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    if matrix:
        ctx.matrix = {k: v[0] if isinstance(v, list) and v else v
                      for k, v in matrix.items() if k not in ("include", "exclude")}
        log(f"NOTE job '{job_id}': matrix reduced to first combination {ctx.matrix}")

    cond = job.get("if")
    if cond is not None and not bool(ctx.eval(str(cond).strip())):
        log(f"SKIP job '{job_id}' (if: {cond})")
        return "skipped"

    defaults = (job.get("defaults") or {}).get("run") or {}
    timeout_min = int(job.get("timeout-minutes") or 60)
    log(f"JOB '{job_id}' ({runs_on}, running on host)")
    for step in job.get("steps") or []:
        t = int(step.get("timeout-minutes") or timeout_min)
        outcome = run_step(ctx, step, defaults, dict(job_env), repo, t)
        if outcome == "failure":
            if str(step.get("continue-on-error", "")).lower() == "true":
                log("    step failed, continue-on-error: true")
            else:
                ctx.job_failed = True
    log(f"JOB '{job_id}' -> {'FAILURE' if ctx.job_failed else 'success'}")
    return "failure" if ctx.job_failed else "success"


def topo_jobs(jobs):
    done, order = set(), []
    pending = dict(jobs)
    while pending:
        progressed = False
        for jid, job in list(pending.items()):
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            if all(n in done for n in needs):
                order.append((jid, job)); done.add(jid); del pending[jid]; progressed = True
        if not progressed:  # cycle or dangling need — run remaining in file order
            order.extend(pending.items()); break
    return order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--event", default="pull_request")
    ap.add_argument("--plan", action="store_true", help="print jobs/steps without executing")
    args = ap.parse_args()
    repo = os.path.abspath(args.repo)

    matched = list(load_workflows(repo, args.event))
    if not matched:
        log(f"no workflows triggered by '{args.event}'")
        sys.exit(42)

    failed, job_results = False, {}
    for path, wf in matched:
        log(f"WORKFLOW {os.path.basename(path)} ('{wf.get('name', '?')}')")
        wf_env = wf.get("env") or {}
        for jid, job in topo_jobs(wf.get("jobs") or {}):
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            if any(job_results.get(n) == "failure" for n in needs):
                log(f"SKIP job '{jid}': needed job failed")
                job_results[jid] = "skipped"
                continue
            if args.plan:
                steps = [(s.get("name") or s.get("uses") or s.get("run", "")[:60].strip())
                         for s in job.get("steps") or []]
                log(f"JOB '{jid}' ({job.get('runs-on')}): " + " | ".join(steps))
                continue
            job_results[jid] = run_job(repo, args.event, jid, job, wf_env)
            failed = failed or job_results[jid] == "failure"
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
