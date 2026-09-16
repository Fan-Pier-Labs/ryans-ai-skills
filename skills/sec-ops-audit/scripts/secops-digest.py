#!/usr/bin/env python3
"""sec-ops: merge every members-*.json / ownership-*.json into the access matrix and the digest.

  scripts/secops-digest.py --dir <dir> [--roster roster.csv] [--ceo ceo@company.com] [--domain company.com]

Reads the normalized files written by the collectors (or transcribed by hand from screenshots,
see references/access-guide.md) plus roster.csv, and writes:
  <dir>/ACCESS-MATRIX.md   people x systems, role per cell; former people first, then unknown identities
  <dir>/DIGEST.md          automatic findings: former-with-access, unknown identities, personal-domain
                           identities, CEO-not-owner systems, admin counts (bus factor / inflation),
                           MFA off, guests/outside, bots, invited-never-accepted, ownership table,
                           systems still missing evidence, plus repo/on-box/domain summaries when present
Read-only. Re-run whenever a file is added."""
import argparse,csv,glob,json,os,re,sys,datetime,collections

ap=argparse.ArgumentParser(); ap.add_argument("--dir",required=True); ap.add_argument("--roster"); ap.add_argument("--ceo"); ap.add_argument("--domain")
a=ap.parse_args(); D=a.dir; ceo=(a.ceo or "").lower(); dom=(a.domain or "").lower().lstrip("@")
ADMIN={"owner","admin"}
PERSONAL={"gmail.com","googlemail.com","yahoo.com","hotmail.com","outlook.com","live.com","icloud.com","me.com","proton.me","protonmail.com","aol.com","msn.com","hey.com","fastmail.com","pm.me","qq.com","163.com","mail.com","ymail.com"}

# ---- roster
roster=[]; idx={}
if a.roster and os.path.exists(a.roster):
    for r in csv.DictReader(open(a.roster)):
        r={k.strip().lower():(v or "").strip() for k,v in r.items() if k}
        if not r.get("email"): continue
        r["status"]="current" if r.get("status","").lower().startswith("cur") else "former"
        roster.append(r)
        for k in [r["email"],r.get("github","")]+[x for x in re.split(r"[;,\s]+",r.get("aliases","")) if x]:
            if k: idx[k.lower()]=r
        if dom and r["email"].lower().endswith("@"+dom): idx.setdefault(r["email"].split("@")[0].lower(),r)   # bare local-part fallback
def person_for(m):
    for k in (m.get("email"),m.get("id"),m.get("name")):
        if k and str(k).lower() in idx: return idx[str(k).lower()]
    e=(m.get("email") or "").lower()
    if dom and e.endswith("@"+dom) and e.split("@")[0] in idx: return idx[e.split("@")[0]]
    return None

# ---- members
systems={}; notes={}
for f in sorted(glob.glob(os.path.join(D,"members-*.json"))):
    try: d=json.load(open(f))
    except Exception as e: print(f"skip {f}: {e}",file=sys.stderr); continue
    s=d.get("system") or os.path.basename(f)[8:-5]; systems[s]={"source":d.get("source"),"collected":d.get("collected"),"members":d.get("members",[]),"notes":d.get("notes",[])}
own={}
for f in sorted(glob.glob(os.path.join(D,"ownership-*.json"))):
    try: d=json.load(open(f)); own[d.get("system") or os.path.basename(f)[10:-5]]=d
    except Exception: pass
if not systems: print("no members-*.json in",D,file=sys.stderr); sys.exit(1)
sysnames=sorted(systems)

# ---- key every identity to a person (or an "unknown" bucket keyed by identity)
rows=collections.OrderedDict()   # key -> {"label","status","cells":{sys:[roles]},"idents":set(),"mfa_off":[], "roster":r|None}
def key_for(m,s):
    p=person_for(m)
    if p: return ("person",p["email"].lower()),p
    ident=(m.get("email") or m.get("id") or m.get("name") or "?"); return ("unknown",str(ident).lower()),None
def cell(role,status):
    return role+("†" if status in("deactivated","suspended") else ("?" if status=="invited" else ""))
bots=[]; guests=[]; mfa_off=[]; invited=[]; personal=[]; deact=[]
for s in sysnames:
    for m in systems[s]["members"]:
        role=(m.get("role") or "unknown").lower(); st=(m.get("status") or "active").lower()
        if role=="bot": bots.append((s,m.get("name") or m.get("id"),m.get("note",""))); continue
        k,p=key_for(m,s); r=rows.setdefault(k,{"label":(p.get("name") or p["email"]) if p else k[1],"status":p["status"] if p else "unknown","cells":collections.defaultdict(list),"idents":set(),"roster":p})
        r["cells"][s].append(cell(role,st)); 
        for i in (m.get("email"),m.get("id")):
            if i: r["idents"].add(str(i))
        e=(m.get("email") or "").lower()
        if e and dom and not e.endswith("@"+dom) and st=="active": personal.append((s,e,role))
        if m.get("mfa") is False and st=="active": mfa_off.append((s,m.get("email") or m.get("id"),role))
        if role in("guest","outside"): guests.append((s,m.get("email") or m.get("id"),m.get("note","")))
        if st=="invited": invited.append((s,m.get("email") or m.get("id"),m.get("last_active")))
        if st in("deactivated","suspended"): deact.append((s,m.get("email") or m.get("id")))
# roster people with no access at all still appear (current) so the reader sees the whole company
for p in roster:
    rows.setdefault(("person",p["email"].lower()),{"label":p.get("name") or p["email"],"status":p["status"],"cells":collections.defaultdict(list),"idents":{p["email"]},"roster":p})

order={"former":0,"unknown":1,"current":2}
ordered=sorted(rows.items(),key=lambda kv:(order.get(kv[1]["status"],3),kv[1]["label"].lower()))

# ---- ACCESS-MATRIX.md
L=[]; L.append(f"# Access matrix — {datetime.date.today()}\n"); L.append(f"Systems: {len(sysnames)} · identities keyed to people: {sum(1 for k in rows if k[0]=='person')} · unknown identities: {sum(1 for k in rows if k[0]=='unknown')} · roster: {len(roster)} ({sum(1 for p in roster if p['status']=='current')} current, {sum(1 for p in roster if p['status']=='former')} former)\n")
L.append("Cell = role in that system (`owner`/`admin`/`member`/`guest`/`outside`); `†` deactivated or suspended (login off, tokens may live on); `?` invited, never accepted. **Bold rows are former people. Italic rows are identities not on the roster.**\n")
hdr="| Person | Status | "+" | ".join(sysnames)+" | Systems |"; L.append(hdr); L.append("|"+"---|"*(len(sysnames)+3))
for k,r in ordered:
    lab=r["label"]; 
    if r["status"]=="former": lab=f"**{lab}**"
    elif k[0]=="unknown": lab=f"*{lab}*"
    cells=[", ".join(sorted(set(r["cells"].get(s,[])))) or "" for s in sysnames]; n=sum(1 for s in sysnames if r["cells"].get(s))
    extra=f" ({r['roster'].get('role')})" if r["roster"] and r["roster"].get("role") else ""
    L.append(f"| {lab}{extra} | {r['status']} | "+" | ".join(cells)+f" | {n} |")
L.append(""); L.append("## Identities behind each row\n")
for k,r in ordered:
    if len(r["idents"])>1 or k[0]=="unknown": L.append(f"- {r['label']}: {', '.join(sorted(r['idents']))}")
L.append(""); L.append("## Sources\n")
for s in sysnames: L.append(f"- {s}: {systems[s]['source']} · {systems[s]['collected']} · {len(systems[s]['members'])} identities" + (f" · notes: {'; '.join(str(n) for n in systems[s]['notes'])}" if systems[s]["notes"] else ""))
open(os.path.join(D,"ACCESS-MATRIX.md"),"w").write("\n".join(L)+"\n")

# ---- DIGEST.md
G=[]; G.append(f"# Sec-ops digest — {D} — {datetime.date.today()}\n")
former=[(k,r) for k,r in ordered if r["status"]=="former" and any(r["cells"].values())]
unknown=[(k,r) for k,r in ordered if k[0]=="unknown"]
G.append("## Q2 — former people with access\n")
if not roster: G.append("_No roster given (`--roster roster.csv`); cannot tell former from current. Every row is 'unknown'._\n")
elif not former: G.append("None found in the collected systems. (Systems without evidence are listed at the bottom — they are not cleared.)\n")
for k,r in former:
    G.append(f"### **{r['label']}** — {r['roster'].get('role','')}"); 
    for s in sysnames:
        if r["cells"].get(s): G.append(f"- {s}: {', '.join(sorted(set(r['cells'][s])))}")
    G.append(f"- identities: {', '.join(sorted(r['idents']))}"); G.append("- before removal: transfer anything they own; replace any token of theirs that CI/prod uses; then remove; then rotate what they could read\n")
G.append("## Identities not on the roster (ask: who is this?)\n")
for k,r in unknown: G.append(f"- `{k[1]}` — "+"; ".join(f"{s}: {', '.join(sorted(set(v)))}" for s,v in r["cells"].items() if v))
if not unknown: G.append("None.")
G.append("\n## Q3 — ownership table\n")
G.append("| System | Account | Display name | Primary email | On company domain | Billing email | Owner identity | CEO role | Source |"); G.append("|---|---|---|---|---|---|---|---|---|")
ceo_missing=[]
for s in sorted(set(sysnames)|set(own)):
    o=own.get(s,{}); pe=(o.get("primary_email") or "")
    ondom="yes" if (dom and pe.lower().endswith("@"+dom)) else ("**NO**" if pe else "?")
    ceo_role=""
    if ceo and s in systems:
        rs=[ (m.get("role") or "") for m in systems[s]["members"] if (m.get("email") or m.get("id") or "").lower()==ceo or (person_for(m) or {}).get("email","").lower()==ceo]
        ceo_role=", ".join(sorted(set(rs))) or "**absent**"
        if not any(x in ADMIN for x in rs): ceo_missing.append((s,ceo_role))
    G.append(f"| {s} | {o.get('account') or ''} | {o.get('display_name') or ''} | {pe} | {ondom} | {o.get('billing_email') or ''} | {o.get('owner_identity') or ''} | {ceo_role} | {o.get('source') or systems.get(s,{}).get('source','')} |")
if ceo: G.append(f"\n**CEO ({ceo}) is not owner/admin in {len(ceo_missing)} system(s):** "+(", ".join(f"{s} ({r})" for s,r in ceo_missing) or "none"))
for s,o in own.items():
    for n in o.get("notes",[]): G.append(f"- {s}: {n}")
crp=os.path.join(D,"code-reconciliation.json")
if os.path.exists(crp):
    try:
        inf=json.load(open(crp)).get("infra",[]); bad=[i for i in inf if str(i.get("verdict","")).startswith(("PERSONAL","TUNNEL","UNACCOUNTED"))]
        G.append(f"\n**Q3 — where the live hosts physically run** ({len(inf)} host(s) resolved, `CODE-RECONCILIATION.md`): "+("all on providers whose accounts are in the inventory" if not bad else "**"+str(len(bad))+" host(s) on infrastructure the company may not own:**"))
        for i in bad: G.append(f"- {i['host']} → {i.get('provider') or i.get('ip_owner')} ({', '.join(i.get('ip',[]))}): {i['verdict']}")
    except Exception as e: G.append(f"- code-reconciliation infra unreadable: {e}")
G.append("\n## Owners/admins per system (supports Q3 and Q5)\n"); G.append("| System | Owners/admins | Who | Total active identities |"); G.append("|---|---|---|---|")
for s in sysnames:
    ad=[(m.get("email") or m.get("id")) for m in systems[s]["members"] if (m.get("role") or "") in ADMIN and (m.get("status") or "active")=="active"]
    act=sum(1 for m in systems[s]["members"] if (m.get("status") or "active")=="active" and (m.get("role")!="bot"))
    flag=""
    G.append(f"| {s} | {len(ad)}{flag} | {', '.join(str(x) for x in ad[:8])}{' …' if len(ad)>8 else ''} | {act} |")
def section(title,items,fmt):
    G.append(f"\n## {title}\n"); 
    if not items: G.append("None."); return
    for it in items: G.append("- "+fmt(*it))
section("Q13 — MFA off (active identities)",mfa_off,lambda s,e,r:f"{s}: {e} ({r})")
section(f"Personal-domain identities (not @{dom or '?'}, active)",personal,lambda s,e,r:f"{s}: {e} ({r})")
section("Guests / outside collaborators",guests,lambda s,e,n:f"{s}: {e} {n}".strip())
section("Deactivated / suspended identities (check their tokens and owned resources)",deact,lambda s,e:f"{s}: {e}")
section("Invited, never accepted (stale invites are open doors)",invited,lambda s,e,t:f"{s}: {e} (since {t})")
section("Bots, apps, service accounts (each is a standing credential; name an owner)",bots,lambda s,n,note:f"{s}: {n} {note}".strip())

# ---- extra evidence present in the dir
G.append("\n## Other evidence in this directory\n")
for f in sorted(glob.glob(os.path.join(D,"domain-*.json"))):
    try:
        d=json.load(open(f)); G.append(f"- domain **{d['domain']}**: registrar={d.get('registrar')} registrant={d.get('registrant_org') or ('(privacy)' if d.get('whois_privacy') else '?')} expires={d.get('expires')} lock={d.get('transfer_lock')} dns={d.get('dns_provider')} mail={d.get('mail_provider')} spf={d.get('spf_all') or 'MISSING'} dmarc={d.get('dmarc_policy') or 'MISSING'} dkim={len(d.get('dkim_selectors',[]))} selector(s)")
    except Exception: pass
for f in sorted(glob.glob(os.path.join(D,"hosts-*.json"))):
    try:
        for h in json.load(open(f))["hosts"]: G.append(f"- host {h['host']} → {h['provider']} ({h.get('ip_owner') or ''})")
    except Exception: pass
for f in sorted(glob.glob(os.path.join(D,"repo-scan-*"))):
    n=os.path.basename(f)[10:]; bits=[]
    for name,label in (("gitleaks.json","gitleaks"),("trufflehog.json","trufflehog")):
        p=os.path.join(f,name)
        if os.path.exists(p):
            try: bits.append(f"{label}={len(json.load(open(p)))} finding(s)")
            except Exception: bits.append(f"{label}=see file")
    for name,label in (("tracked-env.txt","tracked env files"),("personal-deps.txt","deps outside org"),("docs-credentials.txt","credential-shaped lines in docs")):
        p=os.path.join(f,name)
        if os.path.exists(p): bits.append(f"{label}={sum(1 for l in open(p) if l.strip())}")
    G.append(f"- repo **{n}**: "+", ".join(bits)+f" → `{os.path.basename(f)}/`")
cr=os.path.join(D,"code-reconciliation.json")
if os.path.exists(cr):
    try:
        c=json.load(open(cr)); nh=[h for h in c.get("hosts",[]) if h.get("verdict")=="NO MATCH"]; nu=[u for u in c.get("units",[]) if u.get("verdict")=="NO MATCH"]; wk=[h for h in c.get("hosts",[]) if h.get("verdict")=="WEAK"]
        G.append(f"- **Q1 code reconciliation** (`CODE-RECONCILIATION.md`): {len(c.get('hosts',[]))} live host(s) checked, **{len(nh)} NO MATCH** ({', '.join(h['host'] for h in nh) or '-'}), {len(wk)} WEAK; {len(c.get('units',[]))} AWS deployed unit(s), **{len(nu)} NO MATCH** ({', '.join(u['kind']+':'+str(u['name']) for u in nu[:8])}{' …' if len(nu)>8 else ''}); repo components: {len(c.get('repo_components',[]))}")
    except Exception as e: G.append(f"- code-reconciliation.json unreadable: {e}")
dp=os.path.join(D,"deps-provenance.json")
if os.path.exists(dp):
    try:
        d=json.load(open(dp)); hi=[x for x in d["deps"] if x.get("severity")=="HIGH"]; me=[x for x in d["deps"] if x.get("severity")=="MEDIUM"]
        G.append(f"- **Q1 dependency provenance** (`deps-provenance.md`): {d.get('count')} deps, **{len(hi)} HIGH** (low-volume + maintained by someone on the roster: {', '.join(x['name']+' ← '+str(x.get('roster_match')) for x in hi[:6])}{' …' if len(hi)>6 else ''}), {len(me)} MEDIUM" + ("" if d.get("roster_loaded") else " — roster not loaded, employee-maintained check skipped"))
    except Exception as e: G.append(f"- deps-provenance.json unreadable: {e}")
for f in sorted(glob.glob(os.path.join(D,"box-*.txt"))):
    t=open(f,errors="replace").read(); keys=len(re.findall(r"^  \S+  SHA256:",t,re.M)); un=re.findall(r"uncommitted=(\d+) unpushed=(\S+)",t); nogit=len(re.findall(r"^  /\S+  \(",t,re.M)); akia=len(re.findall(r"key id: AKIA",t))
    G.append(f"- box {os.path.basename(f)[4:-4]}: {keys} authorized key(s); repos={len(un)} (uncommitted>0: {sum(1 for u,p in un if u!='0')}, unpushed>0: {sum(1 for u,p in un if p not in('0','?'))}); app dirs without git={nogit}; AKIA on disk={akia}")
for f in ("aws-secrets.json","aws-keypairs.json","aws-external-trusts.json","atlas-accesslist.json","atlas-dbusers.json","atlas-apikeys.json","tailscale-devices.json","github-forks.json","github-installations.json","github-pats.json","vercel-projects.json","render-services.json","slack-integration-log.json","1password-vault-access.json"):
    p=os.path.join(D,f)
    if os.path.exists(p):
        try: d=json.load(open(p)); n=len(d) if isinstance(d,list) else len(d.get("installations",d.get("logs",d.get("results",[])))) if isinstance(d,dict) else "?"
        except Exception: n="?"
        G.append(f"- `{f}`: {n} entries")

G.append("\n## Systems with no evidence yet\n")
expected=["github","aws","google","slack","1password","vercel","render","fly","heroku","cloudflare","atlas","supabase","stripe","apple","googleplay","registrar","product-admin","sentry","datadog","tailscale","npm"]
missing=[s for s in expected if s not in systems and s not in own]
G.append("Not cleared — collect or transcribe a screenshot, or record 'not used': "+", ".join(missing))
G.append("\nScreenshot-sourced systems (point-in-time, not re-runnable): "+(", ".join(s for s in sysnames if systems[s]["source"]=="screenshot") or "none"))
open(os.path.join(D,"DIGEST.md"),"w").write("\n".join(G)+"\n")
print(f"wrote {D}/ACCESS-MATRIX.md ({len(rows)} rows × {len(sysnames)} systems) and {D}/DIGEST.md")
print(f"  former with access: {len(former)}   unknown identities: {len(unknown)}   CEO not admin in: {len(ceo_missing)}   MFA off: {len(mfa_off)}   personal-domain: {len(personal)}   guests: {len(guests)}   bots: {len(bots)}")
