#!/usr/bin/env bash
# sec-ops: read-only domain / DNS / email-auth inventory (Q3, Q7, Q12) and "who hosts this
# hostname" (finds providers the user forgot to list).
#
#   scripts/domain-inventory.sh --domain company.com [--domain other.com ...] \
#       [--host api.company.com --host app.company.com ...] [--out <dir>]
#
# Writes <out>/domain-<name>.json per domain (whois registrar/registrant/expiry/lock, NS, MX,
# SPF, DMARC, DKIM selectors found, DNSSEC) and <out>/hosts-<date>.json for --host entries
# (CNAME chain, IPs, IP owner org from whois → provider guess). Prints a summary. Needs whois + dig.
set -uo pipefail
DOMAINS=(); HOSTS=(); OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAINS+=("$2"); shift 2;;
    --host) HOSTS+=("$2"); shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ ${#DOMAINS[@]} -eq 0 ] && { echo "--domain is required" >&2; exit 2; }
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
command -v dig >/dev/null || { echo "dig not found" >&2; exit 1; }
W(){ if command -v whois >/dev/null; then timeout 20 whois "$1" 2>/dev/null; fi; }
SELECTORS="google selector1 selector2 default dkim k1 k2 k3 s1 s2 mail smtp em sendgrid mandrill mg pm postmark amazonses ses protonmail zoho mailchimp hs1 hs2 krs sig1 mailgun mailjet sparkpost cm brevo mail1 mail2 fm1 fm2 fm3 mxvault zendesk1 zendesk2 zendesk3 zendesk4 intercom hubspot"

for d in "${DOMAINS[@]}"; do
  echo "== $d =="
  wh=$(W "$d")
  python3 - "$d" "$OUT" "$SELECTORS" <<'PY' "$wh"
import sys,json,subprocess,re,datetime
d,out,sels,wh=sys.argv[1],sys.argv[2],sys.argv[3].split(),sys.argv[4]
def dig(name,t): 
    p=subprocess.run(["dig","+short","+time=4","+tries=1",t,name],capture_output=True,text=True); return [l.strip() for l in p.stdout.splitlines() if l.strip()]
def wf(*keys):
    for k in keys:
        m=re.search(rf"(?im)^\s*{k}\s*:\s*(.+)$",wh)
        if m: return m.group(1).strip()
    return None
info={"domain":d,"collected":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
 "registrar":wf("Registrar","Sponsoring Registrar","registrar"),"registrant_org":wf("Registrant Organization","Registrant Organisation","org","Registrant"),
 "registrant_email":wf("Registrant Email"),"created":wf("Creation Date","Created On","created","Registered on"),"expires":wf("Registry Expiry Date","Expiration Date","Expiry Date","expires","paid-till","Expiry date"),
 "status":sorted(set(re.findall(r"(?i)(client(?:Transfer|Delete|Update)Prohibited|server(?:Transfer|Delete|Update)Prohibited|ok|pendingDelete|redemptionPeriod|inactive)",wh))),
 "dnssec":wf("DNSSEC"),"whois_privacy":bool(re.search(r"(?i)redacted|privacy|proxy|whoisguard|withheld|Data Protected|Contact Privacy",wh)),
 "ns":dig(d,"NS"),"mx":dig(d,"MX"),"a":dig(d,"A"),"txt":dig(d,"TXT")}
info["transfer_lock"]=any("TransferProhibited" in s for s in info["status"]) if info["status"] else None
spf=[t for t in info["txt"] if "v=spf1" in t.lower()]; info["spf"]=spf[0] if spf else None
info["spf_lookups"]=len(re.findall(r"\b(include:|a:|mx:|redirect=|exists:|ptr)",info["spf"] or ""))
info["spf_all"]=(re.search(r"([-~?+]all)",info["spf"] or "") or [None,None])[1]
dm=dig(f"_dmarc.{d}","TXT"); info["dmarc"]=dm[0] if dm else None
info["dmarc_policy"]=(re.search(r"p=(\w+)",info["dmarc"] or "") or [None,None])[1]
info["dmarc_rua"]=bool(re.search(r"rua=",info["dmarc"] or ""))
info["dkim_selectors"]=[s for s in sels if dig(f"{s}._domainkey.{d}","TXT") or dig(f"{s}._domainkey.{d}","CNAME")]
info["mta_sts"]=bool(dig(f"_mta-sts.{d}","TXT")); info["bimi"]=bool(dig(f"default._bimi.{d}","TXT"))
def prov(ns):
    n=" ".join(ns).lower()
    for k,v in {"cloudflare":"Cloudflare","awsdns":"Route 53","googledomains":"Google Domains","google":"Google","domaincontrol":"GoDaddy","registrar-servers":"Namecheap","dnsimple":"DNSimple","vercel-dns":"Vercel","nsone":"NS1","digitalocean":"DigitalOcean","linode":"Linode","hetzner":"Hetzner","azure-dns":"Azure","gandi":"Gandi","ovh":"OVH","porkbun":"Porkbun","squarespace":"Squarespace","wixdns":"Wix","name.com":"Name.com","hover":"Hover","dreamhost":"DreamHost","netlify":"Netlify","he.net":"Hurricane Electric"}.items():
        if k in n: return v
    return "unknown"
info["dns_provider"]=prov(info["ns"]); mxs=" ".join(info["mx"]).lower()
info["mail_provider"]="Google Workspace" if "google" in mxs else ("Microsoft 365" if "outlook" in mxs or "protection.outlook" in mxs else ("Proton" if "protonmail" in mxs else ("Zoho" if "zoho" in mxs else ("Fastmail" if "messagingengine" in mxs else ("none" if not mxs else "other")))))
json.dump(info,open(f"{out}/domain-{d}.json","w"),indent=1)
print(f"  registrar: {info['registrar']}   registrant: {info['registrant_org'] or ('(privacy)' if info['whois_privacy'] else None)}   expires: {info['expires']}   lock: {info['transfer_lock']}   dnssec: {info['dnssec']}")
print(f"  dns: {info['dns_provider']} {info['ns'][:2]}   mail: {info['mail_provider']}")
print(f"  spf: {'MISSING' if not info['spf'] else info['spf_all']+' ('+str(info['spf_lookups'])+' lookups)'}   dmarc: {info['dmarc_policy'] or 'MISSING'}{' +rua' if info['dmarc_rua'] else ''}   dkim selectors: {info['dkim_selectors'] or 'none of the common ones'}   mta-sts: {info['mta_sts']}")
PY
done

if [ ${#HOSTS[@]} -gt 0 ]; then
  echo "== hosts → who serves them =="
  python3 - "$OUT" "${HOSTS[@]}" <<'PY'
import sys,json,subprocess,re,datetime
out=sys.argv[1]; hosts=sys.argv[2:]; res=[]
def dig(n,t): p=subprocess.run(["dig","+short","+time=4","+tries=1",t,n],capture_output=True,text=True); return [l.strip().rstrip(".") for l in p.stdout.splitlines() if l.strip()]
def whois(ip):
    try: return subprocess.run(["whois",ip],capture_output=True,text=True,timeout=15).stdout
    except Exception: return ""
guess={"amazon":"AWS","amazonaws":"AWS","cloudfront":"CloudFront (AWS)","vercel":"Vercel","netlify":"Netlify","fly.dev":"Fly.io","onrender":"Render","render":"Render","herokuapp":"Heroku","heroku":"Heroku","railway":"Railway","cloudflare":"Cloudflare","google":"Google Cloud","googleusercontent":"Google Cloud","digitalocean":"DigitalOcean","hetzner":"Hetzner","ovh":"OVH","linode":"Linode / Akamai","akamai":"Akamai","fastly":"Fastly","microsoft":"Azure","azure":"Azure","github":"GitHub Pages","webflow":"Webflow","squarespace":"Squarespace","wix":"Wix","shopify":"Shopify","hubspot":"HubSpot","framer":"Framer","contabo":"Contabo","oracle":"Oracle Cloud","scaleway":"Scaleway","upcloud":"UpCloud","vultr":"Vultr"}
for h in hosts:
    chain=dig(h,"CNAME"); ips=[x for x in dig(h,"A") if re.match(r"^\d+\.\d+\.\d+\.\d+$",x)][:3]
    for ip in ips[:1]:
        w=whois(ip); org=None
        for k in ("OrgName","org-name","Organization","owner","descr","netname"):
            m=re.search(r"(?im)^%s\s*:\s*(.+)$" % k,w)
            if m: org=m.group(1).strip(); break
    blob=(" ".join(chain)+" "+(org or "")).lower(); p=next((v for k,v in guess.items() if k in blob),"unknown")
    res.append({"host":h,"cname":chain,"ips":ips,"ip_owner":org,"provider":p}); print(f"  {h:<36} → {p:<20} cname={chain[:1]} ip={ips[:1]} owner={org}")
json.dump({"collected":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"hosts":res},open(f"{out}/hosts-{datetime.date.today()}.json","w"),indent=1)
PY
fi
echo "done → $OUT   (registrar ACCOUNT ownership, auto-renew and 2FA are screenshot-only: ask for the registrar account page)"
