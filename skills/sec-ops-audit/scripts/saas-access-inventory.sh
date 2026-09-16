#!/usr/bin/env bash
# sec-ops: read-only member/ownership inventory across every system that has a CLI or API.
#
#   scripts/saas-access-inventory.sh --out <dir> [--aws-profile <p>] [--domain company.com]
#       [--vercel-team <slug>] [--gh-org <org>]
#
# Each collector runs only if its CLI is logged in or its token is in the environment; the rest
# are listed at the end with the screenshot to ask for. Every call is a GET/list/describe.
# Writes normalized members-<system>.json / ownership-<system>.json (schema: references/
# access-guide.md) plus raw per-system files. Re-running overwrites only the systems reached.
#
# Tokens (env):  VERCEL_TOKEN [VERCEL_TEAM_ID]  RENDER_API_KEY  NETLIFY_AUTH_TOKEN
#   CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID   SUPABASE_ACCESS_TOKEN   SLACK_TOKEN
#   GOOGLE_ADMIN_TOKEN (or `gam`)   SENTRY_TOKEN + SENTRY_ORG   DD_API_KEY + DD_APP_KEY [DD_SITE]
#   PAGERDUTY_TOKEN   LINEAR_API_KEY   NOTION_TOKEN   STRIPE_API_KEY (restricted, account:read)
#   SENDGRID_API_KEY   TAILSCALE_API_KEY + TAILSCALE_TAILNET
# CLIs (logged in): aws (--aws-profile)  gcloud  fly  heroku  atlas  op  npm  gam
set -uo pipefail
export AWS_PAGER=""
OUT=""; AWSP=""; DOMAIN=""; VTEAM="${VERCEL_TEAM_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --aws-profile) AWSP="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --vercel-team) VTEAM="$2"; shift 2;;
    --gh-org) shift 2;;   # accepted for symmetry; GitHub has its own script
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
mkdir -p "$OUT"; export OUT
NOW=$(date -u +%FT%TZ); export NOW
MANUAL=()
say(){ printf '  %s\n' "$*"; }
# norm <system> <source> <python-expr producing members list> reads raw JSON on stdin; writes members-<system>.json
norm(){ python3 -c '
import sys,json,os
system,source,code=sys.argv[1],sys.argv[2],sys.argv[3]
raw=sys.stdin.read(); 
try: data=json.loads(raw) if raw.strip() else None
except Exception: data={"raw":raw[:500]}
members=[]; notes=[]
try: members=eval(code,{"data":data,"json":json})
except Exception as e: notes.append(f"normalize error: {e}"); 
if isinstance(data,dict) and data.get("error"): notes.append(str(data["error"])[:300])
outdir=os.environ["OUT"]
json.dump({"system":system,"source":source,"collected":os.environ["NOW"],"members":members,"notes":notes},open("%s/members-%s.json" % (outdir,system),"w"),indent=1)
print(f"  members-{system}.json: {len(members)} identities" + (f"  ({notes[0]})" if notes else ""))' "$@"; }
own(){ python3 -c '
import sys,json,os
d=json.loads(sys.argv[1]); d.setdefault("source","api"); d.setdefault("notes",[])
outdir=os.environ["OUT"]; system=d["system"]
json.dump(d,open("%s/ownership-%s.json" % (outdir,system),"w"),indent=1); print("  ownership-%s.json written" % system)' "$1"; }
curlj(){ curl -sS -m 30 "$@" 2>&1 || echo '{"error":"curl failed"}'; }

# ---------------- AWS ----------------
if [ -n "$AWSP" ] && aws --profile "$AWSP" sts get-caller-identity >/dev/null 2>&1; then
  echo "== aws ($AWSP) =="
  A=(aws --profile "$AWSP" --output json)
  ACCT=$("${A[@]}" sts get-caller-identity --query Account --output text)
  "${A[@]}" iam generate-credential-report >/dev/null 2>&1; sleep 3
  "${A[@]}" iam get-credential-report --query Content --output text 2>/dev/null | base64 -d > "$OUT/aws-credential-report.csv" 2>/dev/null || echo "user" > "$OUT/aws-credential-report.csv"
  "${A[@]}" iam list-users > "$OUT/aws-iam-users.json" 2>/dev/null
  "${A[@]}" account get-contact-information > "$OUT/aws-account-contact.json" 2>/dev/null || echo '{"error":"account:GetContactInformation denied"}' > "$OUT/aws-account-contact.json"
  { for t in BILLING SECURITY OPERATIONS; do "${A[@]}" account get-alternate-contact --alternate-contact-type $t 2>/dev/null || echo "{\"AlternateContact\":{\"AlternateContactType\":\"$t\",\"missing\":true}}"; done; } | python3 -c 'import sys,json;dec=json.JSONDecoder();raw=sys.stdin.read();i=0;o=[]
while i<len(raw):
    while i<len(raw) and raw[i].isspace(): i+=1
    if i>=len(raw): break
    x,i=dec.raw_decode(raw,i);o.append(x)
print(json.dumps(o))' > "$OUT/aws-alternate-contacts.json"
  "${A[@]}" organizations describe-organization > "$OUT/aws-organization.json" 2>/dev/null || echo '{"error":"not in an organization or denied"}' > "$OUT/aws-organization.json"
  "${A[@]}" ec2 describe-key-pairs --query 'KeyPairs[].{Name:KeyName,Created:CreateTime,Fingerprint:KeyFingerprint}' > "$OUT/aws-keypairs.json" 2>/dev/null
  "${A[@]}" secretsmanager list-secrets --query 'SecretList[].{Name:Name,LastChanged:LastChangedDate,LastRotated:LastRotatedDate,LastAccessed:LastAccessedDate,Rotation:RotationEnabled}' > "$OUT/aws-secrets.json" 2>/dev/null
  "${A[@]}" iam list-roles --query 'Roles[].{Name:RoleName,Trust:AssumeRolePolicyDocument,LastUsed:RoleLastUsed.LastUsedDate}' 2>/dev/null | python3 -c '
import sys,json,re
acct=sys.argv[1]; roles=json.load(sys.stdin); out=[]
for r in roles:
    s=json.dumps(r["Trust"]); ext=sorted(set(re.findall(r"arn:aws:iam::(\d{12}):",s))-{acct}); fed=re.findall(r"(oidc-provider/[^\"]+|saml-provider/[^\"]+|accounts\.google\.com|cognito-identity\.amazonaws\.com)",s)
    if ext or fed or "\"AWS\": \"*\"" in s: out.append({"role":r["Name"],"external_accounts":ext,"federated":sorted(set(fed)),"wildcard":"\"AWS\": \"*\"" in s,"last_used":r.get("LastUsed")})
print(json.dumps(out,indent=1))' "$ACCT" > "$OUT/aws-external-trusts.json"
  SID=$("${A[@]}" sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null)
  if [ -n "$SID" ] && [ "$SID" != "None" ]; then "${A[@]}" identitystore list-users --identity-store-id "$SID" > "$OUT/aws-identitycenter-users.json" 2>/dev/null; else echo '[]' > "$OUT/aws-identitycenter-users.json"; fi
  python3 - "$OUT" "$ACCT" <<'PY' | sed 's/^/  /'
import csv,json,sys,os
out,acct=sys.argv[1],sys.argv[2]; members=[]
def load(n,d):
    try: return json.load(open(f"{out}/{n}"))
    except Exception: return d
for r in csv.DictReader(open(f"{out}/aws-credential-report.csv")):
    u=r.get("user"); 
    if not u: continue
    ka=[k for k in ("access_key_1_active","access_key_2_active") if r.get(k)=="true"]
    last=max([x for x in (r.get("password_last_used",""),r.get("access_key_1_last_used_date",""),r.get("access_key_2_last_used_date","")) if x and x not in ("N/A","no_information")] or [""])
    members.append({"id":u if u!="<root_account>" else "root","email":None,"name":u,"role":"owner" if u=="<root_account>" else "member","mfa":r.get("mfa_active")=="true",
        "last_active":last or None,"status":"active" if (r.get("password_enabled")=="true" or ka) else "no-credentials",
        "note":f"console={r.get('password_enabled')} active_keys={len(ka)} key1_rotated={r.get('access_key_1_last_rotated','')[:10]}"})
ic=load("aws-identitycenter-users.json",{}).get("Users",[]) if isinstance(load("aws-identitycenter-users.json",{}),dict) else []
for u in ic:
    em=next((e.get("Value") for e in u.get("Emails",[]) if e.get("Value")),None)
    members.append({"id":em or u.get("UserName"),"email":em,"name":(u.get("DisplayName")),"role":"member","mfa":None,"last_active":None,"status":"active","note":"IAM Identity Center"})
json.dump({"system":"aws","source":"api","collected":os.environ["NOW"],"account":acct,"members":members,"notes":["role=member for IAM users; check attached policies for AdministratorAccess (infra-audit digest lists it)"]},open(f"{out}/members-aws.json","w"),indent=1)
c=load("aws-account-contact.json",{}); c=c.get("ContactInformation",c); org=load("aws-organization.json",{}).get("Organization",{})
own={"system":"aws","account":acct,"display_name":c.get("FullName") or c.get("CompanyName"),"primary_email":None,"billing_email":None,"owner_identity":None,"source":"api",
     "notes":[f"contact company={c.get('CompanyName')} address={c.get('AddressLine1','')} {c.get('City','')} {c.get('CountryCode','')}".strip(),
              f"organization management account={org.get('MasterAccountId')} email={org.get('MasterAccountEmail')}" if org else "no organization (standalone account)",
              "root email is NOT readable via API — ask or screenshot Account settings; payment method is UI-only"]}
if org.get("MasterAccountEmail") and org.get("MasterAccountId")==acct: own["primary_email"]=org["MasterAccountEmail"]
alt=load("aws-alternate-contacts.json",[])
for a in alt:
    ac=a.get("AlternateContact",{}); own["notes"].append(f"alternate {ac.get('AlternateContactType')}: {ac.get('EmailAddress','MISSING')}")
    if ac.get("AlternateContactType")=="BILLING" and ac.get("EmailAddress"): own["billing_email"]=ac["EmailAddress"]
json.dump(own,open(f"{out}/ownership-aws.json","w"),indent=1)
print(f"members-aws.json: {len(members)} identities; ownership-aws.json; secrets={len(load('aws-secrets.json',[]))} keypairs={len(load('aws-keypairs.json',[]))} external-trust roles={len(load('aws-external-trusts.json',[]))}")
PY
else MANUAL+=("AWS: pass --aws-profile <p> (SecurityAudit + account:Get*); also screenshot Account → root email/MFA and Billing → Payment methods"); fi

# ---------------- GCP ----------------
if command -v gcloud >/dev/null && gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  echo "== gcp =="
  gcloud projects list --format=json > "$OUT/gcp-projects.json" 2>/dev/null
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import json,subprocess,os,sys
out=sys.argv[1]; projs=json.load(open(f"{out}/gcp-projects.json")); members={}; 
for p in projs:
    pid=p["projectId"]; r=subprocess.run(["gcloud","projects","get-iam-policy",pid,"--format=json"],capture_output=True,text=True)
    if r.returncode: continue
    for b in json.loads(r.stdout).get("bindings",[]):
        for m in b.get("members",[]):
            kind,_,ident=m.partition(":"); e=members.setdefault(m,{"id":ident,"email":ident if kind in("user",) else None,"name":None,"role":"member","mfa":None,"last_active":None,"status":"active","note":""})
            if b["role"] in("roles/owner",): e["role"]="owner"
            elif b["role"]=="roles/editor" and e["role"]!="owner": e["role"]="admin"
            if kind=="serviceAccount": e["role"]="bot"
            e["note"]=(e["note"]+f" {pid}:{b['role'].replace('roles/','')}")[:300]
json.dump({"system":"gcp","source":"cli","collected":os.environ["NOW"],"members":list(members.values()),"notes":[f"{len(projs)} project(s)"]},open(f"{out}/members-gcp.json","w"),indent=1)
print(f"members-gcp.json: {len(members)} identities over {len(projs)} project(s)")
PY
fi

# ---------------- Vercel ----------------
if [ -n "${VERCEL_TOKEN:-}" ]; then
  echo "== vercel =="; H=(-H "Authorization: Bearer $VERCEL_TOKEN")
  curlj "${H[@]}" "https://api.vercel.com/v2/teams" > "$OUT/vercel-teams.json"
  [ -z "$VTEAM" ] && VTEAM=$(python3 -c 'import json,sys;t=json.load(open(sys.argv[1])).get("teams",[]);print(t[0]["id"] if t else "")' "$OUT/vercel-teams.json")
  if [ -n "$VTEAM" ]; then
    curlj "${H[@]}" "https://api.vercel.com/v2/teams/$VTEAM/members?limit=100" > "$OUT/vercel-members.json"
    curlj "${H[@]}" "https://api.vercel.com/v9/projects?teamId=$VTEAM&limit=100" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps([{"name":p.get("name"),"repo":(p.get("link") or {}).get("repo"),"org":(p.get("link") or {}).get("org"),"type":(p.get("link") or {}).get("type"),"env_names":[e.get("key") for e in p.get("env",[])][:40],"updated":p.get("updatedAt")} for p in d.get("projects",[])],indent=1))' > "$OUT/vercel-projects.json"
    norm vercel api '[{"id":m.get("email"),"email":m.get("email"),"name":m.get("name") or m.get("username"),"role":{"OWNER":"owner","MEMBER":"member","DEVELOPER":"member","VIEWER":"guest","BILLING":"admin","CONTRIBUTOR":"member"}.get(m.get("role"),"unknown"),"mfa":None,"last_active":None,"status":"invited" if m.get("confirmed") is False else "active"} for m in data.get("members",[])]' < "$OUT/vercel-members.json"
    own "$(python3 -c 'import json,sys;t=[x for x in json.load(open(sys.argv[1])).get("teams",[]) if x["id"]==sys.argv[2]];t=t[0] if t else {};print(json.dumps({"system":"vercel","account":t.get("slug"),"display_name":t.get("name"),"primary_email":None,"billing_email":(t.get("billing") or {}).get("email"),"owner_identity":None,"notes":["projects → vercel-projects.json (linked repo per project)"]}))' "$OUT/vercel-teams.json" "$VTEAM")"
    python3 -c 'import json,sys;ps=json.load(open(sys.argv[1]));[print("  project %-30s repo=%s/%s" % (p.get("name"),p.get("org"),p.get("repo"))) for p in ps]' "$OUT/vercel-projects.json"
  else say "no team found (personal scope only) — projects live under a personal account: that itself is a Q3 finding"; fi
else MANUAL+=("Vercel: VERCEL_TOKEN (Account → Tokens) or screenshot Team → Settings → Members, and each project's Git connection"); fi

# ---------------- Render ----------------
if [ -n "${RENDER_API_KEY:-}" ]; then
  echo "== render =="; H=(-H "Authorization: Bearer $RENDER_API_KEY")
  curlj "${H[@]}" "https://api.render.com/v1/owners?limit=50" > "$OUT/render-owners.json"
  curlj "${H[@]}" "https://api.render.com/v1/services?limit=100" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps([{"name":s["service"].get("name"),"type":s["service"].get("type"),"repo":s["service"].get("repo"),"branch":s["service"].get("branch"),"autoDeploy":s["service"].get("autoDeploy"),"updated":s["service"].get("updatedAt")} for s in d if "service" in s],indent=1))' > "$OUT/render-services.json"
  own "$(python3 -c 'import json,sys;o=[x["owner"] for x in json.load(open(sys.argv[1])) if "owner" in x];t=[x for x in o if x.get("type")=="team"] or o;t=t[0] if t else {};print(json.dumps({"system":"render","account":t.get("id"),"display_name":t.get("name"),"primary_email":t.get("email"),"billing_email":None,"owner_identity":None,"notes":["members are not in the Render API — screenshot Workspace → Members","services → render-services.json (repo per service)"]}))' "$OUT/render-owners.json")"
  python3 -c 'import json,sys;[print("  service %-30s %-12s repo=%s (%s)" % (s.get("name"),s.get("type"),s.get("repo"),s.get("branch"))) for s in json.load(open(sys.argv[1]))]' "$OUT/render-services.json"
  MANUAL+=("Render members: screenshot Workspace → Members (API has owners/services only)")
else MANUAL+=("Render: RENDER_API_KEY for owners+services; screenshot Workspace → Members either way"); fi

# ---------------- Netlify ----------------
if [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then
  echo "== netlify =="; H=(-H "Authorization: Bearer $NETLIFY_AUTH_TOKEN")
  curlj "${H[@]}" "https://api.netlify.com/api/v1/accounts" > "$OUT/netlify-accounts.json"
  SLUG=$(python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));print(a[0]["slug"] if a else "")' "$OUT/netlify-accounts.json")
  [ -n "$SLUG" ] && curlj "${H[@]}" "https://api.netlify.com/api/v1/$SLUG/members" | norm netlify api '[{"id":m.get("email"),"email":m.get("email"),"name":m.get("full_name"),"role":{"Owner":"owner","Collaborator":"member","Controller":"admin"}.get(m.get("role"),"member"),"mfa":None,"last_active":None,"status":"active" if not m.get("pending") else "invited"} for m in (data if isinstance(data,list) else [])]'
fi

# ---------------- Fly ----------------
if command -v fly >/dev/null && fly auth whoami >/dev/null 2>&1; then
  echo "== fly =="
  fly orgs list --json > "$OUT/fly-orgs.json" 2>/dev/null
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import json,subprocess,os,sys
out=sys.argv[1]
try: orgs=json.load(open(f"{out}/fly-orgs.json"))
except Exception: orgs={}
slugs=list(orgs.keys()) if isinstance(orgs,dict) else [o.get("slug") or o.get("Slug") for o in orgs]
members=[]; notes=[]
for s in slugs:
    r=subprocess.run(["fly","orgs","show",s,"--json"],capture_output=True,text=True)
    if r.returncode: notes.append(f"{s}: {r.stderr.strip()[:100]}"); continue
    try: d=json.loads(r.stdout)
    except Exception: continue
    for m in (d.get("Members") or d.get("members") or []):
        e=m.get("Email") or m.get("email"); members.append({"id":e,"email":e,"name":m.get("Name") or m.get("name"),"role":"admin" if str(m.get("Role") or m.get("role","")).upper()=="ADMIN" else "member","mfa":None,"last_active":None,"status":"active","note":f"org {s}"})
json.dump({"system":"fly","source":"cli","collected":os.environ["NOW"],"members":members,"notes":notes+[f"orgs: {slugs}"]},open(f"{out}/members-fly.json","w"),indent=1)
print(f"members-fly.json: {len(members)} identities over {len(slugs)} org(s)")
PY
fi

# ---------------- Heroku ----------------
if command -v heroku >/dev/null && heroku auth:whoami >/dev/null 2>&1; then
  echo "== heroku =="
  heroku teams --json > "$OUT/heroku-teams.json" 2>/dev/null; heroku apps --all --json > "$OUT/heroku-apps.json" 2>/dev/null
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import json,subprocess,os,sys
out=sys.argv[1]; members={}
def add(e,role,note):
    m=members.setdefault(e,{"id":e,"email":e,"name":None,"role":role,"mfa":None,"last_active":None,"status":"active","note":""})
    if role=="admin": m["role"]="admin"
    m["note"]=(m["note"]+" "+note)[:300]
for t in json.load(open(f"{out}/heroku-teams.json")):
    r=subprocess.run(["heroku","members","--team",t["name"],"--json"],capture_output=True,text=True)
    if r.returncode==0:
        for m in json.loads(r.stdout): add(m["email"],"admin" if m.get("role")=="admin" else "member",f"team {t['name']}:{m.get('role')}"); members[m["email"]]["mfa"]=m.get("two_factor_authentication")
apps=json.load(open(f"{out}/heroku-apps.json"))
for a in apps:
    r=subprocess.run(["heroku","access","-a",a["name"],"--json"],capture_output=True,text=True)
    if r.returncode==0:
        for m in json.loads(r.stdout): add(m["user"]["email"],"member",f"app {a['name']}")
    add(a.get("owner",{}).get("email","?"),"owner",f"owns app {a['name']}")
json.dump({"system":"heroku","source":"cli","collected":os.environ["NOW"],"members":list(members.values()),"notes":[f"{len(apps)} app(s)"]},open(f"{out}/members-heroku.json","w"),indent=1)
print(f"members-heroku.json: {len(members)} identities; apps={len(apps)}")
PY
fi

# ---------------- Cloudflare ----------------
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  echo "== cloudflare =="; H=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  curlj "${H[@]}" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/members?per_page=50" | norm cloudflare api '[{"id":m["user"]["email"],"email":m["user"]["email"],"name":((m["user"].get("first_name") or "")+" "+(m["user"].get("last_name") or "")).strip(),"role":"owner" if any(r.get("name")=="Super Administrator - All Privileges" for r in m.get("roles",[])) else ("admin" if any("Administrator" in r.get("name","") for r in m.get("roles",[])) else "member"),"mfa":m["user"].get("two_factor_authentication_enabled"),"last_active":None,"status":m.get("status","active")} for m in data.get("result",[])]'
  curlj "${H[@]}" "https://api.cloudflare.com/client/v4/zones?per_page=50" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps([{"name":z["name"],"status":z["status"],"plan":(z.get("plan") or {}).get("name"),"registrar_managed":"cloudflare" in str(z.get("original_registrar","")).lower() or z.get("type")=="full","name_servers":z.get("name_servers")} for z in d.get("result",[])],indent=1))' > "$OUT/cloudflare-zones.json"
  python3 -c 'import json,sys;[print("  zone %-32s %s" % (z.get("name"),z.get("status"))) for z in json.load(open(sys.argv[1]))]' "$OUT/cloudflare-zones.json"
else MANUAL+=("Cloudflare: CLOUDFLARE_API_TOKEN (Account Settings: Read, Zone: Read) + CLOUDFLARE_ACCOUNT_ID, or screenshot Manage Account → Members and Domain Registration"); fi

# ---------------- MongoDB Atlas ----------------
if command -v atlas >/dev/null && atlas organizations list --output json >/dev/null 2>&1; then
  echo "== atlas =="
  atlas organizations list --output json > "$OUT/atlas-orgs.json" 2>/dev/null
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import json,subprocess,os,sys
out=sys.argv[1]; members={}; dbusers=[]; acl=[]; keys=[]
def run(*a):
    r=subprocess.run(["atlas",*a,"--output","json"],capture_output=True,text=True)
    try: return json.loads(r.stdout) if r.returncode==0 else {"error":r.stderr[:150]}
    except Exception: return {}
def add(u,role,note):
    e=(u.get("emailAddress") or u.get("username") or "?").lower(); m=members.setdefault(e,{"id":e,"email":e,"name":((u.get("firstName") or "")+" "+(u.get("lastName") or "")).strip(),"role":role,"mfa":None,"last_active":u.get("lastAuth"),"status":"active","note":""})
    if role=="owner": m["role"]="owner"
    m["note"]=(m["note"]+" "+note)[:300]
orgs=json.load(open(f"{out}/atlas-orgs.json")).get("results",[])
for o in orgs:
    oid=o["id"]
    for u in (run("organizations","users","list","--orgId",oid).get("results") or []):
        roles=[r.get("roleName") for r in u.get("roles",[]) if r.get("orgId")==oid]; add(u,"owner" if "ORG_OWNER" in roles else "member",f"org {o['name']}:{','.join(roles)}")
    for k in (run("organizations","apiKeys","list","--orgId",oid).get("results") or []): keys.append({"org":o["name"],"desc":k.get("desc"),"roles":k.get("roles"),"publicKey":k.get("publicKey")})
    for p in (run("projects","list","--orgId",oid).get("results") or []):
        pid=p["id"]
        for u in (run("projects","users","list","--projectId",pid).get("results") or []):
            roles=[r.get("roleName") for r in u.get("roles",[]) if r.get("groupId")==pid]; add(u,"admin" if "GROUP_OWNER" in roles else "member",f"project {p['name']}:{','.join(roles)}")
        for d in (run("dbusers","list","--projectId",pid).get("results") if isinstance(run("dbusers","list","--projectId",pid),dict) else run("dbusers","list","--projectId",pid)) or []: dbusers.append({"project":p["name"],"username":d.get("username"),"roles":[f"{r.get('roleName')}@{r.get('databaseName')}" for r in d.get("roles",[])],"authDatabase":d.get("databaseName")})
        for a in (run("accessLists","list","--projectId",pid).get("results") or []): acl.append({"project":p["name"],"cidr":a.get("cidrBlock") or a.get("ipAddress"),"comment":a.get("comment")})
json.dump({"system":"atlas","source":"cli","collected":os.environ["NOW"],"members":list(members.values()),"notes":[f"{len(orgs)} org(s)"]},open(f"{out}/members-atlas.json","w"),indent=1)
json.dump(dbusers,open(f"{out}/atlas-dbusers.json","w"),indent=1); json.dump(acl,open(f"{out}/atlas-accesslist.json","w"),indent=1); json.dump(keys,open(f"{out}/atlas-apikeys.json","w"),indent=1)
print(f"members-atlas.json: {len(members)} identities; dbusers={len(dbusers)} accesslist={len(acl)} apikeys={len(keys)}")
for a in acl: print(f"  access-list {a['project']:<20} {a['cidr']:<20} {a['comment'] or ''}")
PY
fi

# ---------------- Supabase ----------------
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "== supabase =="; H=(-H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
  curlj "${H[@]}" "https://api.supabase.com/v1/organizations" > "$OUT/supabase-orgs.json"
  curlj "${H[@]}" "https://api.supabase.com/v1/projects" > "$OUT/supabase-projects.json"
  python3 - "$OUT" "$SUPABASE_ACCESS_TOKEN" <<'PY' | sed 's/^/  /'
import json,subprocess,os,sys
out,tok=sys.argv[1],sys.argv[2]; members=[]
for o in json.load(open(f"{out}/supabase-orgs.json")) if isinstance(json.load(open(f"{out}/supabase-orgs.json")),list) else []:
    r=subprocess.run(["curl","-sS","-H",f"Authorization: Bearer {tok}",f"https://api.supabase.com/v1/organizations/{o['id']}/members"],capture_output=True,text=True)
    try:
        for m in json.loads(r.stdout): members.append({"id":m.get("email"),"email":m.get("email"),"name":m.get("user_name"),"role":{"Owner":"owner","Administrator":"admin","Developer":"member","Read-only":"guest"}.get(m.get("role_name"),"member"),"mfa":m.get("mfa_enabled"),"last_active":None,"status":"active","note":f"org {o.get('name')}"})
    except Exception as e: pass
json.dump({"system":"supabase","source":"api","collected":os.environ["NOW"],"members":members,"notes":[]},open(f"{out}/members-supabase.json","w"),indent=1)
print(f"members-supabase.json: {len(members)} identities")
PY
fi

# ---------------- Slack ----------------
if [ -n "${SLACK_TOKEN:-}" ]; then
  echo "== slack =="; H=(-H "Authorization: Bearer $SLACK_TOKEN")
  curlj "${H[@]}" "https://slack.com/api/users.list?limit=500" > "$OUT/slack-users.json"
  curlj "${H[@]}" "https://slack.com/api/team.info" > "$OUT/slack-team.json"
  curlj "${H[@]}" "https://slack.com/api/team.integrationLogs?count=200" > "$OUT/slack-integration-log.json"
  norm slack api '[{"id":(m.get("profile") or {}).get("email") or m["id"],"email":(m.get("profile") or {}).get("email"),"name":m.get("real_name") or m.get("name"),"role":"bot" if (m.get("is_bot") or m.get("id")=="USLACKBOT") else ("owner" if m.get("is_primary_owner") or m.get("is_owner") else ("admin" if m.get("is_admin") else ("guest" if (m.get("is_restricted") or m.get("is_ultra_restricted")) else "member"))),"mfa":m.get("has_2fa"),"last_active":None,"status":"deactivated" if m.get("deleted") else "active","note":("primary owner" if m.get("is_primary_owner") else "")+(" single-channel guest" if m.get("is_ultra_restricted") else "")} for m in data.get("members",[]) if not m.get("is_app_user")] if data.get("ok") else (_ for _ in ()).throw(Exception(data.get("error")))' < "$OUT/slack-users.json"
  own "$(python3 -c 'import json,sys;t=json.load(open(sys.argv[1])).get("team",{});u=[m for m in json.load(open(sys.argv[2])).get("members",[]) if m.get("is_primary_owner")];print(json.dumps({"system":"slack","account":t.get("domain"),"display_name":t.get("name"),"primary_email":(u[0].get("profile",{}).get("email") if u else None),"billing_email":None,"owner_identity":(u[0].get("profile",{}).get("email") if u else None),"notes":["primary owner = owner_identity","apps installed → slack-integration-log.json"]}))' "$OUT/slack-team.json" "$OUT/slack-users.json")"
else MANUAL+=("Slack: SLACK_TOKEN (admin user token: users:read, users:read.email, admin) or screenshots Admin → Manage members (incl. Deactivated, Guests) and Manage apps"); fi

# ---------------- Google Workspace ----------------
if command -v gam >/dev/null && gam info domain >/dev/null 2>&1; then
  echo "== google workspace (gam) =="
  gam print users fields primaryemail,name,suspended,isadmin,isdelegatedadmin,isenrolledin2sv,lastlogintime,creationtime > "$OUT/google-users.csv" 2>/dev/null
  gam print admins > "$OUT/google-admins.csv" 2>/dev/null
  gam all users print forwards > "$OUT/google-forwards.csv" 2>/dev/null || true
  gam all users print tokens > "$OUT/google-tokens.csv" 2>/dev/null || true
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import csv,json,os,sys
out=sys.argv[1]; members=[]
for r in csv.DictReader(open(f"{out}/google-users.csv")):
    members.append({"id":r["primaryEmail"].lower(),"email":r["primaryEmail"].lower(),"name":r.get("name.fullName"),"role":"owner" if r.get("isAdmin")=="True" else ("admin" if r.get("isDelegatedAdmin")=="True" else "member"),"mfa":r.get("isEnrolledIn2Sv")=="True","last_active":(r.get("lastLoginTime") or "")[:10] or None,"status":"suspended" if r.get("suspended")=="True" else "active"})
fw=[]; 
try: fw=[r for r in csv.DictReader(open(f"{out}/google-forwards.csv")) if r.get("forwardTo")]
except Exception: pass
json.dump({"system":"google","source":"cli","collected":os.environ["NOW"],"members":members,"notes":[f"{len(fw)} user(s) with forwarding → google-forwards.csv","admins → google-admins.csv; third-party tokens → google-tokens.csv"]},open(f"{out}/members-google.json","w"),indent=1)
print(f"members-google.json: {len(members)} identities ({sum(1 for m in members if m['role']=='owner')} super admins, {sum(1 for m in members if not m['mfa'] and m['status']=='active')} active without 2SV); forwards={len(fw)}")
PY
elif [ -n "${GOOGLE_ADMIN_TOKEN:-}" ]; then
  echo "== google workspace (admin token) =="
  curlj -H "Authorization: Bearer $GOOGLE_ADMIN_TOKEN" "https://admin.googleapis.com/admin/directory/v1/users?customer=my_customer&maxResults=500&projection=basic" | norm google api '[{"id":u["primaryEmail"].lower(),"email":u["primaryEmail"].lower(),"name":(u.get("name") or {}).get("fullName"),"role":"owner" if u.get("isAdmin") else ("admin" if u.get("isDelegatedAdmin") else "member"),"mfa":u.get("isEnrolledIn2Sv"),"last_active":(u.get("lastLoginTime") or "")[:10] or None,"status":"suspended" if u.get("suspended") else "active"} for u in data.get("users",[])]'
  MANUAL+=("Google Workspace forwards + third-party app access: screenshot Reporting → Email log / Security → API controls (gam covers these)")
else MANUAL+=("Google Workspace: gam (super admin) or GOOGLE_ADMIN_TOKEN; else screenshot Admin → Users (add 2SV + last sign-in columns), Admin roles, App access control"); fi

# ---------------- 1Password ----------------
if command -v op >/dev/null && op whoami >/dev/null 2>&1; then
  echo "== 1password =="
  op user list --format json > "$OUT/1password-users.json" 2>/dev/null
  op vault list --format json > "$OUT/1password-vaults.json" 2>/dev/null
  norm 1password cli '[{"id":u.get("email"),"email":u.get("email"),"name":u.get("name"),"role":"owner" if u.get("type")=="OWNER" else ("admin" if u.get("type") in ("ADMIN","MEMBER_ADMIN") else ("guest" if u.get("type")=="GUEST" else ("bot" if u.get("type")=="SERVICE_ACCOUNT" else "member"))),"mfa":None,"last_active":None,"status":{"ACTIVE":"active","SUSPENDED":"suspended","INVITED":"invited","TRANSFER_PENDING":"invited"}.get(u.get("state"),str(u.get("state")).lower())} for u in data]' < "$OUT/1password-users.json"
  python3 - "$OUT" <<'PY' | sed 's/^/  /'
import json,subprocess,sys
out=sys.argv[1]; vs=json.load(open(f"{out}/1password-vaults.json")); res=[]
for v in vs:
    r=subprocess.run(["op","vault","user","list",v["id"],"--format","json"],capture_output=True,text=True)
    users=[u.get("email") for u in json.loads(r.stdout)] if r.returncode==0 and r.stdout.strip() else []
    res.append({"vault":v["name"],"users":users,"items":v.get("items")})
json.dump(res,open(f"{out}/1password-vault-access.json","w"),indent=1)
for v in res: print(f"vault {v['vault']:<30} items={v.get('items')} users={len(v['users'])}: {', '.join(v['users'][:6])}")
PY
else MANUAL+=("1Password: op signin as owner/admin; else screenshot People and Vaults (who can see the break-glass vault)"); fi

# ---------------- Sentry / Datadog / PagerDuty / Linear / Notion / SendGrid / Tailscale / Stripe / npm ----------------
if [ -n "${SENTRY_TOKEN:-}" ] && [ -n "${SENTRY_ORG:-}" ]; then echo "== sentry =="
  curlj -H "Authorization: Bearer $SENTRY_TOKEN" "https://sentry.io/api/0/organizations/$SENTRY_ORG/members/?per_page=100" | norm sentry api '[{"id":m.get("email"),"email":m.get("email"),"name":m.get("name"),"role":{"owner":"owner","manager":"admin","admin":"admin","member":"member","billing":"admin"}.get(m.get("orgRole") or m.get("role"),"member"),"mfa":(m.get("user") or {}).get("has2fa"),"last_active":((m.get("user") or {}).get("lastActive") or "")[:10] or None,"status":"invited" if m.get("pending") else "active"} for m in data]'; fi
if [ -n "${DD_API_KEY:-}" ] && [ -n "${DD_APP_KEY:-}" ]; then echo "== datadog =="
  curlj -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" "https://api.${DD_SITE:-datadoghq.com}/api/v2/users?page[size]=100&filter[status]=Active,Pending" | norm datadog api '[{"id":u["attributes"].get("email"),"email":u["attributes"].get("email"),"name":u["attributes"].get("name"),"role":"bot" if u["attributes"].get("service_account") else "member","mfa":None,"last_active":None,"status":str(u["attributes"].get("status","active")).lower()} for u in data.get("data",[])]'; fi
if [ -n "${PAGERDUTY_TOKEN:-}" ]; then echo "== pagerduty =="
  curlj -H "Authorization: Token token=$PAGERDUTY_TOKEN" -H "Accept: application/vnd.pagerduty+json;version=2" "https://api.pagerduty.com/users?limit=100" | norm pagerduty api '[{"id":u.get("email"),"email":u.get("email"),"name":u.get("name"),"role":{"owner":"owner","admin":"admin","user":"member","limited_user":"guest","observer":"guest","read_only_user":"guest","restricted_access":"guest"}.get(u.get("role"),"member"),"mfa":None,"last_active":None,"status":"invited" if u.get("invitation_sent") else "active"} for u in data.get("users",[])]'; fi
if [ -n "${LINEAR_API_KEY:-}" ]; then echo "== linear =="
  curlj -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d '{"query":"{ users(first:200) { nodes { email name active admin guest lastSeen } } }"}' https://api.linear.app/graphql | norm linear api '[{"id":u["email"],"email":u["email"],"name":u.get("name"),"role":"admin" if u.get("admin") else ("guest" if u.get("guest") else "member"),"mfa":None,"last_active":(u.get("lastSeen") or "")[:10] or None,"status":"active" if u.get("active") else "deactivated"} for u in data["data"]["users"]["nodes"]]'; fi
if [ -n "${NOTION_TOKEN:-}" ]; then echo "== notion =="
  curlj -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" "https://api.notion.com/v1/users?page_size=100" | norm notion api '[{"id":((u.get("person") or {}).get("email")) or u["id"],"email":(u.get("person") or {}).get("email"),"name":u.get("name"),"role":"bot" if u.get("type")=="bot" else "member","mfa":None,"last_active":None,"status":"active"} for u in data.get("results",[])]'; fi
if [ -n "${SENDGRID_API_KEY:-}" ]; then echo "== sendgrid =="
  curlj -H "Authorization: Bearer $SENDGRID_API_KEY" "https://api.sendgrid.com/v3/teammates?limit=100" | norm sendgrid api '[{"id":t.get("email"),"email":t.get("email"),"name":((t.get("first_name") or "")+" "+(t.get("last_name") or "")).strip(),"role":"admin" if t.get("is_admin") else "member","mfa":None,"last_active":None,"status":"active"} for t in data.get("result",[])]'; fi
if [ -n "${TAILSCALE_API_KEY:-}" ] && [ -n "${TAILSCALE_TAILNET:-}" ]; then echo "== tailscale =="
  curlj -u "$TAILSCALE_API_KEY:" "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/users" | norm tailscale api '[{"id":u.get("loginName"),"email":u.get("loginName"),"name":u.get("displayName"),"role":{"owner":"owner","admin":"admin","it-admin":"admin","network-admin":"admin","member":"member"}.get(u.get("role"),"member"),"mfa":None,"last_active":(u.get("lastSeen") or "")[:10] or None,"status":str(u.get("status","active")).lower()} for u in data.get("users",[])]'
  curlj -u "$TAILSCALE_API_KEY:" "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/devices" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps([{"name":x.get("hostname"),"user":x.get("user"),"os":x.get("os"),"lastSeen":(x.get("lastSeen") or "")[:10],"expires":(x.get("expires") or "")[:10]} for x in d.get("devices",[])],indent=1))' > "$OUT/tailscale-devices.json"
  python3 -c 'import json,sys;[print("  device %-28s %-30s last-seen %s" % (d.get("name"),d.get("user"),d.get("lastSeen"))) for d in json.load(open(sys.argv[1]))]' "$OUT/tailscale-devices.json"; fi
if [ -n "${STRIPE_API_KEY:-}" ]; then echo "== stripe =="
  curlj -u "$STRIPE_API_KEY:" "https://api.stripe.com/v1/account" > "$OUT/stripe-account.json"
  own "$(python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));print(json.dumps({"system":"stripe","account":a.get("id"),"display_name":(a.get("business_profile") or {}).get("name") or (a.get("settings",{}).get("dashboard",{}) or {}).get("display_name"),"primary_email":a.get("email"),"billing_email":None,"owner_identity":None,"notes":["country=%s type=%s" % (a.get("country"),a.get("type")),"team members are not in the API — screenshot Settings → Team and security"]}))' "$OUT/stripe-account.json")"
  MANUAL+=("Stripe team: screenshot Settings → Team and security (members, roles, 2FA)")
else MANUAL+=("Stripe: STRIPE_API_KEY (restricted key, Account: read) for the account identity; screenshot Settings → Team and security"); fi
if command -v npm >/dev/null && npm whoami >/dev/null 2>&1; then echo "== npm =="
  for o in $(npm org ls 2>/dev/null | grep -oE '^@?[a-z0-9-]+' | head -5); do npm org ls "$o" --json 2>/dev/null | python3 -c 'import sys,json,os;d=json.load(sys.stdin);o=sys.argv[1];json.dump({"system":"npm","source":"cli","collected":os.environ["NOW"],"members":[{"id":u,"email":None,"name":u,"role":"owner" if r=="owner" else ("admin" if r=="admin" else "member"),"mfa":None,"last_active":None,"status":"active","note":"org "+o} for u,r in d.items()],"notes":[]},open(os.environ["OUT"]+"/members-npm.json","w"),indent=1);print("  members-npm.json: %d in org %s" % (len(d),o))' "$o"; done
fi

echo
echo "== systems still needing a token or a screenshot =="
for m in ${MANUAL[@]+"${MANUAL[@]}"}; do echo "  - $m"; done
cat <<'TXT'
  - Apple Developer: screenshot Membership details (entity type, Account Holder) + Users and Access
  - Google Play Console: screenshot Users and permissions + Account details (owner)
  - Domain registrar account: screenshot account email/2FA/auto-renew + domain list (whois via domain-inventory.sh)
  - Railway / Neon / PlanetScale / DigitalOcean / Hetzner / Clerk / Auth0 / Twilio / Postmark / Mailgun / Intercom / HubSpot / Zendesk / Figma / Atlassian / Amplitude / Mixpanel / Retool / Zapier: screenshot the members page of each one the company uses
  - The product's own admin panel: export/query of staff-role users, or screenshot
  Transcribe each into members-<system>.json ("source":"screenshot") per references/access-guide.md, then run secops-digest.py.
TXT
echo "done → $OUT"
