#!/usr/bin/env python3
"""Find dead code deterministically in Python and TypeScript/JavaScript: files nothing imports,
and definitions nothing references.

  scripts/dead-code.py [--repo .] [--out <dir>] [--include-tests] [--fail-on none|high|medium]

Writes <out>/dead-code.json and prints a summary. Pure read; nothing is executed, nothing is
deleted. Python is parsed with `ast`, so its answers are exact about what the file declares;
JS/TS is parsed with the same regex-and-resolve pass `import-graph.py` uses, which this script
imports rather than copies.

Three findings, in decreasing confidence:

  1. UNREACHABLE FILES  — not reachable from any entry point through the import graph. Entry
     points are listed in the output, so an over-broad or over-narrow assumption is visible.
  2. UNREFERENCED DEFINITIONS — a name in a reachable file that appears nowhere else, in any
     file, in any form (identifier, attribute, string).
  3. EXPORTED BUT NEVER IMPORTED — public API surface with no consumer. Not dead, but the
     `export` / `__all__` entry is: narrowing it is what makes the next pass able to see more.

Everything ruled out is reported WITH ITS REASON (`excluded`), because the reason is the part a
reviewer has to check: a decorator, `__all__`, a name appearing in a template or a config
string, a namespace import, a framework-conventional path. This script never deletes and never
says "dead" on its own — a framework can call anything by convention, and callers outside this
repo are invisible from inside it.

Other languages are NOT guessed at. They are reported as unanalysed with the tool that does
answer for them, and the judgment is handed back to the reviewer.
"""
import argparse, ast, importlib.util, json, os, re, sys, warnings

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from _repo_files import list_files, is_source, is_test, read_text, language_of  # noqa: E402


def _load_import_graph():
    """import-graph.py has a hyphen in its name, so it cannot be imported as a module. Load it by
    path: its JS resolution (tsconfig `paths`, index files, the .js→.ts convention) and its
    Python module index are exactly what this script needs, and a second copy would drift."""
    spec = importlib.util.spec_from_file_location("_import_graph", os.path.join(HERE, "import-graph.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


IG = _load_import_graph()
JS_EXT = IG.JS_EXT

# --- what counts as a way in -----------------------------------------------------------------
# A file reachable only from one of these is alive. The list is deliberately generous: a false
# entry point hides dead code (a miss), a missing one invents dead code (a wrong answer), and the
# second is much more expensive to a reader.
PY_ENTRY_NAMES = {"__main__.py", "manage.py", "conftest.py", "settings.py", "urls.py", "wsgi.py",
                  "asgi.py", "setup.py", "app.py", "main.py", "celery.py", "celeryconfig.py",
                  "gunicorn.conf.py", "noxfile.py", "tasks.py", "fabfile.py",
                  # Django and friends import these by convention, so no file in the repo does.
                  # Naming them here costs a miss; leaving them out invents a finding per app.
                  "admin.py", "apps.py", "signals.py", "receivers.py", "routing.py", "checks.py",
                  "middleware.py", "middlewares.py", "context_processors.py", "admin_site.py"}
PY_ENTRY_DIR_RE = re.compile(r"(^|/)(migrations|alembic|scripts?|bin|cmd|management/commands|templatetags)/")
JS_ENTRY_BASENAMES = {"next.config.js", "next.config.mjs", "next.config.ts", "vite.config.ts",
                      "vite.config.js", "svelte.config.js", "nuxt.config.ts", "tailwind.config.ts",
                      "tailwind.config.js", "jest.config.ts", "jest.config.js", "vitest.config.ts",
                      "playwright.config.ts", "webpack.config.js", "rollup.config.js",
                      "astro.config.mjs", "remix.config.js", "gatsby-node.js", "gatsby-config.js",
                      "metro.config.js", "babel.config.js", "middleware.ts", "middleware.js",
                      "instrumentation.ts", "service-worker.js", "sw.js"}
# Framework file-based routing: the framework imports these, so no file in the repo does.
JS_CONVENTION_RE = re.compile(
    r"(^|/)pages/|(^|/)app/.*/(page|layout|route|template|loading|error|not-found|default|"
    r"global-error|opengraph-image|icon|apple-icon|sitemap|robots|manifest)\.[jt]sx?$|"
    r"(^|/)app/(page|layout|route|template|loading|error|not-found)\.[jt]sx?$|"
    r"(^|/)routes/|(^|/)api/|\+(page|layout|server|error)[.@]|"
    r"\.stories\.[jt]sx?$|\.d\.ts$|(^|/)functions/|(^|/)netlify/|(^|/)supabase/functions/|"
    r"(^|/)pipes/|(^|/)workers?/|(^|/)cypress/|(^|/)e2e/|"
    r"(^|/)(lambdas?|serverless|cloud-?functions?|edge-functions?)/")
# A standalone script is run by hand or by CI (`bun dev-scripts/x.ts`), so nothing imports it.
CONFIG_LIKE_RE = re.compile(r"\.config\.[mc]?[jt]sx?$|rc\.[mc]?[jt]s$|\.setup\.[jt]sx?$|"
                            r"(^|/)[\w.-]*scripts?/|(^|/)(bin|tools?|dev|devtools|cli|examples?|demos?)/")
# Files whose content is data or text, but which can still name a symbol (a template calling a
# helper, a YAML naming a handler path, a Django settings string). A hit here is not proof the
# symbol is alive, but it IS proof the question is not mechanical, which is enough to exclude it.
TEXTUAL_EXT = (".html", ".htm", ".jinja", ".jinja2", ".j2", ".erb", ".hbs", ".mustache", ".ejs",
               ".liquid", ".twig", ".pug", ".vue", ".svelte", ".yml", ".yaml", ".json", ".toml",
               ".ini", ".cfg", ".env", ".md", ".mdx", ".txt", ".sql", ".tf", ".sh", ".graphql",
               ".proto", ".xml", ".plist", ".gradle", ".csv")
NODE_BUILTINS = {"fs", "path", "os", "url", "util", "http", "https", "net", "crypto", "stream",
                 "events", "child_process", "zlib", "buffer", "assert", "tty", "readline", "vm",
                 "worker_threads", "perf_hooks", "querystring", "timers", "dns", "cluster", "tls",
                 "module", "process", "string_decoder", "constants", "punycode", "v8", "inspector"}
IDENT_RE = re.compile(r"[A-Za-z_$][\w$]*")
DEFAULT_MIN_NAME = 3
# Names too generic for a repo-wide identifier search to mean anything.
COMMON_NAMES = {"main", "run", "get", "set", "add", "new", "init", "setup", "index", "default",
                "handler", "handle", "props", "state", "types", "data", "value", "item", "name",
                "key", "id", "type", "config", "options", "result", "error", "test", "app",
                "self", "cls", "args", "kwargs", "start", "stop", "close", "open", "read",
                "write", "load", "save", "parse", "format", "render", "update", "delete",
                "create", "list", "next", "call", "send", "post", "put", "patch"}


def norm(p):
    return p.replace(os.sep, "/")


def local_uses(text, name, sep="$"):
    r"""How many times this file mentions `name` as a value, not as someone's property.

    A plain `(?<![\w.])` lookbehind gets spread syntax wrong: in `{...EMPTY_PLAN}` the character
    before the name is a dot, so the only use of a constant inside its own module vanishes and a
    live value is reported as referenced nowhere. A member access is ONE dot; three is a spread."""
    rx = re.compile(r"(?<![\w" + re.escape(sep) + r"])" + re.escape(name) + r"(?![\w" + re.escape(sep) + r"])")
    n = 0
    for m in rx.finditer(text):
        i = m.start()
        if i and text[i - 1] == "." and not text[max(0, i - 3):i] == "...":
            continue          # a property access on something else
        n += 1
    return n


# --- Python ----------------------------------------------------------------------------------

def _parse(text, filename="<repo>"):
    """`ast.parse` re-emits the target repo's own SyntaxWarnings (an invalid escape in a regex
    literal, say) on our stderr, where they read as this script breaking. Their code is not our
    report."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return ast.parse(text, filename=filename)


def py_symbols(rel, text):
    """Every module-level def/class/assignment in one file, plus its decorators and __all__.

    Parsed rather than grepped: a decorator is the single strongest signal that something is
    called by a framework and not by any caller this script could ever find, and only a parse
    tells the decorators apart from the code around them."""
    try:
        tree = _parse(text, rel)
    except SyntaxError as e:
        return None, f"SyntaxError line {e.lineno}"
    out, dunder_all = [], set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            decs = []
            for d in node.decorator_list:
                try:
                    decs.append(ast.unparse(d))
                except Exception:
                    decs.append("<decorator>")
            out.append({"name": node.name, "line": node.lineno,
                        "kind": "class" if isinstance(node, ast.ClassDef) else "function",
                        "decorators": decs, "private": node.name.startswith("_")})
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for t in targets:
                if isinstance(t, ast.Name):
                    if t.id == "__all__":
                        v = node.value
                        if isinstance(v, (ast.List, ast.Tuple, ast.Set)):
                            dunder_all |= {e.value for e in v.elts
                                           if isinstance(e, ast.Constant) and isinstance(e.value, str)}
                    elif t.id.isupper() and len(t.id) >= DEFAULT_MIN_NAME:
                        out.append({"name": t.id, "line": node.lineno, "kind": "constant",
                                    "decorators": [], "private": t.id.startswith("_")})
    return {"symbols": out, "all": sorted(dunder_all)}, None


def py_uses(text):
    """Names this file mentions in any form: identifier, attribute, imported name, string.

    Strings count. `getattr(mod, "handler")`, a Django `ROOT_URLCONF`, a Celery task path and a
    router registry all reference code by name and nothing else, so a symbol whose name appears
    as a string is not one this script is willing to call dead."""
    try:
        tree = _parse(text)
    except SyntaxError:
        return set(IDENT_RE.findall(text)), set()
    names, strings = set(), set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Name):
            names.add(n.id)
        elif isinstance(n, ast.Attribute):
            names.add(n.attr)
        elif isinstance(n, ast.ImportFrom):
            for a in n.names:
                names.add(a.name)
                if a.asname:
                    names.add(a.asname)
        elif isinstance(n, ast.Import):
            for a in n.names:
                names.update(a.name.split("."))
                if a.asname:
                    names.add(a.asname)
        elif isinstance(n, ast.Constant) and isinstance(n.value, str):
            if len(n.value) < 400:
                strings.update(IDENT_RE.findall(n.value))
                strings.add(n.value)      # kept whole too: `config.base_settings` is a module
                                          # path, and splitting it loses the thing that matters
    return names, strings


# --- TypeScript / JavaScript -----------------------------------------------------------------
JS_EXPORT_DECL_RE = re.compile(
    r"^\s*export\s+(?:declare\s+)?(?:default\s+)?(?:async\s+)?"
    r"(?:function\s*\*?|class|const|let|var|enum|interface|type|abstract\s+class)\s+([A-Za-z_$][\w$]*)", re.M)
JS_EXPORT_LIST_RE = re.compile(r"^\s*export\s*(?:type\s*)?\{([^}]*)\}(?!\s*from)", re.M)
JS_REEXPORT_RE = re.compile(r"^\s*export\s*(?:type\s*)?(?:\{([^}]*)\}|\*(?:\s+as\s+[A-Za-z_$][\w$]*)?)\s*from\s*['\"]([^'\"]+)['\"]", re.M)
JS_NAMED_IMPORT_RE = re.compile(r"import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*['\"]([^'\"]+)['\"]")
JS_NAMESPACE_IMPORT_RE = re.compile(r"import\s*(?:type\s*)?\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*['\"]([^'\"]+)['\"]")
JS_DEFAULT_IMPORT_RE = re.compile(r"import\s+(?:type\s+)?([A-Za-z_$][\w$]*)\s*(?:,|from)")


def js_exports(text):
    """Exported names in one file. `export default` is recorded as `default`, which is only ever
    imported positionally, so it is never reported as an unreferenced name."""
    names = []
    for m in JS_EXPORT_DECL_RE.finditer(text):
        names.append((m.group(1), text.count("\n", 0, m.start()) + 1))
    for m in JS_EXPORT_LIST_RE.finditer(text):
        for part in m.group(1).split(","):
            part = part.strip()
            if not part:
                continue
            local, _, exported = part.partition(" as ")
            nm = re.sub(r"^(?:type|typeof)\s+", "", (exported or local).strip())
            if re.fullmatch(r"[A-Za-z_$][\w$]*", nm) and nm != "default":
                names.append((nm, text.count("\n", 0, m.start()) + 1))
    return names


# --- the pass --------------------------------------------------------------------------------

def make_js_resolver(root, files, files_set, text, aliases):
    """`IG.resolve_js` handles relative paths and tsconfig `paths`. Two more shapes decide whether
    a frontend's graph resolves at all, and both are invisible in tsconfig: a bundler's
    `resolve.modules` root, which is what makes `from 'src/components/Thing'` work, and a
    workspace package name in a monorepo. Unresolved imports do not fail loudly — they silently
    turn the whole application into "unreachable", which is why this is worth getting right."""
    pkg_jsons = [f for f in files if os.path.basename(f) == "package.json"]
    pkg_dirs = sorted({os.path.dirname(f) for f in pkg_jsons}, key=lambda d: -len(d))
    workspace = {}
    for pj in pkg_jsons:
        try:
            data = json.loads(text.get(pj, "") or "{}")
        except Exception:
            continue
        nm = data.get("name")
        if isinstance(nm, str) and nm:
            workspace[nm] = os.path.dirname(pj)

    def try_path(p):
        p = norm(os.path.normpath(p))
        for t in [p] + [p + e for e in JS_EXT] + [p + "/index" + e for e in JS_EXT] + \
                 [p + "/src/index" + e for e in JS_EXT]:
            if t in files_set:
                return t
        return None

    def resolve(from_file, spec):
        r = IG.resolve_js(root, files_set, from_file, spec, aliases)
        if r or spec.startswith("."):
            return r
        for nm in sorted(workspace, key=len, reverse=True):     # longest name first: @a/b before @a
            if spec == nm or spec.startswith(nm + "/"):
                rest = spec[len(nm):].lstrip("/")
                hit = try_path(os.path.join(workspace[nm], rest)) if rest else try_path(workspace[nm])
                if hit:
                    return hit
        # bundler module roots, nearest package directory first
        here = os.path.dirname(from_file)
        bases = [d for d in pkg_dirs if here == d or here.startswith(d + "/")] + pkg_dirs + [""]
        for b in bases:
            hit = try_path(os.path.join(b, spec))
            if hit:
                return hit
        return None

    return resolve


def build(root, files, include_tests):
    files_set = set(files)
    src_all = [f for f in files if f.endswith(JS_EXT) or f.endswith((".py", ".pyi"))]
    src = [f for f in src_all if include_tests or not is_test(f)]
    js = [f for f in src if f.endswith(JS_EXT)]
    py = [f for f in src if f.endswith((".py", ".pyi"))]
    text = {f: (read_text(root, f) or "") for f in files}

    aliases = IG.load_ts_aliases(root, files)
    resolve_js = make_js_resolver(root, files, files_set, text, aliases)
    idx = IG.py_index([f for f in files if f.endswith((".py", ".pyi"))])

    # edges: importer -> imported, over ALL files including tests, so "imported only by its own
    # test" stays visible instead of being mistaken for unimported.
    imports = {f: set() for f in src_all}
    test_only_importers = {f: set() for f in src_all}
    namespace_imported = set()       # modules pulled in wholesale: every export of them is "used"
    named_imports = {}               # name -> set(files importing it)
    unresolved, unresolved_bare = 0, set()
    deps_names = set()
    for pj in [f for f in files if os.path.basename(f) == "package.json"]:
        try:
            d = json.loads(text.get(pj, "") or "{}")
        except Exception:
            continue
        for k in ("dependencies", "devDependencies", "peerDependencies"):
            deps_names |= set((d.get(k) or {}).keys())
    for f in [x for x in files if x.endswith(JS_EXT)]:
        t = text[f]
        for m in IG.JS_IMPORT_RE.finditer(t):
            spec = next(x for x in m.groups() if x).split("?")[0]
            r = resolve_js(f, spec)
            if r:
                imports.setdefault(f, set()).add(r)
                if is_test(f):
                    test_only_importers.setdefault(r, set()).add(f)
            elif spec.startswith("."):
                unresolved += 1
            elif (spec.split("/")[0] not in deps_names and not spec.startswith(("@", "node:", "bun:", "deno:"))
                  and spec.split("/")[0] not in NODE_BUILTINS):
                # a bare specifier that is not a dependency is a repo-internal path this pass
                # failed to resolve, and every file behind it reads as unreachable
                unresolved_bare.add(spec)
        for m in JS_NAMED_IMPORT_RE.finditer(t):
            for part in m.group(1).split(","):
                nm = re.sub(r"^(?:type|typeof)\s+", "", part.strip()).split(" as ")[0].strip()
                if nm:
                    named_imports.setdefault(nm, set()).add(f)
        for m in JS_NAMESPACE_IMPORT_RE.finditer(t):
            r = resolve_js(f, m.group(2))
            if r:
                namespace_imported.add(r)
        for m in JS_REEXPORT_RE.finditer(t):
            r = resolve_js(f, m.group(2))
            if r:
                imports.setdefault(f, set()).add(r)
                if not m.group(1):        # `export * from './x'` re-exports everything in x
                    namespace_imported.add(r)
    PY_STAR_RE = re.compile(r"^\s*from\s+([.\w]+)\s+import\s+\*", re.M)
    for f in [x for x in files if x.endswith((".py", ".pyi"))]:
        t = text[f]
        # `from x import *` is Python's `import * as`: every name in the target is re-exported,
        # so nothing in it can be called unreferenced. This is how a Django settings module gets
        # its constants read, and without it every one of them reads as dead.
        for m in PY_STAR_RE.finditer(t):
            mod = m.group(1)
            for r in IG.resolve_py(root, files_set, idx, f, mod.lstrip("."), len(mod) - len(mod.lstrip(".")), []):
                imports.setdefault(f, set()).add(r)
                namespace_imported.add(r)
        for mod, level, names in IG.parse_py_imports(t):
            for r in IG.resolve_py(root, files_set, idx, f, mod, level, names):
                imports.setdefault(f, set()).add(r)
                if is_test(f):
                    test_only_importers.setdefault(r, set()).add(f)
            for nm in names:
                named_imports.setdefault(nm, set()).add(f)

    file_routed = bool(deps_names & {"next", "expo-router", "@remix-run/react", "@remix-run/node",
                                     "@sveltejs/kit", "nuxt", "astro", "@tanstack/react-router",
                                     "waku", "solid-start", "@analogjs/router"})
    return dict(files_set=files_set, src=src, src_all=src_all, js=js, py=py, text=text,
                file_routed=file_routed, deps_names=deps_names,
                imports=imports, named_imports=named_imports, namespace_imported=namespace_imported,
                test_only_importers=test_only_importers, unresolved=unresolved,
                unresolved_bare=sorted(unresolved_bare))


def entry_points(root, files, ctx, include_tests, extra=()):
    """Every file the outside world can start from, with the reason recorded. Printed in full in
    the output: an entry-point list a reader cannot see is an answer they cannot check."""
    eps = {}

    def mark(f, why):
        if f in ctx["files_set"]:
            eps.setdefault(f, why)

    for f in extra:
        mark(norm(f), "named on the command line with --entry")
    for f in ctx["src_all"]:
        b = os.path.basename(f)
        if is_test(f):
            if not include_tests:
                mark(f, "test file")
            continue
        if f.endswith((".py", ".pyi")):
            if b in PY_ENTRY_NAMES:
                mark(f, f"python entry-point convention ({b})")
            elif PY_ENTRY_DIR_RE.search("/" + f):
                mark(f, f"lives under {PY_ENTRY_DIR_RE.search('/' + f).group(2)}/ — run or loaded, not imported")
            elif re.search(r"^\s*if\s+__name__\s*==\s*['\"]__main__['\"]", ctx["text"][f], re.M):
                mark(f, "has `if __name__ == \"__main__\"`")
            elif ctx["text"][f].startswith("#!"):
                mark(f, "has a shebang — run directly, not imported")
            elif b == "__init__.py":
                mark(f, "package __init__ (re-exports its package's API)")
        else:
            if b in JS_ENTRY_BASENAMES or JS_CONVENTION_RE.search("/" + f) or CONFIG_LIKE_RE.search(f):
                mark(f, "framework/config convention for this path")
            elif ctx["text"].get(f, "").startswith("#!"):
                mark(f, "has a shebang — run directly, not imported")
            elif ctx["file_routed"] and re.search(r"(^|/)app/", f):
                # Next's and Expo Router's `app/` is file-based routing: every file under it is
                # loaded by the framework. Gated on the framework actually being a dependency,
                # because Angular's `src/app/` is an ordinary folder and this would hide its code.
                mark(f, "file-based routing (`app/`) with a router framework in dependencies")

    # package.json: main / module / exports / bin / types, and anything a script runs by path
    for pj in [f for f in files if os.path.basename(f) == "package.json"]:
        d = os.path.dirname(pj)
        try:
            data = json.loads(ctx["text"][pj])
        except Exception:
            continue
        cands = []
        for k in ("main", "module", "browser", "types", "typings", "source"):
            if isinstance(data.get(k), str):
                cands.append(data[k])
        for k in ("bin", "exports"):
            v = data.get(k)
            if isinstance(v, str):
                cands.append(v)
            elif isinstance(v, dict):
                cands += [x for x in _flatten_strings(v)]
        for s in (data.get("scripts") or {}).values():
            cands += re.findall(r"[\w./-]+\.[jt]sx?\b", s or "")
        for c in cands:
            p = norm(os.path.normpath(os.path.join(d, c.lstrip("./"))))
            for t in [p] + [p + e for e in JS_EXT] + [p + "/index" + e for e in JS_EXT]:
                mark(t, f"{os.path.basename(pj)} entry (main/bin/exports/scripts)")

    # A bundler config names the app's real roots as quoted paths (`entry: { spa: 'src/views/
    # index.tsx' }`). Without them a frontend's whole graph reads as unreachable, which is the
    # single biggest way this analysis goes wrong on a monorepo.
    for cfg in [f for f in ctx["src_all"] + list(files)
                if os.path.basename(f) in JS_ENTRY_BASENAMES or re.search(r"\.config\.[jt]sx?$", f)]:
        d = os.path.dirname(cfg)
        for q in re.findall(r"['\"]([\w./@-]+\.[jt]sx?)['\"]", ctx["text"].get(cfg, "")):
            p2 = norm(os.path.normpath(os.path.join(d, q.lstrip("/."))))
            mark(p2, f"entry path named in {os.path.basename(cfg)}")
    for f in ctx["src_all"]:
        if re.search(r"(^|/)src/(index|main|app|entry|bootstrap|preamble)\.[jt]sx?$", f):
            mark(f, "conventional application root (src/index|main|app)")

    # An HTML page is a root: `<script type="module" src="./main.tsx">` is how every Vite app,
    # and every Electron renderer, boots. Nothing in the repo imports that file, so without this
    # the entire UI tree reads as one large dead cluster.
    for html in [f for f in files if f.endswith((".html", ".htm"))]:
        d = os.path.dirname(html)
        for ref in re.findall(r"<(?:script|link)[^>]*?(?:src|href)\s*=\s*['\"]([^'\"]+)['\"]",
                              ctx["text"].get(html, ""), re.I):
            if ref.startswith(("http://", "https://", "//", "data:", "#")):
                continue
            cand = norm(os.path.normpath(os.path.join(d, ref.lstrip("/"))))
            for t in [cand] + [cand + e for e in JS_EXT]:
                mark(t, f"loaded by <script>/<link> in {html}")
            if ref.startswith("/"):        # a root-absolute src, resolved against each package dir
                for base in {os.path.dirname(pj) for pj in files if os.path.basename(pj) == "package.json"}:
                    for sub in ("", "src", "public"):
                        c2 = norm(os.path.normpath(os.path.join(base, sub, ref.lstrip("/"))))
                        for t in [c2] + [c2 + e for e in JS_EXT]:
                            mark(t, f"loaded by <script>/<link> in {html}")

    # pyproject / setup.cfg console_scripts: "pkg.module:function"
    for cfg in [f for f in files if os.path.basename(f) in ("pyproject.toml", "setup.cfg", "setup.py")]:
        for mod in re.findall(r"=\s*[\"']?([\w.]+):[\w.]+", ctx["text"][cfg]):
            for cand in (mod.replace(".", "/") + ".py", mod.replace(".", "/") + "/__init__.py"):
                mark(cand, f"console_scripts entry in {os.path.basename(cfg)}")
    # Dockerfiles / Procfile / CI: a path named in a run command is a way in
    for f in [x for x in files if os.path.basename(x) in ("Dockerfile", "Procfile", "Makefile")
              or x.startswith(".github/workflows/")]:
        for p in re.findall(r"[\w./-]+\.(?:py|[jt]sx?)\b", ctx["text"][f]):
            mark(norm(os.path.normpath(p.lstrip("./"))), f"referenced by {os.path.basename(f)}")
    return eps


def _flatten_strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from _flatten_strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from _flatten_strings(x)


def reachable(eps, imports, src_all):
    seen, stack = set(), list(eps)
    while stack:
        f = stack.pop()
        if f in seen:
            continue
        seen.add(f)
        stack.extend(x for x in imports.get(f, ()) if x not in seen)
    return seen


def analyse(root, args):
    files = list_files(root, args.exclude)
    ctx = build(root, files, args.include_tests)
    eps = entry_points(root, files, ctx, args.include_tests, getattr(args, "entry", ()))
    # Reachability is computed TWICE, from the product's ways in and from the tests separately.
    # One pass cannot tell "alive" from "kept alive by its own test", and that distinction is the
    # most actionable thing this script reports: code whose only caller is its test is dead code
    # with a test attached, and deleting both is one commit.
    prod_eps = {f: w for f, w in eps.items() if not is_test(f)}
    test_eps = {f: w for f, w in eps.items() if is_test(f)}
    reach = reachable(prod_eps, ctx["imports"], ctx["src_all"])
    test_reach = reachable(test_eps, ctx["imports"], ctx["src_all"]) - reach

    # --- usage index over every file in the repo, source or not
    name_uses, string_uses = {}, {}
    parse_errors = []
    for f in files:
        t = ctx["text"][f]
        if not t:
            continue
        if f.endswith((".py", ".pyi")):
            names, strings = py_uses(t)
        elif f.endswith(JS_EXT) or f.endswith(TEXTUAL_EXT):
            names, strings = set(IDENT_RE.findall(t)), set()
        else:
            continue
        for n in names:
            name_uses.setdefault(n, set()).add(f)
        for n in strings:
            string_uses.setdefault(n, set()).add(f)

    # Modules loaded by name rather than by import: DJANGO_SETTINGS_MODULE, a celery `include`,
    # importlib, a plugin registry, an entry-point string. Whatever loads them reads their
    # contents by name too, so nothing inside one can be called unreferenced from here.
    QUOTED_RE = re.compile(r"['\"]([\w.]+\.[\w.]+)['\"]")
    quoted = set()
    for f in files:
        if f.endswith(JS_EXT) or f.endswith(TEXTUAL_EXT) or f.endswith((".py", ".pyi")):
            quoted.update(QUOTED_RE.findall(ctx["text"][f]))
    quoted |= {n for n in string_uses if "." in n}   # the whole-string literals py_uses kept
    # Files pulled in by FILENAME rather than by import. The identifier index cannot see these,
    # because `care-team.js` and `probe-mount-discovery.ts` are not identifiers, and they are as
    # often unquoted as quoted:
    #   inlineScript('care-team.js')                       a quoted asset path
    #   "./plugins/withModularHeaders"                     a plugin listed in a config
    #   zip -j "$ZIP" handler.mjs google-auth.mjs          a deploy script naming its payload
    #   `bun probes/probe-mount-discovery.ts`              a command a README tells you to run
    # The last two are why this indexes path-shaped tokens anywhere in a file, not only inside
    # quotes: a script documented as a command IS an entry point, and its README says so.
    PATHISH_RE = re.compile(r"[\w@][\w@./-]*\.[A-Za-z0-9]{1,5}\b")
    QUOTED_ANY_RE = re.compile(r"['\"`]([^'\"`\n]{2,120})['\"`]")
    filename_mentions = {}
    for f in files:
        if not (f.endswith(JS_EXT) or f.endswith(TEXTUAL_EXT) or f.endswith((".py", ".pyi"))):
            continue
        t = ctx["text"][f]
        segs = set()
        for q in PATHISH_RE.findall(t):
            seg = q.rstrip("/").split("/")[-1]
            segs.add(seg)
            segs.add(seg.rsplit(".", 1)[0])
        for q in QUOTED_ANY_RE.findall(t):        # a quoted path with no extension
            seg = q.rstrip("/").split("/")[-1]
            if seg and "." not in seg:
                segs.add(seg)
        for seg in segs:
            if seg and not seg.startswith("."):
                filename_mentions.setdefault(seg, set()).add(f)

    dynamic_modules = {}
    for f in ctx["src"]:
        if not f.endswith((".py", ".pyi")):
            continue
        parts = norm(f).rsplit(".", 1)[0].split("/")
        if parts[-1] == "__init__":
            parts = parts[:-1]
        for i in range(len(parts) - 1):
            dotted = ".".join(parts[i:])
            if dotted in quoted:
                dynamic_modules[f] = dotted
                break

    def referenced_by_filename(f, importers):
        """Is this file named, as a filename, by something that is not already importing it?

        The importers are subtracted because their mention IS the import specifier — counting it
        would make every file evidence for itself, and would hide exactly the finding that matters
        most here: a module whose only mention anywhere is its own test importing it."""
        b = os.path.basename(f)
        for cand in (b, b.rsplit(".", 1)[0]):
            if len(cand) < args.min_name_len or cand.lower() in COMMON_NAMES:
                continue
            where = sorted(filename_mentions.get(cand, set()) - {f} - set(importers))
            if where:
                return cand, where[0]
        return None

    def named_elsewhere(f):
        """Is this file, or something it defines, named as a string anywhere outside it? A module
        loaded by a settings path, a template calling a helper and a task registry all look like
        nothing at all to an import graph."""
        stem = os.path.basename(f).rsplit(".", 1)[0]
        cands = {stem, norm(f).rsplit(".", 1)[0].replace("/", ".")}
        t = ctx["text"][f]
        if f.endswith((".py", ".pyi")):
            parsed, _ = py_symbols(f, t)
            if parsed:
                cands |= {s["name"] for s in parsed["symbols"] if not s["name"].startswith("_")}
        else:
            cands |= {n for n, _ in js_exports(t)}
        for n in cands:
            if len(n) < args.min_name_len or n.lower() in COMMON_NAMES:
                continue
            for u in sorted(string_uses.get(n, set()) - {f}):
                return n, u          # a name inside a string literal is a dynamic reference:
                                     # a Django MIDDLEWARE entry, a celery task path, importlib
            for u in sorted(name_uses.get(n, set()) - {f}):
                if u.endswith(TEXTUAL_EXT):
                    return n, u      # a template or a config naming the symbol
        return None

    # How much of the repo the import graph actually explains. Below the floor, the entry-point
    # list is missing a root and the unreachable list is mostly an artifact of that — reporting it
    # anyway would be the most expensive kind of wrong answer this script can give, so it says so
    # and suppresses the file-level half instead.
    considered = [f for f in ctx["src"] if not is_test(f)]
    covered = [f for f in considered if f in reach or f in prod_eps]
    coverage = len(covered) / max(1, len(considered))
    discovery_ok = coverage >= args.min_coverage

    # --- 1. files nothing reaches
    unreachable, excluded = [], []
    dead_set = {f for f in ctx["src"] if f not in reach and f not in prod_eps}
    for f in ctx["src"]:
        if f in reach or f in prod_eps:
            continue
        importers = sorted(g for g, s in ctx["imports"].items() if f in s)
        rec = {"file": f, "lines": ctx["text"][f].count("\n") + 1, "imported_by": importers[:5]}
        hit = named_elsewhere(f)
        fname_hit = referenced_by_filename(f, importers)
        live_importers = [g for g in importers if g not in dead_set]
        # The exclusions come first: evidence that something loads this file by name settles the
        # question regardless of what the import graph shows. A deploy script naming its payload
        # and a README documenting a command to run are both that evidence.
        if hit:
            excluded.append({"file": f, "line": 1, "name": hit[0], "kind": "file", "language": "",
                             "reason": f"unimported, but `{hit[0]}` is named in {hit[1]} — loaded by name, not by import"})
        elif fname_hit:
            excluded.append({"file": f, "line": 1, "name": fname_hit[0], "kind": "file", "language": "",
                             "reason": f"unimported, but the filename `{fname_hit[0]}` is named in {fname_hit[1]} — run or loaded by name, not imported"})
        elif f in test_reach:
            unreachable.append({**rec, "confidence": "medium",
                                "verdict": "reached only from tests — the product does not use it"})
        elif importers and not live_importers:
            # Imported, but only by files that are themselves unreachable. Deleting one of these
            # without the others just moves the finding, so they are named as one cluster.
            unreachable.append({**rec, "confidence": "high",
                                "verdict": f"only imported by other unreachable files ({len(importers)}) — a dead cluster"})
        else:
            unreachable.append({**rec, "confidence": "high", "verdict": "no importer anywhere"})
    unreachable.sort(key=lambda x: (x["confidence"] != "high", -x["lines"]))

    # --- 2 and 3. definitions nothing references
    unreferenced, exported_not_imported = [], []
    # When reachability is not trustworthy, judge every file's symbols rather than only the ones
    # the graph reached: the symbol check does not depend on the entry-point list.
    live_files = ctx["src"] if not discovery_ok else [f for f in ctx["src"] if f in reach or f in prod_eps]

    for f in live_files:
        t = ctx["text"][f]
        if f.endswith((".py", ".pyi")):
            parsed, err = py_symbols(f, t)
            if err:
                parse_errors.append(f"{f}: {err}")
                continue
            for s in parsed["symbols"]:
                n = s["name"]
                rec = {"file": f, "line": s["line"], "name": n, "kind": s["kind"], "language": "python"}
                if len(n) < args.min_name_len or n.lower() in COMMON_NAMES or n.startswith("__"):
                    continue
                if n in parsed["all"]:
                    excluded.append({**rec, "reason": "listed in __all__ (declared public API)"})
                    continue
                if f in dynamic_modules:
                    excluded.append({**rec, "reason": f"its module is loaded by name (`{dynamic_modules[f]}` appears as a string) — whatever loads it reads these by name too"})
                    continue
                if f in ctx["namespace_imported"]:
                    excluded.append({**rec, "reason": "its module is star-imported (`from … import *`) elsewhere — every name in it is re-exported"})
                    continue
                if s["kind"] == "constant" and f in eps:
                    excluded.append({**rec, "reason": f"module-level constant in an entry-point module ({eps[f]}) — read by name by whatever loads it"})
                    continue
                if s["decorators"]:
                    excluded.append({**rec, "reason": f"decorated (@{s['decorators'][0][:40]}) — frameworks call by decorator"})
                    continue
                users = (name_uses.get(n, set()) | string_uses.get(n, set())) - {f}
                if users:
                    if n in ctx["named_imports"] or any(u.endswith((".py", ".pyi")) for u in users):
                        continue
                    excluded.append({**rec, "reason": f"name appears in {sorted(users)[0]}"})
                    continue
                local = local_uses(t, n, sep=".")
                if local <= 1:
                    unreferenced.append({**rec, "confidence": "high" if s["private"] else "medium",
                                         "note": "private to its module and never used in it" if s["private"]
                                                 else "no reference in any file in the repo"})
                elif not s["private"] and f not in eps:
                    # Two things that are not findings: a `_private` name used inside its own
                    # module, and any helper inside a standalone script, whose functions are
                    # local by nature. Reporting either buries the public names with no consumer.
                    exported_not_imported.append({**rec, "local_uses": local - 1,
                                                  "note": "used inside its own module only — not part of any API"})
        else:
            file_is_wholesale = f in ctx["namespace_imported"]
            for n, line in js_exports(t):
                rec = {"file": f, "line": line, "name": n, "kind": "export", "language": "ts/js"}
                if len(n) < args.min_name_len or n.lower() in COMMON_NAMES:
                    continue
                if f in eps:
                    excluded.append({**rec, "reason": f"an entry-point module ({eps[f]}) — its exports are the API of whatever loads it, not of this repo"})
                    continue
                if ".stories." in f:
                    excluded.append({**rec, "reason": "a story file: Storybook loads it by glob and every export is a story"})
                    continue
                if file_is_wholesale:
                    excluded.append({**rec, "reason": "its module is imported wholesale (`import * as` / `export * from`)"})
                    continue
                users = (name_uses.get(n, set()) | string_uses.get(n, set())) - {f}
                if users:
                    if n in ctx["named_imports"]:
                        continue
                    non_code = [u for u in sorted(users) if not u.endswith(JS_EXT)]
                    if non_code:
                        excluded.append({**rec, "reason": f"name appears in {non_code[0]}"})
                    else:
                        exported_not_imported.append({**rec, "local_uses": len(users),
                                                      "note": f"the identifier appears in {sorted(users)[0]} but is never imported by name — check for a same-named local"})
                    continue
                local = local_uses(t, n)
                if local <= 1:
                    unreferenced.append({**rec, "confidence": "medium",
                                         "note": "exported, and the name appears in no other file"})
                else:
                    exported_not_imported.append({**rec, "local_uses": local - 1,
                                                  "note": "used inside its own module only — the `export` is what is dead"})

    suppressed = []
    if not discovery_ok:
        suppressed, unreachable = unreachable, []

    order = {"high": 0, "medium": 1, "low": 2}
    unreferenced.sort(key=lambda x: (order[x["confidence"]], x["file"], x["line"]))
    exported_not_imported.sort(key=lambda x: (x["file"], x["line"]))
    excluded.sort(key=lambda x: (x["file"], x["line"]))

    # Only real source languages: nobody is asking this script about dead shell or SQL.
    langs = sorted({language_of(f) for f in files if is_source(f) and language_of(f)} - {None})
    unsupported = [l for l in langs if l not in ("python", "typescript", "javascript")]
    return {
        "repo": root,
        "analysed": {"python_files": len(ctx["py"]), "ts_js_files": len(ctx["js"]),
                     "entry_points": len(eps), "reachable_files": len(reach),
                     "import_graph_coverage": round(coverage, 3),
                     "entry_point_discovery": "ok" if discovery_ok else "incomplete",
                     "unresolved_relative_imports": ctx["unresolved"],
                     "unresolved_bare_specifiers": ctx["unresolved_bare"][:20]},
        "entry_points": dict(sorted(eps.items())),
        "unreachable_files": unreachable,
        "unreachable_files_suppressed": suppressed if not discovery_ok else [],
        "unreferenced_definitions": unreferenced,
        "exported_but_never_imported": exported_not_imported,
        "excluded_with_reason": excluded,
        "parse_errors": parse_errors,
        "languages_not_analysed": unsupported,
        "caveat": "Candidates, not verdicts. Frameworks call by convention, and callers outside "
                  "this repo are invisible from inside it. Open every file before acting.",
    }


UNSUPPORTED_TOOL = {
    "go": "`go vet` plus `staticcheck -checks U1000` (unused) — and the compiler already rejects unused imports",
    "rust": "`cargo +nightly udeps`, `cargo machete`, and the compiler's own `dead_code` lint",
    "ruby": "`debride`, or Rails' `unused` gem — Ruby's dynamic dispatch defeats static analysis",
    "java": "IntelliJ inspections or `pmd -R unusedcode`",
    "kotlin": "`detekt` with the unused-* rules",
    "csharp": "Roslyn analysers IDE0051/IDE0052, or ReSharper",
    "php": "`phpstan` at level 6+, or `composer-unused`",
    "swift": "`periphery scan`",
    "elixir": "`mix xref unreachable`",
    "dart": "`dart analyze` with `unused_element`",
    "scala": "`-Wunused:all`",
    "cpp": "`-Wunused` plus `clang-tidy misc-unused-*`",
    "c": "`-Wunused` plus `cppcheck --enable=unusedFunction`",
    "objc": "Xcode's own analyser",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--out", default=None, help="directory for dead-code.json (must be outside the repo or gitignored)")
    ap.add_argument("--exclude", nargs="*", default=[], help="extra directory names to exclude")
    ap.add_argument("--entry", nargs="*", default=[],
                    help="extra entry-point paths (repo-relative). Use these when the summary says "
                         "entry-point discovery is incomplete — a root this pass cannot see makes "
                         "everything behind it look unreachable")
    ap.add_argument("--include-tests", action="store_true",
                    help="analyse test files too, instead of treating them as entry points")
    ap.add_argument("--min-name-len", type=int, default=DEFAULT_MIN_NAME)
    ap.add_argument("--min-coverage", type=float, default=0.6,
                    help="the fraction of non-test source files the import graph must explain "
                         "before file-level findings are reported at all (default 0.6)")
    ap.add_argument("--fail-on", choices=["none", "high", "medium"], default="none",
                    help="exit 1 when a finding at this confidence or above exists (for a CI ratchet)")
    ap.add_argument("--json", action="store_true", help="print the JSON to stdout instead of the summary")
    a = ap.parse_args()
    root = os.path.abspath(a.repo)
    r = analyse(root, a)

    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "dead-code.json"), "w") as fh:
            json.dump(r, fh, indent=1)
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        an = r["analysed"]
        print(f"dead code: {an['python_files']} python + {an['ts_js_files']} ts/js files, "
              f"{an['entry_points']} entry points, {an['reachable_files']} reachable "
              f"({an['unresolved_relative_imports']} unresolved relative imports)")
        if an["entry_point_discovery"] != "ok":
            print(f"\nENTRY-POINT DISCOVERY INCOMPLETE: the import graph explains only "
                  f"{an['import_graph_coverage']:.0%} of non-test source files, below the "
                  f"{a.min_coverage:.0%} floor. File-level findings are SUPPRESSED "
                  f"({len(r['unreachable_files_suppressed'])} would have been reported) because at "
                  f"this coverage they are mostly an artifact of a root this pass cannot see.")
            if an["unresolved_bare_specifiers"]:
                print("  unresolved repo-internal specifiers (a likely cause): "
                      + ", ".join(an["unresolved_bare_specifiers"][:8]))
            print("  re-run with --entry <the real roots> to get them, or --min-coverage 0 to see them anyway.")
        print(f"\nunreachable files: {len(r['unreachable_files'])}")
        for x in r["unreachable_files"][:20]:
            print(f"  - [{x['confidence']:>6}] {x['file']} ({x['lines']} lines) — {x['verdict']}"
                  + (f": {', '.join(x['imported_by'][:3])}" if x["imported_by"] else ""))
        hi = [x for x in r["unreferenced_definitions"] if x["confidence"] == "high"]
        print(f"\nunreferenced definitions: {len(r['unreferenced_definitions'])} ({len(hi)} high confidence)")
        for x in r["unreferenced_definitions"][:30]:
            print(f"  - [{x['confidence']:>6}] {x['file']}:{x['line']}  {x['kind']} {x['name']} — {x['note']}")
        print(f"\nexported but never imported: {len(r['exported_but_never_imported'])}")
        for x in r["exported_but_never_imported"][:15]:
            print(f"  - {x['file']}:{x['line']}  {x['name']} — {x['note']}")
        print(f"\nexcluded with a reason (NOT dead, and why): {len(r['excluded_with_reason'])}")
        for x in r["excluded_with_reason"][:10]:
            print(f"  - {x['file']}:{x['line']}  {x['name']} — {x['reason']}")
        if r["parse_errors"]:
            print(f"\nunparsed ({len(r['parse_errors'])}) — not analysed, not guessed at: "
                  + "; ".join(r["parse_errors"][:5]))
        if r["languages_not_analysed"]:
            print("\nnot analysed here — these need the model's judgment plus the language's own tool:")
            for l in r["languages_not_analysed"]:
                print(f"  - {l}: {UNSUPPORTED_TOOL.get(l, 'no deterministic pass in this script')}")
        print("\n" + r["caveat"])
        if a.out:
            print(f"wrote {a.out}/dead-code.json")

    if a.fail_on != "none":
        bad = [x for x in r["unreferenced_definitions"] + r["unreachable_files"]
               if x["confidence"] == "high" or (a.fail_on == "medium" and x["confidence"] == "medium")]
        if bad:
            print(f"\nFAIL: {len(bad)} finding(s) at confidence >= {a.fail_on}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
