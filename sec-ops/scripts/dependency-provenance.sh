#!/usr/bin/env bash
# sec-ops Q1e: who maintains the packages this code depends on, and does anyone else use them?
#
#   scripts/dependency-provenance.sh [--repo <path> ...] [--out <dir>] [--roster roster.csv] \
#       [--threshold 1000] [--all] [--gh-org <org>]
#
# For every direct dependency in every package.json / requirements*.txt / pyproject.toml (or every
# package in the lockfile with --all), asks the public registry — read-only, no auth:
#   npm:  registry.npmjs.org/<pkg> (maintainers, repository, last publish, deprecated)
#         api.npmjs.org/downloads/point/last-week/<pkg>
#   PyPI: pypi.org/pypi/<pkg>/json (author/maintainer, project urls, last release)
#         pypistats.org/api/packages/<pkg>/recent (last_week)
# and flags:
#   LOW-VOLUME            weekly downloads < --threshold (default 1000) — few other eyes on it
#   EMPLOYEE-MAINTAINED   a maintainer's npm/PyPI username or email, or the repository's GitHub owner,
#                         matches someone on the roster (current or former) — by email, github login,
#                         or alias. The user's exact case: "an employee maintains an npm module basically
#                         only the company uses" is LOW-VOLUME + EMPLOYEE-MAINTAINED.
#   PERSONAL-REPO         repository URL is a personal GitHub *user* account (checked via gh api / api.github.com),
#                         not an organization; PERSONAL-REPO? when the type could not be determined
#   NOT-ON-PUBLIC-REGISTRY 404 on the public registry: a private/internal package — where is its source?
#   SINGLE-MAINTAINER, STALE (>2y since last publish), DEPRECATED, NO-REPO
# Writes deps-provenance.json and deps-provenance.md. Never writes to the repo or any registry.
set -uo pipefail
REPOS=(); OUT=""; ROSTER=""; TH=1000; ALL=0; GHORG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPOS+=("$2"); shift 2;;
    --out) OUT="$2"; shift 2;;
    --roster) ROSTER="$2"; shift 2;;
    --threshold) TH="$2"; shift 2;;
    --all) ALL=1; shift;;
    --gh-org) GHORG="$2"; shift 2;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ ${#REPOS[@]} -eq 0 ] && REPOS=(.)
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
python3 - "$OUT" "$ROSTER" "$TH" "$ALL" "$GHORG" "${REPOS[@]}" <<'PY'
import sys,os,re,json,csv,glob,datetime,urllib.request,urllib.error,concurrent.futures as cf
out,roster_path,TH,ALL,GHORG=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]=="1",sys.argv[5].lower(); repos=sys.argv[6:]
# ---- roster identities
ids=set(); people={}
if roster_path and os.path.exists(roster_path):
    for r in csv.DictReader(open(roster_path)):
        r={k.strip().lower():(v or "").strip() for k,v in r.items() if k}
        toks=[r.get("email",""),r.get("github",""),r.get("npm","")]+re.split(r"[;,\s]+",r.get("aliases",""))
        for t in toks:
            t=t.lower().strip()
            if t: ids.add(t); people[t]=f"{r.get('name') or r.get('email')} ({r.get('status','?')})"
        for t in [r.get("email","")]:
            if "@" in t: ids.add(t.split("@")[0].lower()); people[t.split("@")[0].lower()]=people[t.lower()]
def on_roster(*cands):
    for c in cands:
        c=(c or "").lower().strip()
        if c and c in ids: return people[c]
    return None
# ---- collect deps
deps={}  # (eco,name) -> set(where)
SKIP_DIRS=("node_modules","/.git/","/vendor/","/.venv/","/site-packages/","/dist/","/build/")
for r in repos:
    r=os.path.abspath(r)
    for dp,dn,fn in os.walk(r):
        dn[:]=[d for d in dn if d not in("node_modules",".git","vendor",".venv","dist","build",".next","site-packages")]
        for f in fn:
            p=os.path.join(dp,f); rel=os.path.relpath(p,r); where=f"{os.path.basename(r)}:{rel}"
            if f=="package.json":
                try: pj=json.load(open(p))
                except Exception: continue
                for k in ("dependencies","devDependencies","optionalDependencies","peerDependencies"):
                    for n,v in (pj.get(k) or {}).items():
                        if isinstance(v,str) and (v.startswith(("git+","github:","http","file:","link:","workspace:")) or "/" in v and not v.startswith("@")): deps.setdefault(("npm",n),set()).add(where+f" [spec {v[:60]}]")
                        else: deps.setdefault(("npm",n),set()).add(where)
            elif ALL and f in("package-lock.json",):
                try: lk=json.load(open(p))
                except Exception: continue
                for k in (lk.get("packages") or {}):
                    if k.startswith("node_modules/"): deps.setdefault(("npm",k.split("node_modules/")[-1]),set()).add(where+" [lock]")
            elif ALL and f in("yarn.lock","pnpm-lock.yaml"):
                for m in re.findall(r'(?m)^"?((?:@[a-z0-9._-]+/)?[a-z0-9._-]+)@',open(p,errors="replace").read()): deps.setdefault(("npm",m),set()).add(where+" [lock]")
            elif re.match(r"requirements.*\.txt$",f):
                for l in open(p,errors="replace"):
                    l=l.split("#")[0].strip()
                    if not l or l.startswith(("-","git+","http")): 
                        if l.startswith(("git+","http")): deps.setdefault(("pypi",re.sub(r".*/([^/@#.]+).*",r"\1",l)),set()).add(where+f" [spec {l[:60]}]")
                        continue
                    n=re.split(r"[<>=!~\[; ]",l)[0].strip().lower()
                    if n: deps.setdefault(("pypi",n),set()).add(where)
            elif f=="pyproject.toml":
                t=open(p,errors="replace").read()
                for sec in re.findall(r'(?s)dependencies\s*=\s*\[(.*?)\]',t)+re.findall(r'(?s)\[tool\.poetry\.dependencies\](.*?)(?:\n\[|\Z)',t):
                    for m in re.findall(r'["\']?([A-Za-z0-9_.-]+)["\']?\s*[=<>!~\[;"\']',sec): 
                        if m.lower() not in("python",): deps.setdefault(("pypi",m.lower()),set()).add(where)
print(f"{len(deps)} distinct dependencies ({sum(1 for e,_ in deps if e=='npm')} npm, {sum(1 for e,_ in deps if e=='pypi')} pypi){' incl. lockfile' if ALL else ' (direct only; --all for lockfiles)'}")
def get(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers={"User-Agent":"sec-ops-audit (read-only)"}),timeout=20) as r: return json.load(r)
    except urllib.error.HTTPError as e: return {"_error":f"http {e.code}"}
    except Exception as e: return {"_error":str(e)[:80]}
def gh_owner(url):
    m=re.search(r"github\.com[:/]([A-Za-z0-9_.-]+)/",url or ""); return m.group(1).lower() if m else None
now=datetime.datetime.now(datetime.timezone.utc)
import shutil,subprocess,functools
@functools.lru_cache(maxsize=None)
def owner_type(owner):
    """GitHub account type via authenticated gh (5000/h) if available; None if unknown."""
    if shutil.which("gh"):
        p=subprocess.run(["gh","api",f"users/{owner}","--jq",".type"],capture_output=True,text=True)
        if p.returncode==0 and p.stdout.strip() in("User","Organization"): return p.stdout.strip()
    r=get(f"https://api.github.com/users/{owner}")
    return r.get("type") if r.get("type") in("User","Organization") else None
def probe(key):
    eco,name=key; d={"ecosystem":eco,"name":name,"where":sorted(deps[key])[:6]}
    if eco=="npm":
        m=get(f"https://registry.npmjs.org/{name}")
        if "_error" in m:
            d["error"]=m["_error"]
            if "404" in m["_error"]: d["flags"]=["NOT-ON-PUBLIC-REGISTRY"]; d["severity"]="MEDIUM"; d["note"]="private/internal or unpublished package — find its source repo and who can publish it (Q1a/Q1e)"
            return d
        latest=(m.get("dist-tags") or {}).get("latest"); v=(m.get("versions") or {}).get(latest,{})
        d.update(version=latest,maintainers=[{"name":x.get("name"),"email":x.get("email")} for x in m.get("maintainers",[])],repository=(m.get("repository") or {}).get("url") if isinstance(m.get("repository"),dict) else m.get("repository"),last_publish=(m.get("time") or {}).get(latest),deprecated=bool(v.get("deprecated")),license=m.get("license") if isinstance(m.get("license"),str) else None)
        dl=get(f"https://api.npmjs.org/downloads/point/last-week/{name}"); d["weekly_downloads"]=dl.get("downloads")
    else:
        m=get(f"https://pypi.org/pypi/{name}/json")
        if "_error" in m:
            d["error"]=m["_error"]
            if "404" in m["_error"]: d["flags"]=["NOT-ON-PUBLIC-REGISTRY"]; d["severity"]="MEDIUM"; d["note"]="private index or unpublished package — find its source repo and who can publish it (Q1a/Q1e)"
            return d
        info=m.get("info",{}); urls=info.get("project_urls") or {}
        rel=m.get("releases",{}).get(info.get("version"),[]); lp=max([x.get("upload_time_iso_8601","") for x in rel] or [""])
        d.update(version=info.get("version"),maintainers=[{"name":info.get("author"),"email":info.get("author_email")},{"name":info.get("maintainer"),"email":info.get("maintainer_email")}],repository=next((u for u in list(urls.values())+[info.get("home_page")] if u and "github.com" in u),info.get("home_page")),last_publish=lp or None,deprecated=False,license=(info.get("license") or "")[:40])
        d["maintainers"]=[x for x in d["maintainers"] if x.get("name") or x.get("email")]
        dl=get(f"https://pypistats.org/api/packages/{name}/recent"); d["weekly_downloads"]=(dl.get("data") or {}).get("last_week")
    flags=[]
    wd=d.get("weekly_downloads")
    if wd is not None and wd<TH: flags.append("LOW-VOLUME")
    owner=gh_owner(d.get("repository")); d["repo_owner"]=owner
    who=None
    for mt in d.get("maintainers",[]): who=who or on_roster(mt.get("name"),mt.get("email"),(mt.get("email") or "").split("@")[0])
    who=who or (on_roster(owner) if owner else None)
    if who: flags.append("EMPLOYEE-MAINTAINED"); d["roster_match"]=who
    if not d.get("repository"): flags.append("NO-REPO")
    elif owner and GHORG and owner!=GHORG:
        t=owner_type(owner)
        if t=="User": flags.append("PERSONAL-REPO")
        elif t is None: flags.append("PERSONAL-REPO?")
    if len(d.get("maintainers",[]))==1: flags.append("SINGLE-MAINTAINER")
    lp=d.get("last_publish")
    try:
        if lp and (now-datetime.datetime.fromisoformat(lp.replace("Z","+00:00"))).days>730: flags.append("STALE")
    except Exception: pass
    if d.get("deprecated"): flags.append("DEPRECATED")
    d["flags"]=flags
    d["severity"]="HIGH" if ("EMPLOYEE-MAINTAINED" in flags and "LOW-VOLUME" in flags) else ("MEDIUM" if "EMPLOYEE-MAINTAINED" in flags or ("LOW-VOLUME" in flags and ("PERSONAL-REPO" in flags or "PERSONAL-REPO?" in flags or "SINGLE-MAINTAINER" in flags or "NO-REPO" in flags)) else ("LOW" if flags else "OK"))
    return d
with cf.ThreadPoolExecutor(8) as ex: results=list(ex.map(probe,sorted(deps)))
results.sort(key=lambda d:({"HIGH":0,"MEDIUM":1,"LOW":2,"OK":3}.get(d.get("severity","OK"),3),d.get("weekly_downloads") or 0))
json.dump({"collected":now.strftime("%Y-%m-%dT%H:%M:%SZ"),"threshold":TH,"gh_org":GHORG,"roster_loaded":bool(ids),"count":len(results),"deps":results},open(f"{out}/deps-provenance.json","w"),indent=1)
L=[f"# Dependency provenance — {now.date()}\n",f"{len(results)} dependencies from {len(repos)} repo(s); low-volume threshold {TH}/week; roster {'loaded' if ids else 'NOT loaded (--roster to detect employee-maintained)'}; company GitHub org: {GHORG or '(not given, --gh-org)'}\n",
   "**HIGH** = low-volume *and* maintained by someone on the roster: the company is the only real user of a package one of its own people controls — when they leave, or their npm account is phished, production takes whatever the next `npm install` gets. Fix: vendor it into the monorepo, or move the package under the company's npm org/GitHub org with 2FA-required publishing and at least two maintainers.\n",
   "| Sev | Eco | Package | Weekly DL | Maintainers | Repo owner | Roster match | Flags | Used in |","|---|---|---|---|---|---|---|---|---|"]
for d in results:
    if d.get("severity","OK")=="OK" and not d.get("error"): continue
    L.append(f"| {d.get('severity','?')} | {d['ecosystem']} | `{d['name']}` | {d.get('weekly_downloads') if d.get('weekly_downloads') is not None else d.get('error','?')} | {', '.join(str(m.get('name') or m.get('email')) for m in d.get('maintainers',[])[:3])} | {d.get('repo_owner') or ''} | {d.get('roster_match') or ''} | {' '.join(d.get('flags',[]))} | {'; '.join(w.split(':',1)[1] for w in d['where'][:2])} |")
counts={}
for d in results: counts[d.get("severity","OK")]=counts.get(d.get("severity","OK"),0)+1
L.append(f"\n**Counts:** {counts}. OK rows omitted; full data in `deps-provenance.json`.")
open(f"{out}/deps-provenance.md","w").write("\n".join(L)+"\n")
print(f"severity counts: {counts} → {out}/deps-provenance.md")
for d in results:
    if d.get("severity") in("HIGH","MEDIUM"): print(f"  {d['severity']:<6} {d['ecosystem']:<4} {d['name']:<40} dl/wk={d.get('weekly_downloads')}  {' '.join(d['flags'])}  {d.get('roster_match') or ''}")
PY
