#!/usr/bin/env python3
"""Build DIGEST.md from the JSON written by aws-audit-inventory.sh.

Pure read of local files. The CloudTrail section applies the append-only rule set from
references/cloudtrail-append-only.md and prints PASS / FAIL / WARN per rule so the model can
quote it rather than re-derive it. Everything else is a summary; the JSON next to it is the
evidence.
"""
import json, sys, os, datetime

out, acct, region = sys.argv[1:4]
today = datetime.date.today()

def L(n):
    try: return json.load(open(f"{out}/{n}.json"))
    except Exception: return None
def ok(x): return isinstance(x, (list, dict)) and not (isinstance(x, dict) and "error" in x)
def age_days(s):
    try: return (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))).days
    except Exception: return None

md = [f"# Infra audit inventory — account {acct}, region {region} — {today}", ""]

# ---------- identity ----------
summ = L("iam_account_summary"); sm = summ.get("SummaryMap", {}) if ok(summ) else {}
md += ["## Identity & access", ""]
if sm:
    md += [f"- Root MFA enabled: **{'yes' if sm.get('AccountMFAEnabled') == 1 else 'NO'}**",
           f"- Root access keys present: **{'YES — remove' if sm.get('AccountAccessKeysPresent') else 'no'}**",
           f"- IAM users: {sm.get('Users')}, roles: {sm.get('Roles')}, MFA devices: {sm.get('MFADevices')} (in use: {sm.get('MFADevicesInUse')})"]
cr = L("iam_credential_report")
if ok(cr) and cr.get("Content"):
    import base64, csv, io
    rows = list(csv.DictReader(io.StringIO(base64.b64decode(cr["Content"]).decode())))
    md += ["", "| User | Console pw | MFA | Key 1 (age d / last used) | Key 2 (age d / last used) |", "|---|---|---|---|---|"]
    for r in rows:
        def key(n):
            if r.get(f"access_key_{n}_active") != "true": return "—"
            a = age_days(r.get(f"access_key_{n}_last_rotated")); lu = r.get(f"access_key_{n}_last_used_date", "N/A")[:10]
            flag = " **(>90d)**" if (a or 0) > 90 else ""
            return f"{a}{flag} / {lu}"
        pw = r.get("password_enabled"); mfa = r.get("mfa_active")
        pwtxt = "yes" if pw == "true" else ("root" if r["user"] == "<root_account>" else "no")
        mfatxt = ("yes" if mfa == "true" else "**NO**") if pw == "true" or r["user"] == "<root_account>" else "n/a"
        md.append(f"| {r['user']} | {pwtxt} | {mfatxt} | {key(1)} | {key(2)} |")
    md.append("")
pp = L("iam_password_policy")
md.append(f"- Password policy: {'**none set** (AWS default: 8 chars, no rotation)' if not ok(pp) else 'set — ' + ', '.join(f'{k}={v}' for k, v in pp.get('PasswordPolicy', {}).items() if k in ('MinimumPasswordLength', 'RequireUppercaseCharacters', 'RequireNumbers', 'MaxPasswordAge'))}")
aa = L("accessanalyzer_analyzers")
md.append(f"- IAM Access Analyzer: {'**none**' if not (ok(aa) and aa) else ', '.join(a['Name'] + ' (' + a['Status'] + ')' for a in aa)}")
md.append("")

# ---------- cloudtrail append-only verdict ----------
md += ["## CloudTrail — append-only verdict", "",
       "Rules from `references/cloudtrail-append-only.md`. PASS/FAIL are required; WARN is recommended.", ""]
det = L("cloudtrail_detail") or []
trails = L("cloudtrail_trails"); tl = trails.get("trailList", []) if ok(trails) else []
if not tl:
    md += ["**FAIL — no CloudTrail trail exists in this account.** Management events are only visible for 90 days in Event History, nowhere durable, and nothing is tamper-proof.", ""]
for d in det:
    t = d["trail"]; st = d.get("status", {}); es = d.get("event_selectors", {}); bk = d.get("bucket", {})
    rows = []
    def rule(name, cond, evidence, level="req"):
        rows.append((("PASS" if cond else "FAIL") if level == "req" else ("OK" if cond else "WARN"), name, evidence))
    rule("Trail is logging", st.get("IsLogging") is True, f"IsLogging={st.get('IsLogging')}")
    lat = age_days(st.get("LatestDeliveryTime")); rule("Delivered in the last 24h", lat is not None and lat <= 1, f"LatestDeliveryTime={st.get('LatestDeliveryTime')}")
    rule("Multi-region", t.get("IsMultiRegionTrail") is True, f"IsMultiRegionTrail={t.get('IsMultiRegionTrail')} home={t.get('HomeRegion')}")
    rule("Global service events (IAM/STS/CloudFront)", t.get("IncludeGlobalServiceEvents") is True, f"IncludeGlobalServiceEvents={t.get('IncludeGlobalServiceEvents')}")
    sel = (es.get("EventSelectors") or [{}])[0] if isinstance(es, dict) and es.get("EventSelectors") else (es.get("AdvancedEventSelectors") and {"ReadWriteType": "advanced", "IncludeManagementEvents": True}) or {}
    rule("Management events, read + write", sel.get("IncludeManagementEvents") is True and sel.get("ReadWriteType") in ("All", "advanced"), f"ReadWriteType={sel.get('ReadWriteType')} IncludeManagementEvents={sel.get('IncludeManagementEvents')}")
    rule("Log file validation (digests)", t.get("LogFileValidationEnabled") is True, f"LogFileValidationEnabled={t.get('LogFileValidationEnabled')} LatestDigest={st.get('LatestDigestDeliveryTime')}")
    ol = (bk.get("object_lock") or {}).get("ObjectLockConfiguration", {}) if isinstance(bk.get("object_lock"), dict) else {}
    dr = (ol.get("Rule") or {}).get("DefaultRetention", {})
    rule("S3 Object Lock enabled on the log bucket", ol.get("ObjectLockEnabled") == "Enabled", f"bucket={t.get('S3BucketName')} ObjectLockEnabled={ol.get('ObjectLockEnabled')}")
    yrs = dr.get("Years") or (dr.get("Days") or 0) / 365
    rule("Default retention COMPLIANCE mode, >= 1 year", dr.get("Mode") == "COMPLIANCE" and (yrs or 0) >= 1, f"Mode={dr.get('Mode')} Years={dr.get('Years')} Days={dr.get('Days')}")
    so = bk.get("sample_object", {}); ret = (so.get("retention") or {}).get("Retention", {}) if isinstance(so.get("retention"), dict) else {}
    rule("A real log object carries COMPLIANCE retention", ret.get("Mode") == "COMPLIANCE", f"key={str(so.get('key'))[-60:]} Mode={ret.get('Mode')} RetainUntil={ret.get('RetainUntilDate')}")
    rule("Bucket versioning enabled", (bk.get("versioning") or {}).get("Status") == "Enabled", f"Status={(bk.get('versioning') or {}).get('Status')}")
    pab = (bk.get("public_access_block") or {}).get("PublicAccessBlockConfiguration", {}) if isinstance(bk.get("public_access_block"), dict) else {}
    rule("All four public-access blocks on", all(pab.get(k) for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")), f"{pab or 'no PAB configured'}")
    pol = bk.get("policy") if isinstance(bk.get("policy"), dict) and "Statement" in bk.get("policy", {}) else {}
    stmts = pol.get("Statement", []) if pol else []
    def has_deny(actions):
        for s in stmts:
            if s.get("Effect") != "Deny": continue
            acts = s.get("Action") if isinstance(s.get("Action"), list) else [s.get("Action")]
            if any(a in acts or a.split(":")[0] + ":*" in acts or "*" in acts for a in actions): return True
        return False
    rule("Bucket policy denies DeleteBucket / DeleteBucketPolicy", has_deny(["s3:DeleteBucket", "s3:DeleteBucketPolicy"]), "policy present" if pol else "no bucket policy readable")
    write_ok = any(s.get("Effect") == "Allow" and "cloudtrail.amazonaws.com" in json.dumps(s.get("Principal")) and "s3:PutObject" in json.dumps(s.get("Action")) and "aws:SourceAccount" in json.dumps(s.get("Condition", {})) for s in stmts)
    rule("Only the CloudTrail service may write, scoped to this account", write_ok, "PutObject allow with aws:SourceAccount condition" if write_ok else "missing or unconditioned")
    enc = (bk.get("encryption") or {}).get("ServerSideEncryptionConfiguration", {}).get("Rules", [{}]) if isinstance(bk.get("encryption"), dict) else [{}]
    alg = (enc[0].get("ApplyServerSideEncryptionByDefault") or {}).get("SSEAlgorithm") if enc else None
    rule("Bucket default encryption", alg is not None, f"SSEAlgorithm={alg}")
    rule("KMS key (rather than SSE-S3) for the logs", alg == "aws:kms", f"SSEAlgorithm={alg}", level="rec")
    rule("Lifecycle rule to expire logs after the retention window (cost)", isinstance(bk.get("lifecycle"), dict) and "Rules" in bk.get("lifecycle", {}), "present" if isinstance(bk.get("lifecycle"), dict) and "Rules" in bk.get("lifecycle", {}) else "none — bucket grows forever", level="rec")
    ta = d.get("tamper_alerting", {}); rules_txt = json.dumps(ta.get("eventbridge_rules", {})) + json.dumps(ta.get("metric_filters", {}))
    alert = any(k in rules_txt for k in ("StopLogging", "DeleteTrail", "UpdateTrail", "PutBucketPolicy", "PutObjectRetention", "cloudtrail"))
    rule("Alert on StopLogging / DeleteTrail / UpdateTrail / PutBucketPolicy", alert, "EventBridge rule or metric filter mentions these" if alert else "none found — an admin can silently stop the trail (existing logs stay locked)", level="rec")
    rule("Delivered from a separate (log-archive) account", t.get("IsOrganizationTrail") is True, f"IsOrganizationTrail={t.get('IsOrganizationTrail')} — single-account trails protect the *logs*, not the *trail*", level="rec")
    fails = sum(1 for r in rows if r[0] == "FAIL"); warns = sum(1 for r in rows if r[0] == "WARN")
    verdict = "**APPEND-ONLY: PASS**" if fails == 0 else f"**APPEND-ONLY: FAIL ({fails} required rule(s) failing)**"
    md += [f"### Trail `{t.get('Name')}` → s3://{t.get('S3BucketName')} — {verdict}, {warns} recommendation(s)", "", "| Result | Rule | Evidence |", "|---|---|---|"]
    md += [f"| {'**' + r[0] + '**' if r[0] in ('FAIL', 'WARN') else r[0]} | {r[1]} | {r[2]} |" for r in rows]
    md.append("")
eds = L("cloudtrail_event_data_stores")
if ok(eds) and eds.get("EventDataStores"): md += [f"- CloudTrail Lake event data stores: {len(eds['EventDataStores'])} (queryable, but not a substitute for a locked S3 copy)", ""]

# ---------- detective controls ----------
md += ["## Detective controls", ""]
gd = L("guardduty_detectors"); md.append(f"- GuardDuty: {'enabled (' + str(len(gd['DetectorIds'])) + ' detector)' if ok(gd) and gd.get('DetectorIds') else '**not enabled** in ' + region}")
sh = L("securityhub_hub"); md.append(f"- Security Hub: {'enabled' if ok(sh) and sh.get('HubArn') else 'not enabled'}")
cfg = L("config_recorders"); md.append(f"- AWS Config recorder: {'recording' if ok(cfg) and any(r.get('recording') for r in cfg.get('ConfigurationRecordersStatus', [])) else 'not recording'}")
al = L("cloudwatch_alarms"); md.append(f"- CloudWatch alarms: {len(al) if ok(al) else 'n/a'} ({sum(1 for a in (al or []) if ok(al) and a.get('Actions')) if ok(al) else 'n/a'} with actions)")
b = L("budgets"); md.append(f"- Budgets: {len(b['Budgets']) if ok(b) and b.get('Budgets') else '**none**'}")
md.append("")

# ---------- compute ----------
ec2 = L("ec2_instances")
if ok(ec2):
    running = [i for i in ec2 if i["State"] == "running"]
    md += [f"## EC2 — {len(ec2)} instances, {len(running)} running", "", "| Id | Name | Type | Launched | Public IP | IMDSv2 | IAM profile | ASG | Key pair |", "|---|---|---|---|---|---|---|---|---|"]
    for i in sorted(ec2, key=lambda i: (i["State"] != "running", i["Launch"])):
        tags = {t["Key"]: t["Value"] for t in (i.get("Tags") or [])}
        md.append(f"| {i['Id']} | {tags.get('Name', '(untagged)')} | {i['Type']} | {str(i['Launch'])[:10]} | {i.get('PublicIp') or '—'} | {'required' if i.get('Imds') == 'required' else '**optional (v1 allowed)**'} | {(i.get('Profile') or 'none').split('/')[-1]} | {i.get('Asg') or '**none**'} | {i.get('Key') or '—'} |")
    md += ["", "Bare EC2 with no ASG and no health check = a crash or OOM is a manual recovery (checklist Q9).", ""]
sg = L("ec2_security_groups")
if ok(sg):
    PORTS = {22: "SSH", 3389: "RDP", 27017: "MongoDB", 5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 1433: "SQL Server", 9200: "Elasticsearch", 5984: "CouchDB", 11211: "Memcached", 9000: "app/minio", 8080: "app", 2375: "docker", 2376: "docker"}
    hits = []
    for g in sg:
        for p in g.get("In", []):
            fr, to = p.get("FromPort"), p.get("ToPort")
            world = any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", []))
            if not world: continue
            if fr is None or fr == -1: hits.append(f"- `{g['Id']}` ({g['Name']}): **all traffic** open to the world"); continue
            for port, name in PORTS.items():
                if fr <= port <= to: hits.append(f"- `{g['Id']}` ({g['Name']}): **{name} {port}** open to 0.0.0.0/0")
    md += ["## Security groups — sensitive ports open to the world", ""] + (hits or ["- none"]) + [""]
enc = L("ec2_ebs_encryption_default"); vols = L("ec2_volumes")
if ok(vols):
    un = [v for v in vols if not v.get("Encrypted")]
    md += [f"## EBS — {len(vols)} volumes, **{len(un)} unencrypted**; encryption-by-default: {enc.get('EbsEncryptionByDefault') if ok(enc) else 'n/a'}", ""]
amis = L("ec2_public_amis")
if ok(amis) and amis: md += [f"**{len(amis)} PUBLIC AMIs owned by this account:** " + ", ".join(a['Id'] for a in amis), ""]
asg = L("autoscaling_groups"); ecs = L("ecs_services"); lam = L("lambda_functions"); eb = L("eb_environments"); ar = L("apprunner_services"); ls = L("lightsail_instances")
md += ["## Compute platforms in use (checklist Q4/Q5/Q9)", ""]
md.append(f"- Auto Scaling groups: {len(asg) if ok(asg) else 'n/a'}")
if ok(ecs):
    md.append(f"- ECS services: {len([e for e in ecs if e.get('service')])}")
    for e in ecs:
        if e.get("service"):
            c = e["taskDef"]["containers"]
            md.append(f"  - `{e['service']}` on {e['launchType']}: desired={e['desired']} running={e['running']} circuit-breaker={(e.get('deploymentCircuitBreaker') or {}).get('enable')} container-healthcheck={any(k['healthCheck'] for k in c)} secrets={sum(k['secrets'] for k in c)} plain-env={sum(k['plainEnv'] for k in c)} logs={[k['logDriver'] for k in c]}")
if ok(lam):
    old = [f for f in lam if any(x in (f.get("Runtime") or "") for x in ("nodejs14", "nodejs16", "nodejs18", "python3.7", "python3.8", "python3.9", "ruby2", "go1.x", "dotnet6"))]
    md.append(f"- Lambda functions: {len(lam)}; **{len(old)} on deprecated/EOL runtimes**: " + ", ".join(f['Name'] + ' (' + f['Runtime'] + ')' for f in old[:8]))
if ok(eb) and eb: md.append(f"- Elastic Beanstalk environments: {len(eb)} — " + ", ".join(f"{e['Name']} ({e['Health']})" for e in eb))
if ok(ar) and ar.get("ServiceSummaryList"): md.append(f"- App Runner services: {len(ar['ServiceSummaryList'])}")
if ok(ls) and ls: md.append(f"- Lightsail instances: {len(ls)} — " + ", ".join(f"{i['Name']} ({i['Blueprint']}, {i['State']})" for i in ls))
md.append("")

# ---------- data stores ----------
md += ["## Data stores (checklist Q2/Q3/Q8)", ""]
rds = L("rds_instances")
if ok(rds) and rds:
    md += ["| RDS instance | Engine | Class | Multi-AZ | Public | Encrypted | Backup days | Delete-protect | Managed pw (Secrets Mgr) |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rds:
        mp = r.get("ManagedPassword"); md.append(f"| {r['Id']} | {r['Engine']} {r['Version']} | {r['Class']} | {r['MultiAZ']} | {'**YES**' if r['Public'] else 'no'} | {r['Encrypted']} | {'**0**' if not r['BackupDays'] else r['BackupDays']} | {r['DeleteProtect']} | {'yes (' + str(mp.get('SecretStatus')) + ')' if mp else '**no**'} |")
    md.append("")
rc = L("rds_clusters")
if ok(rc) and rc:
    md += ["| RDS/Aurora cluster | Engine | Backup days | Delete-protect | Managed pw | Serverless v2 |", "|---|---|---|---|---|---|"]
    for r in rc: md.append(f"| {r['Id']} | {r['Engine']} {r['Version']} | {r['BackupDays']} | {r['DeleteProtect']} | {'yes' if r.get('ManagedPassword') else '**no**'} | {bool(r.get('Serverless'))} |")
    md.append("")
if not ((ok(rds) and rds) or (ok(rc) and rc)): md += ["- No RDS/Aurora. If the app has a relational or document database, it is self-hosted or off-AWS — confirm with the SSH sweep (`listening-ports`, `databases on this box`).", ""]
dd = L("dynamodb_detail")
if ok(dd) and dd:
    nop = [t for t, v in dd.items() if v.get("pitr") != "ENABLED"]
    md += [f"- DynamoDB: {len(dd)} tables; **{len(nop)} without point-in-time recovery**: " + ", ".join(nop[:10]), ""]
for n, t in [("docdb_clusters", "DocumentDB"), ("elasticache_clusters", "ElastiCache"), ("redshift_clusters", "Redshift"), ("lightsail_databases", "Lightsail managed DB")]:
    x = L(n)
    if ok(x) and x: md += [f"- {t}: " + "; ".join(json.dumps(i, default=str)[:160] for i in x), ""]
bp = L("backup_plans"); bv = L("backup_vaults")
md.append(f"- AWS Backup plans: {len(bp) if ok(bp) and bp else 'none'}; vaults with recovery points: {[v['Name'] for v in bv if v.get('Points')] if ok(bv) else 'n/a'}")
ms = L("rds_snapshots_manual"); md.append(f"- Manual RDS snapshots: {len(ms) if ok(ms) else 'n/a'}")
sec = L("secretsmanager_secrets")
if ok(sec):
    rot = [s for s in sec if s.get("Rotation")]
    md.append(f"- Secrets Manager: {len(sec)} secrets, {len(rot)} with rotation on" + (" — " + ", ".join(s['Name'][:40] for s in sec[:8]) if sec else ""))
sp = L("ssm_parameters")
if ok(sp): md.append(f"- SSM parameters: {len(sp)} ({sum(1 for p in sp if p.get('Type') == 'SecureString')} SecureString)")
md.append("")

# ---------- storage & edge ----------
s3 = L("s3_bucket_config")
if ok(s3):
    pub = [b["Name"] for b in s3 if (b.get("policy_status") or {}).get("PolicyStatus", {}).get("IsPublic") or b.get("acl_public")]
    nopab = [b["Name"] for b in s3 if "error" in (b.get("public_access_block") or {})]
    noenc = [b["Name"] for b in s3 if "error" in (b.get("encryption") or {})]
    apab = L("s3_account_pab"); apab_on = ok(apab) and all((apab.get("PublicAccessBlockConfiguration") or {}).values())
    md += [f"## S3 — {len(s3)} buckets", "", f"- Account-level public access block: {'on' if apab_on else '**off / partial**'}",
           f"- **Public buckets (policy or ACL): {len(pub)}** " + ", ".join(pub[:10]), f"- Buckets with no bucket-level PAB: {len(nopab)}", f"- Buckets with no default encryption: {len(noenc)}", ""]
cf = L("cloudfront_distributions")
if ok(cf) and cf: md += [f"## CloudFront — {len(cf)} distributions, {sum(1 for d in cf if not d.get('WebACL'))} without a WAF; viewer policies: {sorted(set(d.get('ViewerProtocol') or '' for d in cf))}", ""]
acm = L("acm_certificates")
if ok(acm) and acm:
    bad = [c for c in acm if c.get("Status") != "ISSUED" or (age_days(c.get("NotAfter")) or 0) > -30]
    md += [f"## ACM — {len(acm)} certificates; {len(bad)} expiring within 30d or not ISSUED: " + ", ".join(c['Domain'] for c in bad[:6]), ""]
lg = L("logs_groups")
if ok(lg): md += [f"## CloudWatch Logs — {len(lg)} groups, {sum(1 for g in lg if not g.get('RetentionDays'))} never expire, {sum(g.get('StoredBytes', 0) for g in lg) / 1e9:.1f} GB total", ""]
orr = L("other_regions") or {}
nz = {k: v for k, v in orr.items() if any(x not in (0, "error") for x in v.values())}
md += [f"## Other regions: {nz if nz else 'nothing found (EC2/RDS/Lambda sweep only)'}", ""]
errs = [f for f in os.listdir(out) if f.endswith(".json") and isinstance(L(f[:-5]), dict) and "error" in L(f[:-5])]
if errs: md += ["## Probes that failed (permissions or service not enabled)", ""] + [f"- `{e}`: {L(e[:-5])['error'][:160]}" for e in sorted(errs)] + [""]
md += ["---", "Every line above is from a read-only API call saved next to this file. Off-AWS providers (Vercel, Render, Clerk, Hetzner, Atlas, Datadog…) are not here — inventory them from the repo, DNS, env files, and the billing emails (checklist Q4–Q6, Q10, Q11)."]
open(f"{out}/DIGEST.md", "w").write("\n".join(md)); print(f"  wrote {out}/DIGEST.md")
