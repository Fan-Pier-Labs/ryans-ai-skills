#!/usr/bin/env python3
"""Build the intra-repo import graph for Python and JS/TS and report cycles (the DAG check).

  scripts/import-graph.py [--repo .] [--out <dir>] [--exclude dir ...]

Writes <out>/import-graph.json: nodes, edges, strongly connected components with more than
one file (= import cycles), self-imports, fan-in/fan-out hubs. Prints a short summary.
Pure read; no code is executed. Type-only imports (`import type`, `if TYPE_CHECKING:`) are
ignored because they create no runtime dependency. Bare package specifiers are ignored.
Go and Rust are not analysed: their compilers already reject import cycles.
"""
import argparse, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _repo_files import list_files, is_test, read_text  # noqa: E402

JS_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".vue", ".svelte")
JS_IMPORT_RE = re.compile(
    r"""(?:^|[^\w$.])(?:import\s+(?!type\s)(?:[^'";]*?\s+from\s+)?|export\s+(?!type\s)[^'";]*?\s+from\s+)['"]([^'"\n]+)['"]"""
    r"""|require\(\s*['"]([^'"\n]+)['"]\s*\)|import\(\s*['"]([^'"\n]+)['"]\s*\)""", re.M)
PY_IMPORT_RE = re.compile(r"^\s*(?:from\s+([.\w]+)\s+import\s+([^\n#]+)|import\s+([^\n#]+))", re.M)


def strip_json_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"^\s*//.*$", "", s, flags=re.M)
    s = re.sub(r",(\s*[}\]])", r"\1", s)
    return s


def load_ts_aliases(root, files):
    """Return list of (prefix, [targets]) from tsconfig/jsconfig `paths`, plus the `@/`→src default."""
    aliases = []
    for cfg in [f for f in files if os.path.basename(f) in ("tsconfig.json", "jsconfig.json", "tsconfig.base.json")]:
        txt = read_text(root, cfg) or ""
        try:
            data = json.loads(strip_json_comments(txt))
        except Exception:
            continue
        co = data.get("compilerOptions", {}) or {}
        base = os.path.normpath(os.path.join(os.path.dirname(cfg), co.get("baseUrl", ".")))
        for pat, targets in (co.get("paths") or {}).items():
            aliases.append((pat.rstrip("*"), [os.path.normpath(os.path.join(base, t.rstrip("*"))) for t in targets]))
    for src in ("src", "app", "lib"):
        if os.path.isdir(os.path.join(root, src)):
            aliases.append(("@/", [src])); aliases.append(("~/", [src]))
            break
    return aliases


class Graph:
    def __init__(self):
        self.edges = {}  # file -> set(file)

    def add(self, a, b):
        self.edges.setdefault(a, set()); self.edges.setdefault(b, set())
        if a != b:
            self.edges[a].add(b)
        else:
            self.edges[a].add(a)

    def sccs(self):
        index = {}; low = {}; on = set(); stack = []; out = []; counter = [0]
        nodes = list(self.edges)
        for start in nodes:
            if start in index:
                continue
            work = [(start, iter(self.edges[start]))]
            index[start] = low[start] = counter[0]; counter[0] += 1; stack.append(start); on.add(start)
            while work:
                v, it = work[-1]
                advanced = False
                for w in it:
                    if w not in index:
                        index[w] = low[w] = counter[0]; counter[0] += 1; stack.append(w); on.add(w)
                        work.append((w, iter(self.edges[w]))); advanced = True; break
                    elif w in on:
                        low[v] = min(low[v], index[w])
                if advanced:
                    continue
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[v])
                if low[v] == index[v]:
                    comp = []
                    while True:
                        w = stack.pop(); on.discard(w); comp.append(w)
                        if w == v:
                            break
                    out.append(comp)
        return out


def resolve_js(root, files_set, from_file, spec, aliases):
    cands = []
    if spec.startswith("."):
        cands.append(os.path.normpath(os.path.join(os.path.dirname(from_file), spec)))
    else:
        for prefix, targets in aliases:
            if spec.startswith(prefix):
                rest = spec[len(prefix):]
                cands += [os.path.normpath(os.path.join(t, rest)) for t in targets]
        if not cands:
            return None
    for c in cands:
        c = c.replace(os.sep, "/")
        tries = [c] + [c + e for e in JS_EXT] + [c + "/index" + e for e in JS_EXT]
        stem, ext = os.path.splitext(c)
        if ext in (".js", ".jsx", ".mjs", ".cjs"):  # ESM-in-TS convention: import './x.js' → x.ts
            tries += [stem + e for e in (".ts", ".tsx", ".mts", ".cts")]
        for t in tries:
            if t in files_set:
                return t
    return None


def py_index(py_files):
    idx = {}
    for f in py_files:
        stem = f[:-3] if f.endswith(".py") else f[:-4]
        parts = stem.split("/")
        if parts[-1] == "__init__":
            parts = parts[:-1]
        for i in range(len(parts)):
            idx.setdefault(".".join(parts[i:]), []).append(f)
    return idx


def resolve_py(root, files_set, idx, from_file, module, level, names):
    if level:
        base = os.path.dirname(from_file)
        for _ in range(level - 1):
            base = os.path.dirname(base)
        targets = []
        modpath = os.path.join(base, *module.split(".")) if module else base
        if module:
            targets.append(modpath)
        for n in names:
            targets.append(os.path.join(modpath, n))
        if not module:
            targets.append(base)
        out = []
        for t in targets:
            t = t.replace(os.sep, "/")
            for cand in (t + ".py", t + "/__init__.py"):
                if cand in files_set:
                    out.append(cand); break
        return out
    out = []
    keys = [module] + [module + "." + n for n in names]
    for k in keys:
        hits = idx.get(k)
        if not hits:
            continue
        best = max(hits, key=lambda h: len(os.path.commonprefix([h, from_file])))
        out.append(best)
    return out


def parse_py_imports(text):
    """Yield (module, level, names) skipping `if TYPE_CHECKING:` blocks."""
    lines = text.split("\n"); i = 0; skip_indent = None
    while i < len(lines):
        line = lines[i]
        if skip_indent is not None:
            if line.strip() and (len(line) - len(line.lstrip())) <= skip_indent:
                skip_indent = None
            else:
                i += 1; continue
        if re.match(r"\s*if\s+(typing\.)?TYPE_CHECKING\s*:", line):
            skip_indent = len(line) - len(line.lstrip()); i += 1; continue
        m = re.match(r"^\s*from\s+([.\w]+)\s+import\s+(.*)$", line)
        if m:
            mod = m.group(1); rest = m.group(2)
            if rest.strip().startswith("("):
                buf = rest
                while ")" not in buf and i + 1 < len(lines):
                    i += 1; buf += " " + lines[i]
                rest = buf
            level = len(mod) - len(mod.lstrip("."))
            names = [n.strip().split(" as ")[0].strip() for n in rest.strip("() \\").split(",") if n.strip() and n.strip() != "*"]
            yield mod.lstrip("."), level, names
        else:
            m = re.match(r"^\s*import\s+([\w., ]+)$", line)
            if m:
                for mod in m.group(1).split(","):
                    yield mod.strip().split(" as ")[0].strip(), 0, []
        i += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="."); ap.add_argument("--out", default=None)
    ap.add_argument("--exclude", nargs="*", default=[]); ap.add_argument("--include-tests", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.repo)
    files = list_files(root, a.exclude)
    files_set = set(files)
    src = [f for f in files if (a.include_tests or not is_test(f))]
    js = [f for f in src if f.endswith(JS_EXT)]
    py = [f for f in src if f.endswith((".py", ".pyi"))]
    g = Graph(); unresolved = 0
    aliases = load_ts_aliases(root, files)
    for f in js:
        t = read_text(root, f)
        if t is None:
            continue
        g.edges.setdefault(f, set())
        for m in JS_IMPORT_RE.finditer(t):
            spec = next(x for x in m.groups() if x)
            spec = spec.split("?")[0]
            r = resolve_js(root, files_set, f, spec, aliases)
            if r:
                g.add(f, r)
            elif spec.startswith("."):
                unresolved += 1
    idx = py_index(py)
    for f in py:
        t = read_text(root, f)
        if t is None:
            continue
        g.edges.setdefault(f, set())
        for mod, level, names in parse_py_imports(t):
            for r in resolve_py(root, files_set, idx, f, mod, level, names):
                g.add(f, r)
    comps = g.sccs()
    cycles = sorted([sorted(c) for c in comps if len(c) > 1], key=len, reverse=True)
    self_loops = sorted(n for n, e in g.edges.items() if n in e)
    fan_in = {n: 0 for n in g.edges}
    for n, e in g.edges.items():
        for d in e:
            fan_in[d] = fan_in.get(d, 0) + 1
    fan_out = {n: len(e) for n, e in g.edges.items()}
    nodes = len(g.edges); edges = sum(len(e) for e in g.edges.values())
    in_cycles = sum(len(c) for c in cycles)
    result = {
        "languages": {"javascript_typescript_files": len(js), "python_files": len(py)},
        "nodes": nodes, "edges": edges, "unresolved_relative_imports": unresolved,
        "acyclic": not cycles and not self_loops,
        "cycle_count": len(cycles), "files_in_cycles": in_cycles,
        "largest_cycle": len(cycles[0]) if cycles else 0,
        "cycles": cycles[:50], "self_imports": self_loops,
        "top_fan_in": sorted(fan_in.items(), key=lambda kv: -kv[1])[:15],
        "top_fan_out": sorted(fan_out.items(), key=lambda kv: -kv[1])[:15],
        "high_fan_out_files": sorted([n for n, c in fan_out.items() if c >= 20]),
    }
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "import-graph.json"), "w") as fh:
            json.dump(result, fh, indent=1)
    print(f"import graph: {nodes} files, {edges} edges ({len(js)} js/ts, {len(py)} py; {unresolved} unresolved relative imports)")
    if result["acyclic"]:
        print("acyclic: YES — no import cycles")
    else:
        print(f"acyclic: NO — {len(cycles)} cycle group(s) covering {in_cycles} files; largest {result['largest_cycle']}; self-imports {len(self_loops)}")
        for c in cycles[:10]:
            print("  - " + " <-> ".join(c[:6]) + (f" (+{len(c)-6} more)" if len(c) > 6 else ""))


if __name__ == "__main__":
    main()
