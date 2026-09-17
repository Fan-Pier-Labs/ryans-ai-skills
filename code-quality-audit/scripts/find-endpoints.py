#!/usr/bin/env python3
"""Find HTTP endpoints, whether each visibly requires authentication, and whether anything
in the repo references it (dead-endpoint candidates).

  scripts/find-endpoints.py [--repo .] [--out <dir>] [--exclude dir ...]

Frameworks: Express/Koa/Fastify/Hono-style `x.get('/path', ...)`, NestJS decorators,
Next.js `pages/api` + `app/**/route.*`, FastAPI (+ APIRouter/include_router), Flask
(+ blueprints), Django `urls.py`, Rails `routes.rb`, Go (net/http, gin, chi, echo, fiber),
Spring `@*Mapping`, ASP.NET `[HttpGet]`.

Router mounts are followed one file deep in both directions: `app.use('/api/users',
requireAuth, usersRouter)` / `app.include_router(r, prefix=..., dependencies=[...])` /
`register_blueprint(bp, url_prefix=...)` give the mounted file's routes their full path and
a "router" auth status.

Auth is a *heuristic*: "inline" = an auth-looking argument/decorator/guard on the route
itself; "router" = auth applied to the router/blueprint/controller that owns the route (or
at its mount point); "global" evidence = an app-wide auth middleware exists (listed
separately — confirm which paths it really covers); "none-seen" = nothing auth-looking
near the route; "expected-public" = health/login/webhook-style paths; "unknown" = the
framework declares routes away from handlers (Django, Rails) so the handler must be read.
References: the rest of the repo is searched for the full path (params as wildcards);
`prefix_references` counts looser matches on the static prefix. Evidence, not a verdict.
Pure read.
"""
import argparse, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _repo_files import list_files, is_test, read_text  # noqa: E402

AUTH_RE = re.compile(r"auth|login_?required|jwt|passport|protect|require_?(user|login|session|role|admin)|"
                     r"verify_?token|guard|permission|current_?user|api_?key|bearer|is_?authenticated|"
                     r"ensure_?logged|secured|authorize|IsAuthenticated|LoginRequired|get_?user\b", re.I)
NOT_AUTH_RE = re.compile(r"Router\(|express\.(json|static|urlencoded)|\bcors\b|bodyParser|helmet|morgan|compression|cookieParser|rateLimit", re.I)
PUBLIC_RE = re.compile(r"^/?(health|healthz|ping|status|ready|readyz|live|livez|metrics|version|docs|redoc|openapi(\.json)?|"
                       r"swagger(-ui)?|favicon\.ico|robots\.txt|login|logout|signin|signup|sign-in|sign-up|register|auth|oauth|"
                       r"callback|webhooks?|password|forgot(-password)?|reset(-password)?|verify(-email)?|token|refresh|public|static|"
                       r"assets|\.well-known)(/|$)|^/api/(health|healthz|ping|status|version|docs|login|logout|signup|register|auth|oauth|webhooks?|public)(/|$)", re.I)
METHODS = "get|post|put|patch|delete|options|head|all"
GENERIC_SEG = {"api", "v1", "v2", "v3", "app", "index", "internal", "admin", "public"}
NOT_ROUTER_VARS = {"req", "request", "res", "response", "map", "cache", "headers", "localStorage", "sessionStorage", "params",
                   "searchParams", "store", "this", "window", "document", "config", "settings", "env", "process", "form",
                   "formData", "url", "cookies", "storage", "redis", "client", "db", "collection", "table", "obj", "self"}

JS_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
JS_ROUTE_RE = re.compile(r"\b(\w+)\.(" + METHODS + r")\(\s*(['\"`])(/[^'\"`\n]*)\3\s*(,([^\n]*))?", re.I)
JS_USE_RE = re.compile(r"\b(\w+)\.use\(\s*(?:(['\"`])(/[^'\"`\n]*)\2\s*,)?\s*([^\n]*)\)")
JS_ROUTE_CHAIN_RE = re.compile(r"\.route\(\s*(['\"`])(/[^'\"`\n]*)\1\s*\)((?:\s*\.\w+\([^\n]*\))+)")
JS_IMPORT_RE = re.compile(r"import\s+(?:(\w+)|\{([^}]*)\}|\*\s+as\s+(\w+))\s+from\s+['\"]([^'\"]+)['\"]|"
                          r"(?:const|let|var)\s+(?:(\w+)|\{([^}]*)\})\s*=\s*require\(\s*['\"]([^'\"]+)['\"]\s*\)")
NEST_CTRL_RE = re.compile(r"@Controller\(\s*(?:['\"]([^'\"]*)['\"])?")
NEST_ROUTE_RE = re.compile(r"@(Get|Post|Put|Patch|Delete|All|Options|Head)\(\s*(?:['\"]([^'\"]*)['\"])?")
PY_ROUTE_RE = re.compile(r"^\s*@(\w+)\.(" + METHODS + r"|api_route|route)\(\s*['\"]([^'\"]+)['\"](.*)$", re.I)
PY_DECOR_RE = re.compile(r"^\s*@(.+)$")
PY_DEF_RE = re.compile(r"^\s*(async\s+)?def\s+(\w+)\s*\((.*)$")
PY_FROM_IMPORT_RE = re.compile(r"^\s*from\s+([.\w]+)\s+import\s+([^\n#]+)", re.M)
PY_IMPORT_RE = re.compile(r"^\s*import\s+([.\w]+)(?:\s+as\s+(\w+))?", re.M)
DJANGO_PATH_RE = re.compile(r"\b(?:re_)?path\(\s*r?['\"]([^'\"]*)['\"]\s*,\s*([\w.]+)(?:\.as_view\(\))?")
RAILS_RE = re.compile(r"^\s*(get|post|put|patch|delete|match)\s+['\"]([^'\"]+)['\"]|^\s*resources?\s+:(\w+)", re.M)
GO_RE = re.compile(r"\b(\w+)\.(HandleFunc|Handle|GET|POST|PUT|PATCH|DELETE|Get|Post|Put|Patch|Delete|Any|Method)\(\s*(?:\"(\w+)\"\s*,\s*)?\"(/[^\"\n]*)\"\s*,?([^\n]*)")
SPRING_RE = re.compile(r"@(Get|Post|Put|Patch|Delete|Request)Mapping\(\s*(?:value\s*=\s*|path\s*=\s*)?(?:\{)?['\"]([^'\"]*)['\"]")
DOTNET_RE = re.compile(r"\[Http(Get|Post|Put|Patch|Delete)\(?(?:\"([^\"]*)\")?\)?\]")


def norm_path(prefix, p):
    p = (prefix.rstrip("/") + "/" + p.lstrip("/")) if prefix else p
    p = re.sub(r"/+", "/", p or "/")
    p = p if p.startswith("/") else "/" + p
    return p if p == "/" else p.rstrip("/")


class Scan:
    def __init__(self, root, files):
        self.root, self.files, self.files_set = root, files, set(files)
        self.texts, self.eps, self.globals, self.mounts = {}, [], [], []
        py = [f for f in files if f.endswith(".py")]
        self.py_index = {}
        for f in py:
            parts = f[:-3].split("/")
            if parts[-1] == "__init__":
                parts = parts[:-1]
            for i in range(len(parts)):
                self.py_index.setdefault(".".join(parts[i:]), []).append(f)

    def add(self, **kw):
        kw.setdefault("auth", "none-seen"); kw.setdefault("auth_evidence", ""); kw.setdefault("router_var", None)
        kw["path"] = norm_path("", kw["path"])
        self.eps.append(kw)

    # ---------- resolution helpers ----------
    def resolve_js(self, from_file, spec):
        cands = []
        if spec.startswith("."):
            cands.append(os.path.normpath(os.path.join(os.path.dirname(from_file), spec)).replace(os.sep, "/"))
        elif spec.startswith(("@/", "~/")):
            for src in ("src", "app", "lib", "."):
                cands.append(os.path.normpath(os.path.join(src, spec[2:])).replace(os.sep, "/"))
        for c in cands:
            stem = os.path.splitext(c)[0]
            for t in [c] + [c + e for e in JS_EXT] + [stem + e for e in JS_EXT] + [c + "/index" + e for e in JS_EXT]:
                if t in self.files_set:
                    return t
        return None

    def js_import_target(self, text, var, from_file):
        for m in JS_IMPORT_RE.finditer(text):
            default, named, star, spec, rdefault, rnamed, rspec = m.groups()
            names = set()
            for n in (default, star, rdefault):
                if n: names.add(n)
            for grp in (named, rnamed):
                for part in (grp or "").split(","):
                    part = part.strip()
                    if part:
                        names.add(part.split(" as ")[-1].strip())
            if var in names:
                return self.resolve_js(from_file, spec or rspec)
        return None

    def resolve_py(self, from_file, module, level):
        if level:
            base = os.path.dirname(from_file)
            for _ in range(level - 1):
                base = os.path.dirname(base)
            t = os.path.join(base, *module.split(".")).replace(os.sep, "/") if module else base
            for c in (t + ".py", t + "/__init__.py"):
                if c in self.files_set:
                    return c
            return None
        hits = self.py_index.get(module)
        if not hits:
            return None
        return max(hits, key=lambda h: len(os.path.commonprefix([h, from_file])))

    def py_import_target(self, text, var, from_file):
        """`var` may be `alias` (from m import x as alias / import m as alias) or `mod.attr`."""
        attr = None
        if "." in var:
            var, attr = var.split(".", 1)
        for m in PY_FROM_IMPORT_RE.finditer(text):
            mod, names = m.group(1), m.group(2).strip("() \\\n")
            level = len(mod) - len(mod.lstrip("."))
            for part in names.split(","):
                part = part.strip()
                if not part:
                    continue
                name, _, alias = part.partition(" as ")
                name, alias = name.strip(), alias.strip()
                if (alias or name) == var:
                    modfile = self.resolve_py(from_file, mod.lstrip("."), level)
                    if attr is None:
                        # `from app.users import router as users_router`: the name lives in module file, or is a submodule
                        sub = self.resolve_py(from_file, (mod.lstrip(".") + "." + name) if mod.lstrip(".") else name, level)
                        return (sub, None) if sub and attr is None and name not in ("router", "bp", "blueprint", "api") else (modfile, name)
                    sub = self.resolve_py(from_file, (mod.lstrip(".") + "." + name) if mod.lstrip(".") else name, level)
                    return (sub or modfile, attr)
        for m in PY_IMPORT_RE.finditer(text):
            mod, alias = m.group(1), m.group(2)
            if (alias or mod.split(".")[-1] or mod) == var:
                return (self.resolve_py(from_file, mod, 0), attr)
        return (None, None)

    # ---------- per-language scanners ----------
    def scan_js(self, f, text):
        lines = text.split("\n"); router_auth = {}; ctrl_prefix, ctrl_guard = "", None
        for i, line in enumerate(lines, 1):
            m = NEST_CTRL_RE.search(line)
            if m:
                ctrl_prefix = m.group(1) or ""; ctrl_guard = None
                for k in range(max(0, i - 6), i - 1):
                    if "@UseGuards(" in lines[k]:
                        ctrl_guard = f"{f}:{k+1} {lines[k].strip()[:80]}"
            m = NEST_ROUTE_RE.search(line)
            if m:
                guard = None; public = False
                for k in range(max(0, i - 5), min(len(lines), i + 2)):
                    if "@UseGuards(" in lines[k] and "@Controller" not in "\n".join(lines[k:k + 3]):
                        guard = f"{f}:{k+1} {lines[k].strip()[:80]}"
                    if re.search(r"@(Public|AllowAnonymous|SkipAuth)\(", lines[k]):
                        public = True
                auth, ev = ("inline", guard) if guard else (("router", ctrl_guard) if ctrl_guard else ("none-seen", ""))
                if public:
                    auth, ev = "public-explicit", "@Public()"
                self.add(file=f, line=i, framework="nestjs", method=m.group(1).upper(), path=norm_path(ctrl_prefix, m.group(2) or ""),
                         auth=auth, auth_evidence=ev)
                continue
            for m in JS_USE_RE.finditer(line):
                var, path, args = m.group(1), m.group(3), (m.group(4) or "").strip()
                has_auth = bool(AUTH_RE.search(args)) and not NOT_AUTH_RE.search(args.split(",")[0]) if not path else bool(AUTH_RE.search(args))
                mounted = [x.strip() for x in args.split(",") if re.match(r"^\w+$", x.strip())]
                target_var = mounted[-1] if mounted else None
                if path and target_var:
                    self.mounts.append({"file": f, "line": i, "kind": "js", "var": target_var, "prefix": path,
                                        "auth": f"{f}:{i} {line.strip()[:100]}" if has_auth else None})
                elif has_auth and path:
                    router_auth[("prefix", path)] = f"{f}:{i} {line.strip()[:100]}"
                elif has_auth:
                    router_auth[var] = f"{f}:{i} {line.strip()[:100]}"
                    if var in ("app", "server", "fastify", "koa"):
                        self.globals.append({"file": f, "line": i, "kind": "app-level middleware", "text": line.strip()[:120]})
            for m in JS_ROUTE_RE.finditer(line):
                var, method, path, args = m.group(1), m.group(2), m.group(4), (m.group(6) or "")
                if var in NOT_ROUTER_VARS:
                    continue
                auth, ev = "none-seen", ""
                first_arg = args.split(",")[0] if args else ""
                if AUTH_RE.search(args) and not re.match(r"^\s*(async\s*)?\(?\s*(req|request|ctx|c)\b", args) and AUTH_RE.search(first_arg + "," + ",".join(args.split(",")[1:3])):
                    auth, ev = "inline", args.strip()[:100]
                elif var in router_auth:
                    auth, ev = "router", router_auth[var]
                else:
                    for k, e in router_auth.items():
                        if isinstance(k, tuple) and path.startswith(k[1]):
                            auth, ev = "router", e; break
                self.add(file=f, line=i, framework="express-style", method=method.upper(), path=path, auth=auth, auth_evidence=ev, router_var=var)
            for m in JS_ROUTE_CHAIN_RE.finditer(line):
                for mm in re.finditer(r"\.(" + METHODS + r")\(([^)]*)", m.group(3), re.I):
                    args = mm.group(2)
                    auth = "inline" if AUTH_RE.search(args) else "none-seen"
                    self.add(file=f, line=i, framework="express-style", method=mm.group(1).upper(), path=m.group(2), auth=auth,
                             auth_evidence=args.strip()[:100] if auth == "inline" else "")

    def scan_next(self, f, text):
        m = re.search(r"(?:^|/)(?:src/)?pages/api/(.+?)\.(ts|js|tsx|jsx)$", f); path = None
        if m:
            path = "/api/" + re.sub(r"/index$", "", m.group(1))
        else:
            m = re.search(r"(?:^|/)(?:src/)?app/(.+?)/route\.(ts|js|tsx|jsx)$", f)
            if m:
                path = "/" + re.sub(r"\(.*?\)/?", "", m.group(1))
        if not path:
            return
        path = re.sub(r"\[\.\.\.(\w+)\]", r"*\1", path); path = re.sub(r"\[(\w+)\]", r":\1", path)
        methods = re.findall(r"export\s+(?:async\s+)?(?:function|const)\s+(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)\b", text) or ["ANY"]
        ev = re.search(r"getServerSession|\bauth\(\)|getToken|currentUser|withAuth|verifyToken|getSession|requireAuth|clerk|supabase\.auth|getUser\(|withApiAuth", text)
        for meth in methods:
            self.add(file=f, line=1, framework="nextjs", method=meth, path=path, auth="inline" if ev else "none-seen",
                     auth_evidence=ev.group(0) if ev else "")

    def scan_py(self, f, text):
        lines = text.split("\n"); router_auth = {}; router_prefix = {}
        for i, line in enumerate(lines, 1):
            m = re.search(r"\b(\w+)\s*=\s*(?:APIRouter|Blueprint|Namespace)\((.*)$", line)
            if m:
                pm = re.search(r"(?:prefix|url_prefix)\s*=\s*['\"]([^'\"]*)['\"]", m.group(2))
                if pm: router_prefix[m.group(1)] = pm.group(1)
                if "dependencies" in m.group(2) and AUTH_RE.search(m.group(2)):
                    router_auth[m.group(1)] = f"{f}:{i} {line.strip()[:100]}"
            m = re.search(r"\.(include_router|register_blueprint|add_namespace)\(\s*([\w.]+)(.*)$", line)
            if m:
                pm = re.search(r"(?:prefix|url_prefix|path)\s*=\s*['\"]([^'\"]*)['\"]", m.group(3))
                has_auth = bool(re.search(r"dependencies\s*=", m.group(3)) and AUTH_RE.search(m.group(3)))
                self.mounts.append({"file": f, "line": i, "kind": "py", "var": m.group(2), "prefix": pm.group(1) if pm else "",
                                    "auth": f"{f}:{i} {line.strip()[:100]}" if has_auth else None})
            if re.search(r"add_middleware\(", line) and AUTH_RE.search(line):
                self.globals.append({"file": f, "line": i, "kind": "app.add_middleware", "text": line.strip()[:120]})
            m = re.search(r"@(\w+)\.before_(?:app_)?request", line)
            if m and AUTH_RE.search("\n".join(lines[i:i + 15])):
                if m.group(1) in ("app", "application"):
                    self.globals.append({"file": f, "line": i, "kind": "flask app.before_request", "text": line.strip()[:120]})
                else:
                    router_auth[m.group(1)] = f"{f}:{i} {line.strip()[:100]} (before_request)"
            if (re.search(r"DEFAULT_PERMISSION_CLASSES", line) or re.search(r"^\s*MIDDLEWARE\s*=", line)) and AUTH_RE.search("\n".join(lines[i - 1:i + 20])):
                self.globals.append({"file": f, "line": i, "kind": "django settings", "text": line.strip()[:120]})
        i = 0
        while i < len(lines):
            m = PY_ROUTE_RE.match(lines[i])
            if not m:
                i += 1; continue
            var, meth, path, rest = m.group(1), m.group(2).upper(), m.group(3), m.group(4)
            if meth == "ROUTE":
                mm = re.search(r"methods\s*=\s*[\[(]([^\])]*)[\])]", rest)
                meth = ",".join(re.findall(r"['\"](\w+)['\"]", mm.group(1))).upper() if mm else "GET"
            elif meth == "API_ROUTE":
                meth = "ANY"
            decos = [rest]; j = i + 1
            while j < len(lines) and (PY_DECOR_RE.match(lines[j]) or not lines[j].strip()):
                decos.append(lines[j]); j += 1
            sig = ""
            if j < len(lines) and PY_DEF_RE.match(lines[j]):
                sig = lines[j]; k = j
                while ")" not in sig and k + 1 < len(lines) and k - j < 12:
                    k += 1; sig += " " + lines[k]
            blob = "\n".join(decos) + "\n" + sig
            auth, ev = "none-seen", ""
            if AUTH_RE.search(blob) and (re.search(r"Depends\(|Security\(", blob) or re.search(r"@\w*(login_required|jwt_required|auth|permission|roles?_required|protected)\w*", blob, re.I)):
                auth, ev = "inline", blob.strip().replace("\n", " ")[:120]
            elif var in router_auth:
                auth, ev = "router", router_auth[var]
            self.add(file=f, line=i + 1, framework="fastapi/flask", method=meth, path=norm_path(router_prefix.get(var, ""), path),
                     auth=auth, auth_evidence=ev, router_var=var)
            i = j
        if f.endswith("urls.py"):
            for i, line in enumerate(lines, 1):
                for m in DJANGO_PATH_RE.finditer(line):
                    if "include(" in line:
                        continue
                    self.add(file=f, line=i, framework="django", method="ANY", path="/" + m.group(1).lstrip("^").rstrip("$"), auth="unknown",
                             auth_evidence=f"view {m.group(2)} — read its decorators / mixins / permission_classes")

    def scan_rails(self, f, text):
        if f.endswith("config/routes.rb"):
            for i, line in enumerate(text.split("\n"), 1):
                m = RAILS_RE.match(line)
                if not m:
                    continue
                if m.group(3):
                    self.add(file=f, line=i, framework="rails", method="RESOURCE", path="/" + m.group(3), auth="unknown",
                             auth_evidence="read the controller's before_action :authenticate_*")
                else:
                    self.add(file=f, line=i, framework="rails", method=m.group(1).upper(), path=m.group(2), auth="unknown",
                             auth_evidence="read the controller's before_action :authenticate_*")
        if "ApplicationController" in text and re.search(r"before_action\s+:authenticate", text):
            self.globals.append({"file": f, "line": 0, "kind": "rails ApplicationController before_action", "text": "authenticate_* on every controller"})

    def scan_go(self, f, text):
        lines = text.split("\n"); router_auth = {}; group_prefix = {}
        for i, line in enumerate(lines, 1):
            m = re.search(r"\b(\w+)\.Use\((.*)\)", line)
            if m and AUTH_RE.search(m.group(2)):
                router_auth[m.group(1)] = f"{f}:{i} {line.strip()[:100]}"
            m = re.search(r"\b(\w+)\s*:?=\s*(\w+)\.Group\(\s*\"([^\"]*)\"\s*,?([^\n]*)\)", line)
            if m:
                group_prefix[m.group(1)] = norm_path(group_prefix.get(m.group(2), ""), m.group(3))
                if AUTH_RE.search(m.group(4)) or m.group(2) in router_auth:
                    router_auth[m.group(1)] = f"{f}:{i} {line.strip()[:100]}"
            m = re.search(r"\b(\w+)\.Route\(\s*\"([^\"]*)\"", line)
            if m:
                group_prefix["__route__"] = m.group(2)
            for m in GO_RE.finditer(line):
                var, fn, meth, path, rest = m.groups()
                method = meth or (fn.upper() if fn.upper() in ("GET", "POST", "PUT", "PATCH", "DELETE") else "ANY")
                auth, ev = "none-seen", ""
                if AUTH_RE.search(rest or ""):
                    auth, ev = "inline", (rest or "").strip()[:100]
                elif var in router_auth:
                    auth, ev = "router", router_auth[var]
                self.add(file=f, line=i, framework="go", method=method, path=norm_path(group_prefix.get(var, ""), path), auth=auth, auth_evidence=ev, router_var=var)
        if router_auth and re.search(r"ListenAndServe\(|\.Run\(|\.Listen\(", text):
            self.globals.append({"file": f, "line": 0, "kind": "go router Use()", "text": "; ".join(list(router_auth.values())[:3])})

    def scan_jvm_dotnet(self, f, text):
        lines = text.split("\n"); prefix = ""
        for i, line in enumerate(lines, 1):
            m = re.search(r"@RequestMapping\(\s*(?:value\s*=\s*|path\s*=\s*)?['\"]([^'\"]*)['\"]", line)
            if m and re.search(r"\bclass\b", "\n".join(lines[i:i + 3])):
                prefix = m.group(1); continue
            m = SPRING_RE.search(line)
            if m and m.group(1) != "Request":
                ctx = "\n".join(lines[max(0, i - 4):i + 2])
                auth = "inline" if re.search(r"@(PreAuthorize|Secured|RolesAllowed)", ctx) else "none-seen"
                self.add(file=f, line=i, framework="spring", method=m.group(1).upper(), path=norm_path(prefix, m.group(2)), auth=auth,
                         auth_evidence="@PreAuthorize/@Secured" if auth == "inline" else "")
            m = re.search(r"\[Route\(\"([^\"]*)\"\)\]", line)
            if m and re.search(r"\bclass\b", "\n".join(lines[i:i + 3])):
                prefix = m.group(1).replace("[controller]", os.path.basename(f).replace("Controller.cs", "").lower())
            m = DOTNET_RE.search(line)
            if m:
                ctx = "\n".join(lines[max(0, i - 4):i + 2])
                auth = "inline" if "[Authorize" in ctx else ("public-explicit" if "[AllowAnonymous]" in ctx else "none-seen")
                self.add(file=f, line=i, framework="aspnet", method=m.group(1).upper(), path=norm_path(prefix, m.group(2) or ""), auth=auth,
                         auth_evidence="[Authorize]" if auth == "inline" else "")
        if re.search(r"(anyRequest\(\)\s*\.\s*authenticated|RequireAuthorization\(\)|app\.UseAuthentication|\[Authorize\]\s*\n\s*public\s+(abstract\s+)?class)", text):
            self.globals.append({"file": f, "line": 0, "kind": "framework security config", "text": "global authenticated()/UseAuthentication/class-level [Authorize]"})

    # ---------- mount resolution ----------
    def apply_mounts(self):
        file_prefix, file_auth = {}, {}
        resolved = []
        for m in self.mounts:
            text = self.texts.get(m["file"], "")
            if m["kind"] == "js":
                target = self.js_import_target(text, m["var"], m["file"])
                if target is None and re.search(r"\b(const|let|var|function)\s+" + re.escape(m["var"]) + r"\b", text):
                    target = m["file"]  # router defined in the mounting file itself
            else:
                target, _ = self.py_import_target(text, m["var"], m["file"])
                if target is None and re.search(r"\b" + re.escape(m["var"].split(".")[0]) + r"\s*=\s*(APIRouter|Blueprint)\(", text):
                    target = m["file"]
            m["target"] = target
            if target:
                resolved.append(m)
        for _ in range(5):
            changed = False
            for m in resolved:
                t = m["target"]
                base = file_prefix.get(m["file"], "") if m["target"] != m["file"] else ""
                new_prefix = norm_path(base, m["prefix"]) if (base or m["prefix"]) else ""
                new_auth = m["auth"] or file_auth.get(m["file"])
                if t != m["file"] and (file_prefix.get(t) != new_prefix or file_auth.get(t) != new_auth):
                    if t not in file_prefix or new_prefix:
                        file_prefix[t] = new_prefix
                    if new_auth:
                        file_auth[t] = new_auth
                    changed = True
            if not changed:
                break
        for e in self.eps:
            if e["framework"] not in ("express-style", "fastapi/flask", "go"):
                continue
            f = e["file"]
            # same-file mount: router defined and mounted in one file → match by router_var
            local = [m for m in resolved if m["target"] == f and m["file"] == f and m["var"].split(".")[-1] == e.get("router_var")]
            if local:
                m = local[0]
                e["path"] = norm_path(m["prefix"], e["path"])
                if m["auth"] and e["auth"] == "none-seen":
                    e["auth"], e["auth_evidence"] = "router", m["auth"]
            elif f in file_prefix or f in file_auth:
                if e.get("router_var") in ("app", "application", "server", "fastify"):
                    continue
                e["path"] = norm_path(file_prefix.get(f, ""), e["path"])
                if file_auth.get(f) and e["auth"] == "none-seen":
                    e["auth"], e["auth_evidence"] = "router", file_auth[f]
        for e in self.eps:
            if e["auth"] == "none-seen" and PUBLIC_RE.match(e["path"]):
                e["auth"] = "expected-public"

    # ---------- references ----------
    def count_refs(self, e):
        segs = [s for s in e["path"].split("/") if s]
        static = []
        for s in segs:
            if re.match(r"^[:{*<\[]", s) or "{" in s or "<" in s or s.startswith("*"):
                break
            static.append(s)
        meaningful = [s for s in segs if not re.match(r"^[:{*<\[]", s) and "{" not in s and s.lower() not in GENERIC_SEG and len(s) >= 3]
        if not meaningful:
            return -1, -1, [], []
        parts = []
        for s in segs:
            if re.match(r"^[:{*<\[]", s) or "{" in s or "<" in s:
                parts.append(r"(?:[^/'\"`\s?#]+|\$\{[^}]*\}|%s|\{[^}]*\})")
            else:
                parts.append(re.escape(s))
        full_rx = re.compile(r"(?<![\w.])/" + "/".join(parts) + r"/?(?=['\"`?\s#)]|$)")
        prefix_rx = None
        if len(static) >= 2 and [s for s in static if s.lower() not in GENERIC_SEG]:
            prefix_rx = re.compile(r"(?<![\w.])/" + "/".join(re.escape(s) for s in static) + r"(?=[/'\"`?\s#)]|$)")
        n_prod = n_test = n_prefix = 0; ex = []; pex = []
        for f, t in self.texts.items():
            if f == e["file"]:
                continue
            for i, line in enumerate(t.split("\n"), 1):
                if full_rx.search(line):
                    if is_test(f): n_test += 1
                    else: n_prod += 1
                    if len(ex) < 3: ex.append(f"{f}:{i}")
                elif prefix_rx and prefix_rx.search(line):
                    n_prefix += 1
                    if len(pex) < 3: pex.append(f"{f}:{i}")
            if n_prod + n_test > 60:
                break
        return n_prod, n_test, ex, (n_prefix, pex)

    def run(self):
        for f in self.files:
            t = read_text(self.root, f)
            if t is None:
                continue
            self.texts[f] = t
            if is_test(f):
                continue
            if f.endswith(JS_EXT):
                self.scan_js(f, t); self.scan_next(f, t)
            elif f.endswith(".py"):
                self.scan_py(f, t)
            elif f.endswith(".rb"):
                self.scan_rails(f, t)
            elif f.endswith(".go"):
                self.scan_go(f, t)
            elif f.endswith((".java", ".kt", ".cs")):
                self.scan_jvm_dotnet(f, t)
        self.apply_mounts()
        seen, uniq = set(), []
        for e in self.eps:
            k = (e["file"], e["line"], e["method"], e["path"])
            if k not in seen:
                seen.add(k); uniq.append(e)
        self.eps = uniq
        for e in self.eps:
            p, t, ex, (np_, pex) = self.count_refs(e)
            e["references_prod"], e["references_test"], e["reference_examples"] = p, t, ex
            e["references"] = -1 if p == -1 else p + t
            e["prefix_references"], e["prefix_reference_examples"] = np_, pex
            e.pop("router_var", None)
        return self


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="."); ap.add_argument("--out", default=None); ap.add_argument("--exclude", nargs="*", default=[])
    a = ap.parse_args()
    root = os.path.abspath(a.repo)
    s = Scan(root, list_files(root, a.exclude)).run()
    eps = s.eps
    frameworks = sorted({e["framework"] for e in eps})
    summary = {"total": len(eps),
               "by_auth": {k: sum(1 for e in eps if e["auth"] == k) for k in ("inline", "router", "expected-public", "public-explicit", "none-seen", "unknown")},
               "global_auth_evidence": len(s.globals),
               "no_references": sum(1 for e in eps if e["references"] == 0),
               "no_references_even_by_prefix": sum(1 for e in eps if e["references"] == 0 and e["prefix_references"] == 0),
               "unverifiable_references": sum(1 for e in eps if e["references"] == -1),
               "mounts_resolved": sum(1 for m in s.mounts if m.get("target")), "mounts_total": len(s.mounts)}
    order = {"none-seen": 0, "unknown": 1, "router": 2, "inline": 3, "public-explicit": 4, "expected-public": 5}
    result = {"frameworks": frameworks, "summary": summary, "global_auth": s.globals,
              "mounts": [{k: v for k, v in m.items()} for m in s.mounts],
              "endpoints": sorted(eps, key=lambda e: (order.get(e["auth"], 9), e["path"]))}
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "endpoints.json"), "w") as fh:
            json.dump(result, fh, indent=1)
    print(f"endpoints: {summary['total']} across {', '.join(frameworks) or 'no framework detected'}; auth: {summary['by_auth']}; "
          f"global auth evidence: {len(s.globals)}; mounts resolved {summary['mounts_resolved']}/{summary['mounts_total']}; "
          f"no references: {summary['no_references']} (none even by prefix: {summary['no_references_even_by_prefix']})")
    for e in result["endpoints"]:
        flag = "NONE-SEEN" if e["auth"] == "none-seen" else ("no-refs  " if e["references"] == 0 else "         ")
        print(f"  {flag} {e['auth']:15} {e['method']:7} {e['path']:42} {e['file']}:{e['line']}  refs={e['references_prod']}+{e['references_test']}t prefix={e['prefix_references']}")


if __name__ == "__main__":
    main()
