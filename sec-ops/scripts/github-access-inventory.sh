#!/usr/bin/env bash
# sec-ops: read-only GitHub org inventory for the access/ownership audit.
#
#   scripts/github-access-inventory.sh --org <org> [--out <dir>] [--max-repos 200]
#
# Needs `gh` authenticated as an ORG OWNER for the full picture (outside collaborators,
# installations, secrets, PATs, 2FA requirement are owner-only; a member sees less and the
# corresponding files carry an "error" field). Every call is a GET. Writes:
#   members-github.json            normalized members (role, mfa, status)   ← read by secops-digest.py
#   ownership-github.json          billing email, 2FA requirement, plan, SAML  ← read by secops-digest.py
#   github-outside-collaborators.json, github-installations.json, github-org-secrets.json (names),
#   github-pats.json, github-forks.json, github-repos.json, github-audit-log.json (Enterprise only),
#   repo-<name>.json               default-branch protection, deploy keys, outside collaborators,
#                                  security_and_analysis, visibility, pushed_at
set -uo pipefail
ORG=""; OUT=""; MAX=200
while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --max-repos) MAX="$2"; shift 2;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$ORG" ] && { echo "--org is required" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated (gh auth login)" >&2; exit 1; }
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
ME=$(gh api user --jq .login 2>/dev/null); echo "org=$ORG as=$ME out=$OUT"

get() {  # get <file> <endpoint> [gh api args...]; paginates; error → {"error":...}
  local f="$1"; shift
  if out=$(gh api --paginate "$@" 2>&1); then printf '%s\n' "$out" | python3 -c '
import sys,json
# --paginate concatenates JSON arrays/objects; merge arrays, keep last object otherwise
raw=sys.stdin.read().strip(); dec=json.JSONDecoder(); i=0; parts=[]
while i<len(raw):
    while i<len(raw) and raw[i].isspace(): i+=1
    if i>=len(raw): break
    o,j=dec.raw_decode(raw,i); parts.append(o); i=j
if all(isinstance(p,list) for p in parts): print(json.dumps([x for p in parts for x in p]))
else: print(json.dumps(parts[-1] if len(parts)==1 else parts))' > "$OUT/$f"; echo "  ok   $f"
  else python3 -c 'import json,sys;print(json.dumps({"error":sys.argv[1].strip()[:400]}))' "$out" > "$OUT/$f"; echo "  ERR  $f: $(echo "$out" | head -c 120)"; fi
}

echo "== org =="
get github-org.json "/orgs/$ORG"
get github-members-admin.json "/orgs/$ORG/members?role=admin&per_page=100"
get github-members-all.json "/orgs/$ORG/members?per_page=100"
get github-members-2fa-disabled.json "/orgs/$ORG/members?filter=2fa_disabled&per_page=100"
get github-outside-collaborators.json "/orgs/$ORG/outside_collaborators?per_page=100"
get github-pending-invitations.json "/orgs/$ORG/invitations?per_page=100"
get github-installations.json "/orgs/$ORG/installations?per_page=100"
get github-org-secrets.json "/orgs/$ORG/actions/secrets?per_page=100"
get github-pats.json "/orgs/$ORG/personal-access-tokens?per_page=100"
get github-pat-requests.json "/orgs/$ORG/personal-access-token-requests?per_page=100"
get github-saml.json "graphql" -f query="{ organization(login: \"$ORG\") { samlIdentityProvider { ssoUrl } requiresTwoFactorAuthentication } }"
get github-audit-log.json "/orgs/$ORG/audit-log?per_page=100&phrase=action:org.add_member+action:org.remove_member+action:org.update_member+action:repo.transfer"
get github-repos.json "/orgs/$ORG/repos?type=all&per_page=100&sort=pushed"

echo "== repos (up to $MAX) =="
python3 - "$OUT" "$ORG" "$MAX" <<'PY'
import json,subprocess,sys,os
out,org,mx=sys.argv[1],sys.argv[2],int(sys.argv[3])
try: repos=json.load(open(f"{out}/github-repos.json"))
except Exception: repos=[]
if isinstance(repos,dict): repos=[]
forks=[]
def gh(ep):
    p=subprocess.run(["gh","api","--paginate",ep],capture_output=True,text=True)
    if p.returncode: return {"error":p.stderr.strip()[:200]}
    try: return json.loads(p.stdout)
    except Exception:
        try: # paginated arrays concatenated
            dec=json.JSONDecoder(); raw=p.stdout.strip(); i=0; acc=[]
            while i<len(raw):
                while i<len(raw) and raw[i].isspace(): i+=1
                if i>=len(raw): break
                o,i=dec.raw_decode(raw,i); acc+=o if isinstance(o,list) else [o]
            return acc
        except Exception: return {"raw":p.stdout[:200]}
for r in repos[:mx]:
    n=r["name"]; full=r["full_name"]; db=r.get("default_branch") or "main"
    d={"name":n,"full_name":full,"private":r.get("private"),"visibility":r.get("visibility"),"archived":r.get("archived"),
       "pushed_at":r.get("pushed_at"),"default_branch":db,"security_and_analysis":r.get("security_and_analysis"),
       "protection":gh(f"/repos/{full}/branches/{db}/protection"),
       "deploy_keys":gh(f"/repos/{full}/keys"),
       "outside_collaborators":gh(f"/repos/{full}/collaborators?affiliation=outside&per_page=100"),
       "direct_collaborators":gh(f"/repos/{full}/collaborators?affiliation=direct&per_page=100"),
       "secrets":gh(f"/repos/{full}/actions/secrets?per_page=100"),
       "forks":gh(f"/repos/{full}/forks?per_page=100") if (r.get("forks_count") or 0) else []}
    if isinstance(d["forks"],list):
        for f in d["forks"]: forks.append({"repo":full,"fork":f.get("full_name"),"owner":(f.get("owner") or {}).get("login"),"private":r.get("private")})
    json.dump(d,open(f"{out}/repo-{n}.json","w"),indent=1)
    prot="protected" if isinstance(d["protection"],dict) and "error" not in d["protection"] else "UNPROTECTED"
    print(f"  {full:<50} {str(r.get('visibility')):<8} {prot:<11} keys={len(d['deploy_keys']) if isinstance(d['deploy_keys'],list) else '?'} outside={len(d['outside_collaborators']) if isinstance(d['outside_collaborators'],list) else '?'} forks={len(d['forks']) if isinstance(d['forks'],list) else '?'}")
json.dump(forks,open(f"{out}/github-forks.json","w"),indent=1)
print(f"  {len(forks)} fork(s) of org repos in other accounts → github-forks.json")
PY

echo "== normalize =="
python3 - "$OUT" "$ORG" <<'PY'
import json,sys,datetime
out,org=sys.argv[1],sys.argv[2]
def load(n):
    try: return json.load(open(f"{out}/{n}"))
    except Exception: return {"error":"missing"}
def lst(x): return x if isinstance(x,list) else []
admins={m["login"] for m in lst(load("github-members-admin.json"))}
no2fa={m["login"] for m in lst(load("github-members-2fa-disabled.json"))}
org_info=load("github-org.json"); saml=load("github-saml.json")
members=[]
for m in lst(load("github-members-all.json")):
    l=m["login"]; members.append({"id":l,"email":None,"name":None,"role":"owner" if l in admins else "member",
        "mfa":(False if l in no2fa else (True if "error" not in load("github-members-2fa-disabled.json") else None)),
        "last_active":None,"status":"active","type":m.get("type")})
for m in lst(load("github-outside-collaborators.json")):
    members.append({"id":m["login"],"email":None,"name":None,"role":"outside","mfa":(False if m["login"] in no2fa else None),"last_active":None,"status":"active"})
for i in lst(load("github-pending-invitations.json")):
    members.append({"id":i.get("login") or i.get("email"),"email":i.get("email"),"name":None,"role":"member","mfa":None,"last_active":i.get("created_at"),"status":"invited"})
inst=load("github-installations.json"); apps=lst(inst.get("installations") if isinstance(inst,dict) else inst)
for a in apps:
    members.append({"id":f"app:{a.get('app_slug')}","email":None,"name":a.get("app_slug"),"role":"bot","mfa":None,"last_active":a.get("updated_at"),"status":"active","note":f"GitHub App, permissions={list((a.get('permissions') or {}).keys())[:8]}"})
notes=[]
if "error" in load("github-outside-collaborators.json"): notes.append("outside collaborators not readable (need org owner)")
if "error" in load("github-members-2fa-disabled.json"): notes.append("2fa_disabled filter not readable (need org owner) — mfa unknown")
json.dump({"system":"github","source":"api","collected":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"org":org,"members":members,"notes":notes},open(f"{out}/members-github.json","w"),indent=1)
s=(saml.get("data") or {}).get("organization") or {} if isinstance(saml,dict) else {}
own={"system":"github","account":org,"display_name":org_info.get("name") if isinstance(org_info,dict) else None,
     "primary_email":org_info.get("email") if isinstance(org_info,dict) else None,
     "billing_email":org_info.get("billing_email") if isinstance(org_info,dict) else None,
     "owner_identity":", ".join(sorted(admins)) or None,"source":"api",
     "notes":[f"plan={((org_info.get('plan') or {}).get('name')) if isinstance(org_info,dict) else None}",
              f"two_factor_requirement_enabled={org_info.get('two_factor_requirement_enabled') if isinstance(org_info,dict) else None}",
              f"saml={'yes' if s.get('samlIdentityProvider') else 'no/unknown'}",
              f"owners={len(admins)} members={len(lst(load('github-members-all.json')))} outside={len(lst(load('github-outside-collaborators.json')))} apps={len(apps)}"]}
json.dump(own,open(f"{out}/ownership-github.json","w"),indent=1)
print(f"  members-github.json: {len(members)} identities ({len(admins)} owners, {len(no2fa)} without 2FA); ownership-github.json written")
for n in notes: print("  note:",n)
PY
echo "done → $OUT"
