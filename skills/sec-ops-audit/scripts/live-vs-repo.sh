#!/usr/bin/env bash
# sec-ops Q1: reconcile what is actually running against what is in the repo.
#
#   scripts/live-vs-repo.sh --host app.company.com [--host api.company.com ...] \
#       [--repo <path> ...] [--domain company.com ...] [--aws-profile <p> [--region <r>]] [--out <dir>] [--bundles 6]
#   --domain: the company's domain(s); API hosts the bundles call on other domains are classed as
#             THIRD-PARTY SERVICE (a vendor to list as a system) rather than company infra. Defaults to
#             the registrable domains of the --host values.
#
# Three read-only inventories, then a heuristic match, then CODE-RECONCILIATION.md for the
# model to reason over (the model makes the call; this script gathers and pre-matches):
#   live-<host>.json          what the browser would see: headers (server, x-vercel-id, cf-ray, x-powered-by),
#                             <meta generator>, framework fingerprint (Next/Vite/Nuxt/CRA/Angular/Webflow/
#                             Squarespace/Wix/Framer/WordPress/Shopify/Bubble/...), first- and third-party
#                             script hosts, API hostnames + /api paths + NEXT_PUBLIC_/VITE_ var names pulled
#                             out of up to --bundles first-party JS bundles, robots/sitemap paths, and whether
#                             /api/health, /openapi.json, /graphql, /.well-known answer.
#   repo-components-<name>.json  every deployable unit in each --repo: package.json dirs with framework guess,
#                             Python/Go/Ruby/Rust/Java apps, Dockerfiles, serverless/SAM/CDK/terraform
#                             functions, workflow/pipeline definitions (Airflow DAGs, dbt, Dagster, Prefect,
#                             Glue scripts, Step Functions ASL), cron/CI schedules.
#   aws-deployed-units.json   every place code runs in the account: Lambda (handler, runtime, lastModified),
#                             ECS services + images, EventBridge rules + targets (schedules = pipelines),
#                             Glue jobs + script locations, Step Functions, Batch job defs, App Runner,
#                             Amplify (repo), Elastic Beanstalk, CloudFront distributions + origins,
#                             S3 website buckets behind them, MWAA, SageMaker pipelines, DMS tasks,
#                             Firehose, AppFlow, CodeBuild/CodePipeline sources, Lightsail.
#   code-reconciliation.json / CODE-RECONCILIATION.md   where each host (and each API host the bundles call)
#                             physically runs — IP owner → provider → is that provider's account in the
#                             ownership inventory? flags residential-ISP IPs, ngrok/Cloudflare tunnels and
#                             dynamic DNS (someone's machine) and UNACCOUNTED providers (Q3) — and
#                             each live host and each deployed unit → the repo
#                             component it maps to (framework match, hostnames/paths/var names found in the
#                             repo via git grep, function names/handlers/images/script names found) or
#                             "NO MATCH" — which is the Q1 finding.
# Everything is GET/list/describe. Bundles are fetched to a temp dir under --out and grepped, never executed.
set -uo pipefail
export AWS_PAGER=""
HOSTS=(); REPOS=(); DOMAINS=(); AWSP=""; REGION=""; OUT=""; NB=6
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOSTS+=("$2"); shift 2;;
    --repo) REPOS+=("$2"); shift 2;;
    --domain) DOMAINS+=("$2"); shift 2;;
    --aws-profile) AWSP="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --bundles) NB="$2"; shift 2;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ ${#REPOS[@]} -eq 0 ] && REPOS=(.)
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
mkdir -p "$OUT/bundles"; export OUT NB; export COMPANY_DOMAINS="${DOMAINS[*]+"${DOMAINS[*]}"}"
echo "out=$OUT hosts=${#HOSTS[@]} repos=${REPOS[*]} aws=${AWSP:-none}"

# ---------------- live hosts ----------------
for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
  echo "== live: $h =="
  python3 - "$h" <<'PY'
import sys,json,re,os,subprocess,urllib.parse,datetime
h=sys.argv[1]; out=os.environ["OUT"]; NB=int(os.environ["NB"])
def curl(url,maxbytes=3_000_000,head=False):
    cmd=["curl","-sSL","-m","25","--max-filesize",str(maxbytes),"-A","Mozilla/5.0 (sec-ops audit; read-only)","-D","-",url]
    if head: cmd.insert(1,"-I")
    p=subprocess.run(cmd,capture_output=True)   # bytes: text=True would turn \r\n into \n and break the header/body split
    raw=p.stdout.decode("utf-8","replace"); parts=raw.split("\r\n\r\n")
    hdrs={}; body=""
    for i,part in enumerate(parts):
        if part.startswith("HTTP/"):
            for l in part.splitlines()[1:]:
                if ":" in l: k,v=l.split(":",1); hdrs[k.strip().lower()]=v.strip()
        else: body="\r\n\r\n".join(parts[i:]); break
    return hdrs,body,p.returncode
base=f"https://{h}"; hdrs,body,rc=curl(base)
if rc and not body: base=f"http://{h}"; hdrs,body,rc=curl(base)
info={"host":h,"collected":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"reachable":bool(body),"headers":{k:hdrs[k] for k in ("server","x-powered-by","x-vercel-id","x-vercel-cache","cf-ray","via","x-amz-cf-id","x-amz-cf-pop","x-render-origin-server","fly-request-id","x-github-request-id","x-netlify-id","x-nf-request-id","x-served-by","x-generator","x-drupal-cache","x-shopify-stage","x-wix-request-id","x-framer-app","x-heroku-dynos-in-use","strict-transport-security") if k in hdrs}}
low=body.lower()
gen=re.search(r'<meta[^>]+name=["\']generator["\'][^>]+content=["\']([^"\']+)',body,re.I); info["generator"]=gen.group(1) if gen else None
fp=[]
for k,v in {"/_next/":"Next.js","__next_data__":"Next.js","__nuxt":"Nuxt","/assets/index-":"Vite","/static/js/main.":"Create React App","ng-version":"Angular","data-reactroot":"React","__sveltekit":"SvelteKit","_astro/":"Astro","gatsby":"Gatsby","__remixcontext":"Remix","wp-content":"WordPress","cdn.shopify.com":"Shopify","website-files.com":"Webflow","squarespace":"Squarespace","wixstatic":"Wix","framerusercontent":"Framer","bubble.io":"Bubble","webflow":"Webflow","hubspot":"HubSpot CMS","ghost":"Ghost","docusaurus":"Docusaurus","mkdocs":"MkDocs","gitbook":"GitBook","streamlit":"Streamlit","gradio":"Gradio","retool":"Retool","softr":"Softr","carrd.co":"Carrd","notion.site":"Notion","readme.io":"ReadMe","x-powered-by:express":"Express","phoenix":"Phoenix","rails-ujs":"Rails","csrfmiddlewaretoken":"Django","laravel":"Laravel"}.items():
    if k in low: fp.append(v)
xp=info["headers"].get("x-powered-by","").lower()
for k,v in {"express":"Express","next":"Next.js","php":"PHP","asp.net":"ASP.NET","phoenix":"Phoenix"}.items():
    if k in xp: fp.append(v)
if "x-vercel-id" in info["headers"]: fp.append("hosted:Vercel")
if "cf-ray" in info["headers"]: fp.append("via:Cloudflare")
if "x-amz-cf-id" in info["headers"]: fp.append("hosted:CloudFront")
if "x-render-origin-server" in info["headers"]: fp.append("hosted:Render")
if "fly-request-id" in info["headers"]: fp.append("hosted:Fly")
if "x-nf-request-id" in info["headers"] or "x-netlify-id" in info["headers"]: fp.append("hosted:Netlify")
if "x-github-request-id" in info["headers"]: fp.append("hosted:GitHub Pages")
info["fingerprint"]=sorted(set(fp))
nd=re.search(r'"buildId":"([^"]+)"',body); info["next_build_id"]=nd.group(1) if nd else None
srcs=re.findall(r'(?:src|href)=["\']([^"\']+\.(?:m?js|css)(?:\?[^"\']*)?)["\']',body,re.I)
def absu(u): return urllib.parse.urljoin(base+"/",u)
scripts=[absu(u) for u in srcs]
hosts=sorted({urllib.parse.urlparse(u).netloc for u in scripts if urllib.parse.urlparse(u).netloc})
first=[u for u in scripts if urllib.parse.urlparse(u).netloc in ("",h) or urllib.parse.urlparse(u).netloc.endswith("."+".".join(h.split(".")[-2:]))]
third=[x for x in hosts if not (x==h or x.endswith("."+".".join(h.split(".")[-2:])))]
info["asset_hosts_first_party"]=sorted({urllib.parse.urlparse(u).netloc for u in first}); info["asset_hosts_third_party"]=third
info["title"]=(re.search(r"<title[^>]*>([^<]{0,120})",body,re.I) or [None,None])[1]
# pull API hostnames, paths, public env names, SDK hosts out of the first N first-party JS bundles
api_hosts=set(); api_paths=set(); envnames=set(); sdks=set(); fetched=[]
sdk_pat={"sentry":"Sentry","posthog":"PostHog","segment":"Segment","amplitude":"Amplitude","mixpanel":"Mixpanel","intercom":"Intercom","stripe":"Stripe","firebase":"Firebase","supabase":"Supabase","clerk":"Clerk","auth0":"Auth0","cognito":"Cognito","amazonaws.com":"AWS SDK/API","googleapis":"Google APIs","hotjar":"Hotjar","fullstory":"FullStory","logrocket":"LogRocket","datadoghq":"Datadog RUM","launchdarkly":"LaunchDarkly","algolia":"Algolia","mapbox":"Mapbox","openai.com":"OpenAI (client-side!)","anthropic.com":"Anthropic (client-side!)"}
js=[u for u in first if re.search(r"\.m?js(\?|$)",u)][:NB]
for i,u in enumerate(js):
    hd,b,rc=curl(u,5_000_000)
    if not b: continue
    fn=f"{out}/bundles/{h}-{i}.js"; open(fn,"w",errors="replace").write(b); fetched.append({"url":u,"bytes":len(b),"file":fn})
    for m in re.findall(r'https?://([a-z0-9.-]+\.[a-z]{2,})(?::\d+)?/',b,re.I):
        m=m.lower()
        if m in (h,) or m.endswith(("w3.org","schema.org","googleapis.com","gstatic.com","mozilla.org","github.com","npmjs.com","unpkg.com","jsdelivr.net","reactjs.org","nextjs.org","vitejs.dev","webpack.js.org","facebook.github.io","fb.me","react.dev","babeljs.io","tc39.es","whatwg.org","w3c.github.io","stackoverflow.com","github.io","typescriptlang.org","zod.dev","radix-ui.com","tailwindcss.com","daringfireball.net","google.com","apple.com","microsoft.com","adobe.com","wikipedia.org","gnu.org","opensource.org","spec.commonmark.org","emojipedia.org","ietf.org","json.org")): continue
        api_hosts.add(m)
    for p in re.findall(r'["\'`](/(?:api|v\d|graphql|trpc|rpc|auth|webhooks?|ws|socket\.io)[A-Za-z0-9_/\-\.\$\{\}:]*)["\'`]',b): api_paths.add(p[:80])
    for e in re.findall(r'\b(NEXT_PUBLIC_[A-Z0-9_]+|VITE_[A-Z0-9_]+|REACT_APP_[A-Z0-9_]+|NUXT_PUBLIC_[A-Z0-9_]+|PUBLIC_[A-Z0-9_]{4,}|EXPO_PUBLIC_[A-Z0-9_]+)\b',b): envnames.add(e)
    bl=b.lower()
    for k,v in sdk_pat.items():
        if k in bl: sdks.add(v)
    for m in re.findall(r'(sk_live_[0-9a-zA-Z]{8}|AKIA[0-9A-Z]{4}|sk-[A-Za-z0-9]{6}|sk-ant-[A-Za-z0-9]{4}|xox[bp]-[0-9]{4})',b): sdks.add(f"SECRET-SHAPED STRING IN BUNDLE: {m}…")
info["bundles"]=fetched; info["api_hosts"]=sorted(api_hosts); info["api_paths"]=sorted(api_paths)[:80]; info["public_env_names"]=sorted(envnames); info["sdks"]=sorted(sdks)
probes={}; catchall=[]
for p in ("/robots.txt","/sitemap.xml","/api/health","/health","/healthz","/api","/openapi.json","/swagger.json","/docs","/graphql","/.well-known/security.txt","/api/auth/providers","/admin","/wp-login.php","/.env","/.git/HEAD"):
    hd,b,rc=curl(base+p,200_000)
    st=None
    pr=subprocess.run(["curl","-sSL","-m","15","-o","/dev/null","-w","%{http_code} %{content_type}",base+p],capture_output=True,text=True); st=pr.stdout.strip()
    if st and not st.startswith(("404","000","3")):
        html="text/html" in st
        if p in("/robots.txt","/sitemap.xml","/.well-known/security.txt") and not html: probes[p]=st[:60]
        elif p in("/docs","/admin","/wp-login.php") : probes[p]=st[:60]+("" if not html else " (html — could be SPA catch-all)")
        elif not html: probes[p]=st[:60]          # an API/health/openapi/.env/.git path answering with non-HTML is real
        else: catchall.append(p)
info["probes"]=probes; info["spa_catch_all_paths"]=catchall
rb,_,_=curl(base+"/robots.txt",100_000); info["robots_paths"]=re.findall(r"(?im)^(?:dis)?allow:\s*(\S+)",curl(base+"/robots.txt",100_000)[1])[:30]
json.dump(info,open(f"{out}/live-{h}.json","w"),indent=1)
print(f"  {'reachable' if info['reachable'] else 'UNREACHABLE'}  fingerprint={info['fingerprint']}  generator={info['generator']}")
print(f"  api hosts={info['api_hosts'][:6]}  paths={len(info['api_paths'])}  env names={info['public_env_names'][:5]}  sdks={info['sdks'][:6]}")
print(f"  probes answering: {list(probes)[:8]}  third-party asset hosts: {third[:6]}")
PY
done

# ---------------- repo components ----------------
for r in "${REPOS[@]}"; do
  [ -d "$r" ] || { echo "repo $r not found" >&2; continue; }
  echo "== repo: $r =="
  python3 - "$r" <<'PY'
import sys,json,os,re,subprocess
r=os.path.abspath(sys.argv[1]); out=os.environ["OUT"]; name=os.path.basename(r)
def files():
    p=subprocess.run(["git","-C",r,"ls-files"],capture_output=True,text=True)
    if p.returncode==0: return p.stdout.splitlines()
    acc=[]
    for dp,dn,fn in os.walk(r):
        dn[:]=[d for d in dn if d not in ("node_modules",".git","vendor",".venv","dist","build",".next")]
        acc+=[os.path.relpath(os.path.join(dp,f),r) for f in fn]
    return acc
F=files(); comps=[]; pipelines=[]; iac=[]
FW={"next":"Next.js","react":"React","vue":"Vue","nuxt":"Nuxt","svelte":"Svelte","@sveltejs/kit":"SvelteKit","astro":"Astro","gatsby":"Gatsby","@remix-run/react":"Remix","@angular/core":"Angular","vite":"Vite","react-native":"React Native","expo":"Expo","express":"Express","fastify":"Fastify","@nestjs/core":"NestJS","koa":"Koa","hono":"Hono","@hapi/hapi":"Hapi","apollo-server":"Apollo","graphql-yoga":"GraphQL Yoga","@trpc/server":"tRPC","prisma":"Prisma","drizzle-orm":"Drizzle","mongoose":"Mongoose","bullmq":"BullMQ (worker)","agenda":"Agenda (worker)","node-cron":"node-cron (scheduled)","electron":"Electron","puppeteer":"Puppeteer","playwright":"Playwright"}
PYFW={"fastapi":"FastAPI","flask":"Flask","django":"Django","starlette":"Starlette","celery":"Celery (worker)","airflow":"Airflow","apache-airflow":"Airflow","dagster":"Dagster","prefect":"Prefect","dbt-core":"dbt","dbt":"dbt","luigi":"Luigi","scrapy":"Scrapy","streamlit":"Streamlit","gradio":"Gradio","pyspark":"Spark","awsglue":"Glue","boto3":"boto3","sqlalchemy":"SQLAlchemy","pandas":"pandas","torch":"PyTorch","tensorflow":"TensorFlow","langchain":"LangChain","openai":"OpenAI","anthropic":"Anthropic"}
for f in F:
    d=os.path.dirname(f); b=os.path.basename(f)
    if b=="package.json" and "node_modules" not in f:
        try: pj=json.load(open(os.path.join(r,f)))
        except Exception: continue
        deps={**pj.get("dependencies",{}),**pj.get("devDependencies",{})}
        fw=sorted({v for k,v in FW.items() if k in deps}); kind="frontend" if any(x in fw for x in ("Next.js","Vue","Nuxt","Svelte","SvelteKit","Astro","Gatsby","Remix","Angular","Vite","React")) and not any(x in fw for x in ("Express","Fastify","NestJS","Koa","Hono","Hapi")) else ("backend" if any(x in fw for x in ("Express","Fastify","NestJS","Koa","Hono","Hapi","Apollo","GraphQL Yoga","tRPC")) else ("mobile" if any(x in fw for x in ("React Native","Expo")) else ("worker" if any("worker" in x or "scheduled" in x for x in fw) else "library/other")))
        if "Next.js" in fw and "backend" not in kind: kind="fullstack (Next.js)"
        comps.append({"path":d or ".","lang":"node","name":pj.get("name"),"kind":kind,"frameworks":fw,"scripts":list((pj.get("scripts") or {}).keys())[:12],"private":pj.get("private"),"workspaces":pj.get("workspaces")})
    if b in ("requirements.txt","pyproject.toml","Pipfile","setup.py") and "site-packages" not in f:
        try: txt=open(os.path.join(r,f),errors="replace").read().lower()
        except Exception: continue
        fw=sorted({v for k,v in PYFW.items() if re.search(r"(^|[\s\"'\[])"+re.escape(k)+r"([\s=<>\[\"',]|$)",txt,re.M)})
        kind="pipeline" if any(x in fw for x in ("Airflow","Dagster","Prefect","dbt","Luigi","Spark","Glue","Celery (worker)","Scrapy")) else ("backend" if any(x in fw for x in ("FastAPI","Flask","Django","Starlette")) else ("app" if any(x in fw for x in ("Streamlit","Gradio")) else "python/other"))
        comps.append({"path":d or ".","lang":"python","name":None,"kind":kind,"frameworks":fw,"file":b})
    if b=="go.mod": comps.append({"path":d or ".","lang":"go","kind":"go service","frameworks":[]})
    if b=="Gemfile": comps.append({"path":d or ".","lang":"ruby","kind":"ruby app","frameworks":["Rails"] if "rails" in open(os.path.join(r,f),errors="replace").read().lower() else []})
    if b=="Cargo.toml": comps.append({"path":d or ".","lang":"rust","kind":"rust","frameworks":[]})
    if b in ("pom.xml","build.gradle","build.gradle.kts"): comps.append({"path":d or ".","lang":"java","kind":"java/kotlin","frameworks":[]})
    if b.startswith("Dockerfile"): comps.append({"path":d or ".","lang":"docker","kind":"container image","frameworks":[],"file":b})
    if b in ("serverless.yml","serverless.yaml","template.yaml","template.yml","samconfig.toml","cdk.json","Pulumi.yaml","main.tf","fly.toml","render.yaml","vercel.json","netlify.toml","Procfile","app.yaml","amplify.yml","wrangler.toml","firebase.json","supabase/config.toml"): iac.append(f)
    if re.search(r"\.tf$",b): iac.append(f)
    if re.search(r"(dags?/.*\.py$|/dbt_project\.yml$|^dbt_project\.yml$|/models/.*\.sql$|\.asl\.json$|state[-_]?machine.*\.json$|glue.*\.py$|(etl|ingest|sync|export|import|backfill|migrat|batch|scrap|crawl)[a-z_-]*\.(py|ts|js|sql)$|pipeline.*\.(py|ya?ml|ts)$|prefect\.yaml$|dagster\.yaml$|/jobs?/.*\.(py|ts|js)$|/crons?/.*\.(py|ts|js|sh)$|/(workers?|tasks?|lambdas?|functions?)/.*\.(py|ts|js)$)",f,re.I) and "node_modules" not in f and ".github/workflows" not in f and "/test" not in f: pipelines.append(f)
sched=[]
for f in F:
    if f.startswith(".github/workflows/") or f in ("vercel.json","render.yaml","fly.toml","serverless.yml","template.yaml") or f.endswith((".tf",".yaml",".yml")) and "node_modules" not in f:
        try: t=open(os.path.join(r,f),errors="replace").read()
        except Exception: continue
        for m in re.findall(r"(cron\s*[:=(]\s*[\"']?[^\"'\n]{5,40}|rate\(\d+ \w+\)|schedule_expression\s*=\s*\"[^\"]+\"|schedule:\s*[\"'][^\"'\n]+)",t): sched.append({"file":f,"schedule":m.strip()[:60]})
# lambda handler / function names declared in IaC
fnames=set()
for f in iac:
    try: t=open(os.path.join(r,f),errors="replace").read()
    except Exception: continue
    fnames|=set(re.findall(r"(?im)^\s*([A-Za-z0-9_-]+):\s*\n\s*handler:",t)); fnames|=set(re.findall(r"FunctionName[\"']?\s*[:=]\s*[\"']([^\"']+)",t)); fnames|=set(re.findall(r"function_name\s*=\s*\"([^\"]+)\"",t))
comp={"repo":name,"path":r,"remote":subprocess.run(["git","-C",r,"remote","get-url","origin"],capture_output=True,text=True).stdout.strip(),"files":len(F),"components":comps,"iac":iac[:60],"pipeline_files":pipelines[:120],"schedules":sched[:60],"declared_function_names":sorted(fnames)[:100],
      "hostnames_in_repo":sorted({m.lower() for m in re.findall(r"https?://([a-z0-9-]+(?:\.[a-z0-9-]+)+)",subprocess.run(["git","-C",r,"grep","-hoiE","https?://[a-z0-9-]+(\\.[a-z0-9-]+)+","--",".",":!*.lock",":!package-lock.json",":!yarn.lock",":!pnpm-lock.yaml",":!*.min.js",":!*.svg",":!*.map"],capture_output=True,text=True).stdout,re.I) if not m.lower().endswith(("w3.org","schema.org","github.com","npmjs.org","npmjs.com","localhost","example.com","googleapis.com","gstatic.com","mozilla.org","nodejs.org","yarnpkg.com","docker.com","docker.io","microsoft.com","apple.com","google.com","amazon.com","wikipedia.org","unpkg.com","jsdelivr.net","typescriptlang.org","reactjs.org","nextjs.org","vitejs.dev","eslint.org","prettier.io","json-schema.org","openapis.org","swagger.io","apache.org","python.org","pypi.org","readthedocs.io","gnu.org","choosealicense.com","opensource.org","spdx.org","semver.org","keepachangelog.com","conventionalcommits.org","editorconfig.org","gitignore.io","shields.io","badge.fury.io","travis-ci.org","circleci.com","codecov.io","coveralls.io"))})[:200]}
json.dump(comp,open(f"{out}/repo-components-{name}.json","w"),indent=1)
kinds={}
for c in comps: kinds[c["kind"]]=kinds.get(c["kind"],0)+1
print(f"  {len(comps)} component(s): {kinds}")
for c in comps[:25]: print(f"    {c['path']:<40} {c['lang']:<7} {c['kind']:<22} {','.join(c.get('frameworks',[]))[:50]}")
print(f"  iac={len(iac)} pipeline-ish files={len(pipelines)} schedules={len(sched)} declared functions={len(fnames)} hostnames referenced={len(comp['hostnames_in_repo'])}")
PY
done

# ---------------- AWS deployed units ----------------
if [ -n "$AWSP" ]; then
  echo "== aws deployed units ($AWSP) =="
  A=(aws --profile "$AWSP" --output json); [ -n "$REGION" ] && A+=(--region "$REGION")
  "${A[@]}" sts get-caller-identity >/dev/null 2>&1 || { echo "  cannot authenticate with profile $AWSP" >&2; }
  python3 - "$AWSP" "$REGION" <<'PY'
import json,subprocess,sys,os
profile,region=sys.argv[1],sys.argv[2]; out=os.environ["OUT"]
def aws(*a):
    cmd=["aws","--profile",profile,"--output","json"]+(["--region",region] if region else [])+list(a)
    p=subprocess.run(cmd,capture_output=True,text=True)
    if p.returncode: return {"error":p.stderr.strip()[:200]}
    try: return json.loads(p.stdout) if p.stdout.strip() else {}
    except Exception: return {"raw":p.stdout[:200]}
U=[]
def unit(kind,name,**kw): U.append({"kind":kind,"name":name,**kw})
for f in aws("lambda","list-functions").get("Functions",[]): unit("lambda",f["FunctionName"],runtime=f.get("Runtime"),handler=f.get("Handler"),last_modified=f.get("LastModified"),code_size=f.get("CodeSize"),description=f.get("Description"),package=f.get("PackageType"),image=(f.get("ImageConfigResponse") or {}).get("ImageUri") if f.get("PackageType")=="Image" else None)
for r in aws("events","list-rules").get("Rules",[]):
    t=aws("events","list-targets-by-rule","--rule",r["Name"]).get("Targets",[])
    unit("eventbridge-rule",r["Name"],schedule=r.get("ScheduleExpression"),pattern=(r.get("EventPattern") or "")[:120],state=r.get("State"),targets=[{"arn":x.get("Arn"),"input":(x.get("Input") or "")[:80],"ecs":(x.get("EcsParameters") or {}).get("TaskDefinitionArn")} for x in t])
sch=aws("scheduler","list-schedules")
for s in sch.get("Schedules",[]) if isinstance(sch,dict) else []: unit("eventbridge-scheduler",s["Name"],schedule=s.get("ScheduleExpression"),target=(s.get("Target") or {}).get("Arn"),state=s.get("State"))
for c in aws("ecs","list-clusters").get("clusterArns",[]):
    for s in aws("ecs","list-services","--cluster",c).get("serviceArns",[]):
        d=aws("ecs","describe-services","--cluster",c,"--services",s).get("services",[{}])[0]
        td=aws("ecs","describe-task-definition","--task-definition",d.get("taskDefinition","")).get("taskDefinition",{})
        unit("ecs-service",d.get("serviceName"),cluster=c.split("/")[-1],desired=d.get("desiredCount"),images=[x.get("image") for x in td.get("containerDefinitions",[])],task_def=d.get("taskDefinition","").split("/")[-1])
for j in aws("glue","get-jobs").get("Jobs",[]): unit("glue-job",j["Name"],script=(j.get("Command") or {}).get("ScriptLocation"),last_modified=j.get("LastModifiedOn"),role=j.get("Role"))
for t in aws("glue","list-triggers").get("TriggerNames",[]): unit("glue-trigger",t)
for s in aws("stepfunctions","list-state-machines").get("stateMachines",[]): unit("step-function",s["name"],created=s.get("creationDate"))
for b in aws("batch","describe-job-definitions","--status","ACTIVE").get("jobDefinitions",[]): unit("batch-job-def",b["jobDefinitionName"],image=(b.get("containerProperties") or {}).get("image"))
for s in aws("apprunner","list-services").get("ServiceSummaryList",[]):
    d=aws("apprunner","describe-service","--service-arn",s["ServiceArn"]).get("Service",{}); src=d.get("SourceConfiguration",{})
    unit("apprunner",s["ServiceName"],repo=(src.get("CodeRepository") or {}).get("RepositoryUrl"),image=((src.get("ImageRepository") or {}).get("ImageIdentifier")))
for a in aws("amplify","list-apps").get("apps",[]): unit("amplify-app",a["name"],repo=a.get("repository"),domain=a.get("defaultDomain"),platform=a.get("platform"))
for e in aws("elasticbeanstalk","describe-environments").get("Environments",[]): unit("beanstalk-env",e["EnvironmentName"],app=e.get("ApplicationName"),cname=e.get("CNAME"),version=e.get("VersionLabel"))
cf=aws("cloudfront","list-distributions").get("DistributionList",{}).get("Items",[])
for d in cf: unit("cloudfront",d["Id"],aliases=d.get("Aliases",{}).get("Items",[]),origins=[o.get("DomainName") for o in d.get("Origins",{}).get("Items",[])],default_root=d.get("DefaultRootObject"),comment=d.get("Comment"))
origins={o for d in cf for o in [x.get("DomainName") for x in d.get("Origins",{}).get("Items",[])] if o and ".s3" in o}
for o in origins:
    b=o.split(".s3")[0]; w=aws("s3api","get-bucket-website","--bucket",b)
    unit("s3-site-bucket",b,website="error" not in w,index=(w.get("IndexDocument") or {}).get("Suffix"))
for e in aws("mwaa","list-environments").get("Environments",[]): unit("mwaa-airflow",e)
for p in aws("sagemaker","list-pipelines").get("PipelineSummaries",[]): unit("sagemaker-pipeline",p["PipelineName"],last_modified=p.get("LastModifiedTime"))
for t in aws("dms","describe-replication-tasks").get("ReplicationTasks",[]): unit("dms-task",t.get("ReplicationTaskIdentifier"),status=t.get("Status"))
for s in aws("firehose","list-delivery-streams").get("DeliveryStreamNames",[]): unit("firehose",s)
for f in aws("appflow","list-flows").get("flows",[]): unit("appflow",f["flowName"],source=f.get("sourceConnectorType"),dest=f.get("destinationConnectorType"))
for p in aws("codebuild","list-projects").get("projects",[]):
    d=aws("codebuild","batch-get-projects","--names",p).get("projects",[{}])[0]; unit("codebuild",p,source=(d.get("source") or {}).get("location"))
for p in aws("codepipeline","list-pipelines").get("pipelines",[]): unit("codepipeline",p["name"])
for i in aws("lightsail","get-instances").get("instances",[]): unit("lightsail-instance",i["name"],blueprint=i.get("blueprintName"))
for c in aws("lightsail","get-container-services").get("containerServices",[]): unit("lightsail-container",c["containerServiceName"],url=c.get("url"))
for i in aws("ec2","describe-instances","--filters","Name=instance-state-name,Values=running").get("Reservations",[]):
    for x in i.get("Instances",[]): unit("ec2",x["InstanceId"],name=next((t["Value"] for t in x.get("Tags",[]) if t["Key"]=="Name"),None),note="see on-box-secops.sh git-repos-on-disk for what runs here")
json.dump({"profile":profile,"region":region,"units":U},open(f"{out}/aws-deployed-units.json","w"),indent=1)
kinds={}
for u in U: kinds[u["kind"]]=kinds.get(u["kind"],0)+1
print(f"  {len(U)} deployed unit(s): {kinds}")
PY
fi

# ---------------- reconcile ----------------
echo "== reconcile =="
python3 - "${REPOS[@]}" <<'PY'
import json,glob,os,re,subprocess,sys,datetime
out=os.environ["OUT"]; repos=[os.path.abspath(r) for r in sys.argv[1:] if os.path.isdir(r)]
comps=[json.load(open(f)) for f in glob.glob(f"{out}/repo-components-*.json")]
lives=[json.load(open(f)) for f in glob.glob(f"{out}/live-*.json")]
try: units=json.load(open(f"{out}/aws-deployed-units.json"))["units"]
except Exception: units=[]
def grep(tok):
    """which repos mention this token (git grep -l, fixed string, case-insensitive)"""
    hits=[]
    if not tok or len(tok)<4: return hits
    for r in repos:
        p=subprocess.run(["git","-C",r,"grep","-lIiF","--",tok,"--",".",":!*.lock",":!package-lock.json",":!yarn.lock",":!pnpm-lock.yaml"],capture_output=True,text=True)
        if p.returncode==0 and p.stdout.strip(): hits.append((os.path.basename(r),len(p.stdout.splitlines())))
        elif p.returncode>1:  # not a git repo → plain grep
            q=subprocess.run(["grep","-rlIiF","--exclude-dir=node_modules","--exclude-dir=.git","--exclude=*.lock",tok,r],capture_output=True,text=True)
            if q.stdout.strip(): hits.append((os.path.basename(r),len(q.stdout.splitlines())))
    return hits
R={"collected":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"hosts":[],"units":[],"repo_components":[{"repo":c["repo"],"path":x["path"],"kind":x["kind"],"frameworks":x.get("frameworks",[]),"name":x.get("name")} for c in comps for x in c["components"]]}
allfw={fw for c in comps for x in c["components"] for fw in x.get("frameworks",[])}
kinds={x["kind"] for c in comps for x in c["components"]}
for L in lives:
    ev=[]; fp=[f for f in L.get("fingerprint",[]) if not f.startswith(("hosted:","via:"))]
    fwmatch=[f for f in fp if f in allfw or (f=="React" and any(k in allfw for k in ("Next.js","Vite","React")))]
    if fwmatch: ev.append(f"framework {fwmatch} present in repo")
    elif fp: ev.append(f"framework {fp} NOT found in any repo component")
    hn=grep(L["host"]); 
    if hn: ev.append(f"hostname referenced in repo {hn}")
    for a in L.get("api_hosts",[])[:8]:
        g=grep(a); ev.append(f"api host {a} → {'in repo '+str(g) if g else 'NOT in repo'}")
    pm=0
    for p in L.get("api_paths",[])[:12]:
        seg=re.sub(r"[\$\{\}:].*","",p).rstrip("/")
        if len(seg)>4 and grep(seg): pm+=1
    if L.get("api_paths"): ev.append(f"{pm}/{min(len(L['api_paths']),12)} API paths from bundles found in repo")
    em=sum(1 for e in L.get("public_env_names",[])[:10] if grep(e))
    if L.get("public_env_names"): ev.append(f"{em}/{min(len(L['public_env_names']),10)} public env var names found in repo")
    nb=L.get("next_build_id")
    if nb and grep(nb): ev.append("Next.js buildId found in repo (built artifacts committed)")
    site_builders={"Webflow","Squarespace","Wix","Framer","Bubble","Shopify","HubSpot CMS","Carrd","Notion","Softr","WordPress","GitBook","ReadMe","Retool"}
    sb=[f for f in fp if f in site_builders]
    score=("SITE-BUILDER" if sb else ("MATCH" if (fwmatch and (pm>0 or em>0)) or (pm>=2) or (em>=2) else ("WEAK" if fwmatch or hn or pm or em else ("UNREACHABLE" if not L.get("reachable") else "NO MATCH"))))
    R["hosts"].append({"host":L["host"],"verdict":score,"fingerprint":L.get("fingerprint"),"generator":L.get("generator"),"evidence":ev,"api_hosts":L.get("api_hosts"),"sdks":L.get("sdks"),"probes":L.get("probes")})
for u in units:
    toks=[]; k=u["kind"]
    if k=="lambda": toks=[u["name"],(u.get("handler") or "").split(".")[0].split("/")[-1],(u.get("image") or "").split("/")[-1].split(":")[0]]
    elif k=="ecs-service": toks=[u["name"]]+[(i or "").split("/")[-1].split(":")[0].split("@")[0] for i in u.get("images",[])]
    elif k=="glue-job": toks=[u["name"],os.path.basename(u.get("script") or "")]
    elif k in("step-function","batch-job-def","eventbridge-rule","eventbridge-scheduler","codebuild","codepipeline","sagemaker-pipeline","firehose","appflow","dms-task","glue-trigger","mwaa-airflow"): toks=[u["name"]]
    elif k=="cloudfront": toks=u.get("aliases",[])+[u.get("comment") or ""]
    elif k=="s3-site-bucket": toks=[u["name"]]
    elif k in("amplify-app","apprunner"): toks=[u["name"],u.get("repo") or ""]
    elif k=="beanstalk-env": toks=[u["name"],u.get("app") or ""]
    elif k in("ec2","lightsail-instance","lightsail-container"): toks=[u.get("name") or u["name"]]
    found={t:grep(t) for t in toks if t and len(t)>=4}
    hits={t:h for t,h in found.items() if h}
    verdict="MATCH" if hits else ("SEE-SSH-SWEEP" if k=="ec2" else ("CDN-ONLY" if k=="cloudfront" and not u.get("aliases") else "NO MATCH"))
    if k in("amplify-app","apprunner") and u.get("repo"): verdict+=" (deploys from "+u["repo"]+")"
    R["units"].append({**u,"verdict":verdict,"tokens_found":hits})
# ---- where does each host (and each API host the bundles call) physically run, and does the company own that account?
def dig(n,t):
    p=subprocess.run(["dig","+short","+time=4","+tries=1",t,n],capture_output=True,text=True); return [l.strip().rstrip(".") for l in p.stdout.splitlines() if l.strip()]
def whois_org(ip):
    try: w=subprocess.run(["whois",ip],capture_output=True,text=True,timeout=15).stdout
    except Exception: return None
    for k in ("OrgName","org-name","Organization","owner","descr","netname"):
        m=re.search(r"(?im)^%s\s*:\s*(.+)$" % k,w)
        if m: return m.group(1).strip()
    return None
PROV={"amazon":"AWS","cloudfront":"AWS","vercel":"Vercel","netlify":"Netlify","fly.io":"Fly","fly.dev":"Fly","onrender":"Render","render":"Render","heroku":"Heroku","railway":"Railway","cloudflare":"Cloudflare","google":"GCP","digitalocean":"DigitalOcean","hetzner":"Hetzner","ovh":"OVH","linode":"Linode","akamai":"Akamai","fastly":"Fastly","microsoft":"Azure","github":"GitHub Pages","webflow":"Webflow","squarespace":"Squarespace","wix":"Wix","shopify":"Shopify","framer":"Framer","contabo":"Contabo","oracle":"Oracle Cloud","scaleway":"Scaleway","vultr":"Vultr","upcloud":"UpCloud","ionos":"IONOS","godaddy":"GoDaddy hosting","hostinger":"Hostinger","namecheap":"Namecheap hosting","supabase":"Supabase","mongodb":"MongoDB Atlas","ngrok":"ngrok (tunnel to someone's machine!)","trycloudflare":"Cloudflare tunnel (to someone's machine!)","tailscale":"Tailscale funnel","duckdns":"DuckDNS (dynamic DNS — home server?)","no-ip":"No-IP (dynamic DNS — home server?)","dyndns":"DynDNS (home server?)"}
RESIDENTIAL=("comcast","xfinity","verizon","at&t","att-","spectrum","charter","cox ","centurylink","lumen","frontier","altice","optimum","rogers","bell canada","telus","shaw","bt-","british telecom","virgin media","sky uk","talktalk","vodafone","deutsche telekom","telekom","orange","sfr","free sas","bouygues","telefonica","movistar","kpn","ziggo","swisscom","telstra","optus","nbn","jio","airtel","bsnl","singtel","starhub","ntt","kddi","softbank","sk broadband","kt corp","turk telekom","claro","vivo","tim ","oi s.a","t-mobile","sprint","windstream","mediacom","suddenlink","wow!","rcn","astound","google fiber","starlink")
def provider_of(host):
    chain=dig(host,"CNAME"); ips=[x for x in dig(host,"A") if re.match(r"^\d+\.\d+\.\d+\.\d+$",x)]
    org=whois_org(ips[0]) if ips else None; blob=(" ".join(chain)+" "+(org or "")).lower()
    prov=next((v for k,v in PROV.items() if k in blob),None)
    kind="provider" if prov else ("RESIDENTIAL-ISP" if org and any(r in org.lower() for r in RESIDENTIAL) else ("unknown-org" if org else "unresolved"))
    return {"host":host,"cname":chain[:2],"ip":ips[:2],"ip_owner":org,"provider":prov or org,"kind":kind}
known_systems=set()
for f in glob.glob(f"{out}/ownership-*.json")+glob.glob(f"{out}/members-*.json"):
    try: known_systems.add(json.load(open(f)).get("system","").lower())
    except Exception: pass
SYS_ALIAS={"AWS":"aws","Vercel":"vercel","Netlify":"netlify","Fly":"fly","Render":"render","Heroku":"heroku","Railway":"railway","Cloudflare":"cloudflare","GCP":"gcp","DigitalOcean":"digitalocean","Hetzner":"hetzner","Supabase":"supabase","MongoDB Atlas":"atlas","Webflow":"webflow","Squarespace":"squarespace","Wix":"wix","Shopify":"shopify","Framer":"framer","GitHub Pages":"github","Azure":"azure","Linode":"linode","OVH":"ovh","Contabo":"contabo","Vultr":"vultr","Oracle Cloud":"oracle","Scaleway":"scaleway"}
def reg_domain(h):
    parts=h.lower().split("."); 
    if len(parts)>=3 and parts[-2] in("co","com","org","net","ac","gov","edu") and len(parts[-1])==2: return ".".join(parts[-3:])
    return ".".join(parts[-2:])
company={d.lower() for d in os.environ.get("COMPANY_DOMAINS","").split() if d} or {reg_domain(L["host"]) for L in lives}
PAAS_DEFAULT=("herokuapp.com","onrender.com","fly.dev","vercel.app","railway.app","netlify.app","amazonaws.com","cloudfront.net","azurewebsites.net","appspot.com","run.app","cloudfunctions.net","ngrok.io","ngrok.app","ngrok-free.app","trycloudflare.com","duckdns.org","no-ip.org","ddns.net","github.io","pages.dev","workers.dev","supabase.co","firebaseapp.com","web.app","glitch.me","replit.app","repl.co","deno.dev","koyeb.app","zeabur.app","up.railway.app","elasticbeanstalk.com","lightsail.aws","digitaloceanspaces.com","ondigitalocean.app","linodeusercontent.com","hetzner.cloud","your-server.de","clients.your-server.de")
hosts_to_check=sorted({L["host"] for L in lives}|{a for L in lives for a in L.get("api_hosts",[])[:10] if "." in a})
R["infra"]=[]
for h in hosts_to_check:
    i=provider_of(h); sysname=SYS_ALIAS.get(i["provider"] or "","")
    named=h in {L["host"] for L in lives}; rd=reg_domain(h)
    if not named and rd not in company and not h.endswith(PAAS_DEFAULT):
        i["verdict"]=f"THIRD-PARTY SERVICE ({rd}) called from the frontend — not company infra; add it to the system list if the company has an account there"; R["infra"].append(i); continue
    if i["kind"]=="RESIDENTIAL-ISP": i["verdict"]="PERSONAL/HOME SERVER? — residential ISP address"
    elif i["provider"] and any(t in (i["provider"] or "") for t in ("someone's machine","home server","tunnel","funnel")): i["verdict"]="TUNNEL/DYNAMIC-DNS — running on someone's machine"
    elif i["kind"]=="unresolved": i["verdict"]="unresolved (dead hostname or blocked)"
    elif not known_systems: i["verdict"]="provider identified — no ownership inventory in this dir yet to check the account against"
    elif sysname and sysname in known_systems: i["verdict"]="provider account is in the inventory"
    else: i["verdict"]=f"UNACCOUNTED PROVIDER — no {i['provider']} account in the system list: whose account is this host running in?"
    R["infra"].append(i)
json.dump(R,open(f"{out}/code-reconciliation.json","w"),indent=1)
L=[f"# Code reconciliation — live product and deployed compute vs. the repo(s) — {datetime.date.today()}\n",
   f"Repos: {', '.join(os.path.basename(r) for r in repos) or '(none given)'} · components found: {len(R['repo_components'])} · live hosts: {len(lives)} · AWS deployed units: {len(units)}\n",
   "Verdicts: **MATCH** the repo contains this (framework + paths/env names, or the unit's name/handler/image/script). **WEAK** something matches but not enough — read the evidence. **NO MATCH** nothing in any given repo accounts for it — this is the Q1 finding unless the user names another repo. **SITE-BUILDER** a hosted no-code site (Webflow/Squarespace/…): not code, but list it as a system and check who owns the account. **SEE-SSH-SWEEP** an EC2 box — `on-box-secops.sh` says what runs there.\n",
   "## Repo components\n","| Repo | Path | Kind | Frameworks |","|---|---|---|---|"]
for c in R["repo_components"]: L.append(f"| {c['repo']} | `{c['path']}` | {c['kind']} | {', '.join(c['frameworks'])} |")
kinds_present={c["kind"] for c in R["repo_components"]}
gaps=[]
if any(("Express" in c["frameworks"] or c["kind"]=="backend") for c in R["repo_components"]) and not any(c["kind"] in("frontend","fullstack (Next.js)","mobile") for c in R["repo_components"]): gaps.append("backend present, **no frontend/mobile component** in any repo — where does the UI live?")
if any(c["kind"] in("frontend","fullstack (Next.js)","mobile") for c in R["repo_components"]) and not any(c["kind"] in("backend","fullstack (Next.js)","go service","ruby app","java/kotlin","python/other") for c in R["repo_components"]) and any(h.get("api_hosts") for h in R["hosts"]): gaps.append("frontend present and it calls an API, **no backend component** in any repo — where does the API live?")
if any(u["kind"] in("glue-job","step-function","eventbridge-rule","eventbridge-scheduler","mwaa-airflow","sagemaker-pipeline","batch-job-def") for u in units) and not any(c["kind"]=="pipeline" for c in R["repo_components"]) and not any(c.get("pipeline_files") for c in comps): gaps.append("scheduled/pipeline compute exists in AWS, **no pipeline code** (DAGs, Glue scripts, jobs) in any repo")
L.append("\n## Structural gaps\n"); L+= [f"- {g}" for g in gaps] or ["- none detected structurally (still read the per-host and per-unit verdicts)"]
L.append("\n## Live hosts\n"); L.append("| Host | Verdict | Fingerprint | Evidence |"); L.append("|---|---|---|---|")
for h in R["hosts"]: L.append(f"| {h['host']} | **{h['verdict']}** | {', '.join(h['fingerprint'] or [])} {('/ '+h['generator']) if h.get('generator') else ''} | {'<br>'.join(h['evidence'])[:600]} |")
for h in R["hosts"]:
    if h.get("sdks"): L.append(f"- {h['host']} client-side SDKs/endpoints: {', '.join(h['sdks'])}")
    if h.get("probes"): L.append(f"- {h['host']} answering probes: {h['probes']}")
L.append("\n## AWS deployed units\n"); L.append("| Kind | Name | Verdict | Detail |"); L.append("|---|---|---|---|")
for u in sorted(R["units"],key=lambda x:(x["verdict"]!="NO MATCH",x["kind"])):
    det={k:v for k,v in u.items() if k not in("kind","name","verdict","tokens_found") and v}
    L.append(f"| {u['kind']} | {u['name']} | **{u['verdict']}** | {json.dumps(det,default=str)[:220]} |")
L.append("\n## Where each host physically runs (Q3: does the company own that account?)\n"); L.append("| Host | CNAME | IP | IP owner | Provider | Verdict |"); L.append("|---|---|---|---|---|---|")
for i in R["infra"]: L.append(f"| {i['host']} | {', '.join(i['cname'])} | {', '.join(i['ip'])} | {i.get('ip_owner') or ''} | {i.get('provider') or ''} | **{i['verdict']}** |")
bad_infra=[i for i in R["infra"] if i["verdict"].startswith(("PERSONAL","TUNNEL","UNACCOUNTED"))]
nm=[u for u in R["units"] if u["verdict"]=="NO MATCH"]; nh=[h for h in R["hosts"] if h["verdict"]=="NO MATCH"]
L.append(f"\n**Summary:** {len(nh)} live host(s) and {len(nm)} deployed unit(s) with NO MATCH in the given repos; {len(gaps)} structural gap(s); {len(bad_infra)} host(s) running somewhere the company may not own ({', '.join(i['host'] for i in bad_infra) or '-'}).")
open(f"{out}/CODE-RECONCILIATION.md","w").write("\n".join(L)+"\n")
print(f"  wrote {out}/CODE-RECONCILIATION.md — hosts NO MATCH: {len(nh)}  units NO MATCH: {len(nm)}  structural gaps: {len(gaps)}  hosts on unowned/unaccounted infra: {len(bad_infra)}")
for i in R["infra"]: print(f"  {i['host']:<36} → {str(i.get('provider') or i.get('ip_owner') or '?'):<28} {i['verdict'][:70]}")
for g in gaps: print(f"  GAP: {g}")
for h in R["hosts"]: print(f"  {h['host']:<36} {h['verdict']}")
PY
echo "done → $OUT"
