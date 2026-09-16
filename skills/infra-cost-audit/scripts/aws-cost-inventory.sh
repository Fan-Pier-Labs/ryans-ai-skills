#!/usr/bin/env bash
# infra-cost-review: read-only AWS inventory for the cost review.
#
#   scripts/aws-cost-inventory.sh --profile <p> [--region us-east-1] [--days 14] [--out <dir>]
#
# Writes one JSON file per probe into <out>/ plus DIGEST.md. Never mutates anything:
# every call is describe-/get-/list-. A missing permission becomes an "error" field
# in that probe's JSON instead of aborting the run, so a partial inventory is still useful.
#
# Env: AWS_PAGER is disabled; set INFRA_COST_SKIP="ce lightsail" to skip probes.
set -uo pipefail
export AWS_PAGER=""; export PROFILE_FOR_PY=""

PROFILE=""; REGION=""; DAYS=14; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    --days)    DAYS="$2";    shift 2;;
    --out)     OUT="$2";     shift 2;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
export PROFILE_FOR_PY="$PROFILE"
[ -z "$PROFILE" ] && { echo "--profile is required (never rely on the default profile)" >&2; exit 2; }
A=(aws --profile "$PROFILE" --output json)
[ -n "$REGION" ] && A+=(--region "$REGION")

IDENT=$("${A[@]}" sts get-caller-identity 2>&1) || { echo "cannot authenticate with profile $PROFILE:"; echo "$IDENT"; exit 1; }
ACCOUNT=$(echo "$IDENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Account"])')
[ -z "$REGION" ] && REGION=$(aws --profile "$PROFILE" configure get region 2>/dev/null || echo us-east-1)
[ -z "$OUT" ] && OUT="./infra-cost-review-${ACCOUNT}-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
echo "$IDENT" > "$OUT/identity.json"
echo "account=$ACCOUNT region=$REGION days=$DAYS out=$OUT"

# probe <name> <aws args...>  — runs one read-only call, captures errors as JSON.
probe() {
  local name="$1"; shift
  case " ${INFRA_COST_SKIP:-} " in *" ${name%%_*} "*) echo "  skip $name"; return;; esac
  if out=$("${A[@]}" "$@" 2>&1); then printf '%s\n' "$out" > "$OUT/$name.json"; echo "  ok   $name"
  else python3 -c 'import json,sys;print(json.dumps({"error":sys.argv[1].strip()[:800]}))' "$out" > "$OUT/$name.json"; echo "  ERR  $name: $(echo "$out" | head -c 160)"; fi
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
M0=$(date -u +%Y-%m-01)
M3=$(date -u -v-3m +%Y-%m-01 2>/dev/null || date -u -d "-3 months" +%Y-%m-01)
M1=$(date -u -v-1m +%Y-%m-01 2>/dev/null || date -u -d "-1 month" +%Y-%m-01)

echo "== cost =="
probe ce_by_service ce get-cost-and-usage --time-period Start="$M3",End="$M0" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
probe ce_by_usage_type ce get-cost-and-usage --time-period Start="$M1",End="$M0" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=USAGE_TYPE
probe ce_by_region ce get-cost-and-usage --time-period Start="$M1",End="$M0" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=REGION
probe ce_daily ce get-cost-and-usage --time-period Start="$M1",End="$M0" --granularity DAILY --metrics UnblendedCost
probe budgets budgets describe-budgets --account-id "$ACCOUNT"
probe ce_anomaly_monitors ce get-anomaly-monitors

echo "== compute =="
probe ec2_instances ec2 describe-instances --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Launch:LaunchTime,AZ:Placement.AvailabilityZone,PublicIp:PublicIpAddress,Tags:Tags,Volumes:BlockDeviceMappings[].Ebs.VolumeId,SGs:SecurityGroups[].GroupId}'
probe ec2_addresses ec2 describe-addresses
probe ec2_volumes_available ec2 describe-volumes --filters Name=status,Values=available
probe ec2_volumes_all ec2 describe-volumes --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,State:State,Attached:Attachments[0].InstanceId,Created:CreateTime}'
probe ec2_snapshots ec2 describe-snapshots --owner-ids self --query 'Snapshots[].{Id:SnapshotId,GB:VolumeSize,Start:StartTime,Desc:Description,Volume:VolumeId}'
probe ec2_images ec2 describe-images --owners self --query 'Images[].{Id:ImageId,Name:Name,Created:CreationDate}'
probe ec2_nat_gateways ec2 describe-nat-gateways
probe ec2_security_groups ec2 describe-security-groups --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,In:IpPermissions}'
probe elbv2_load_balancers elbv2 describe-load-balancers
probe elbv2_target_groups elbv2 describe-target-groups
probe ecs_clusters ecs list-clusters
probe lambda_functions lambda list-functions --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Mem:MemorySize,Modified:LastModified}'
probe eb_environments elasticbeanstalk describe-environments --query 'Environments[].{Name:EnvironmentName,App:ApplicationName,Status:Status,Health:Health,Updated:DateUpdated}'

echo "== lightsail (bills stopped instances at full price) =="
probe lightsail_instances lightsail get-instances --query 'instances[].{Name:name,Bundle:bundleId,State:state.name,Created:createdAt,Ip:publicIpAddress,StaticIp:isStaticIp}'
probe lightsail_static_ips lightsail get-static-ips --query 'staticIps[].{Name:name,Ip:ipAddress,AttachedTo:attachedTo,IsAttached:isAttached}'
probe lightsail_snapshots lightsail get-instance-snapshots --query 'instanceSnapshots[].{Name:name,GB:sizeInGb,Created:createdAt,From:fromInstanceName,State:state}'
probe lightsail_disks lightsail get-disks --query 'disks[].{Name:name,GB:sizeInGb,State:state,AttachedTo:attachedTo}'
probe lightsail_databases lightsail get-relational-databases --query 'relationalDatabases[].{Name:name,Bundle:relationalDatabaseBundleId,Engine:engine,State:state,Created:createdAt}'
probe lightsail_load_balancers lightsail get-load-balancers --query 'loadBalancers[].{Name:name,State:state}'

echo "== databases =="
probe rds_instances rds describe-db-instances --query 'DBInstances[].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Status:DBInstanceStatus,MultiAZ:MultiAZ,GB:AllocatedStorage,Created:InstanceCreateTime,Cluster:DBClusterIdentifier}'
probe rds_clusters rds describe-db-clusters --query 'DBClusters[].{Id:DBClusterIdentifier,Engine:Engine,Status:Status,Members:DBClusterMembers[].DBInstanceIdentifier,Created:ClusterCreateTime}'
probe docdb_clusters docdb describe-db-clusters --query 'DBClusters[].{Id:DBClusterIdentifier,Engine:Engine,Version:EngineVersion,Status:Status,Members:DBClusterMembers[].DBInstanceIdentifier}'
probe dynamodb_tables dynamodb list-tables
probe elasticache_clusters elasticache describe-cache-clusters --query 'CacheClusters[].{Id:CacheClusterId,Node:CacheNodeType,Engine:Engine,Status:CacheClusterStatus}'

echo "== storage / logs / misc =="
probe s3_buckets s3api list-buckets --query 'Buckets[].{Name:Name,Created:CreationDate}'
probe logs_groups logs describe-log-groups --query 'logGroups[].{Name:logGroupName,RetentionDays:retentionInDays,StoredBytes:storedBytes}'
probe route53_zones route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Records:ResourceRecordSetCount}'
probe cloudfront_distributions cloudfront list-distributions --query 'DistributionList.Items[].{Id:Id,Aliases:Aliases.Items,Enabled:Enabled,WebACL:WebACLId}'
probe secretsmanager_secrets secretsmanager list-secrets --query 'SecretList[].{Name:Name,LastAccessed:LastAccessedDate,Rotation:RotationEnabled}'
probe workmail_orgs workmail list-organizations
probe regions ec2 describe-regions --query 'Regions[].RegionName'

echo "== per-bucket lifecycle (read-only) =="
python3 - "$OUT" <<'EOF'
import json,sys,subprocess,os
out=sys.argv[1]
try: buckets=json.load(open(f"{out}/s3_buckets.json"))
except Exception: buckets=[]
res=[]
for b in buckets if isinstance(buckets,list) else []:
    n=b["Name"]; r={"Name":n}
    for k,cmd in {"lifecycle":["s3api","get-bucket-lifecycle-configuration"],"versioning":["s3api","get-bucket-versioning"]}.items():
        p=subprocess.run(["aws","--profile",os.environ.get("PROFILE_FOR_PY",""),"--output","json",*cmd,"--bucket",n],capture_output=True,text=True)
        r[k]=json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else {"error":p.stderr.strip()[:200] or "none"}
    res.append(r)
json.dump(res,open(f"{out}/s3_bucket_config.json","w"),indent=1); print(f"  ok   s3_bucket_config ({len(res)} buckets)")
EOF

echo "== per-instance CPU (${DAYS}d avg/max) =="
python3 - "$OUT" "$START" "$NOW" "$PROFILE" "$REGION" <<'EOF'
import json,sys,subprocess
out,start,now,profile,region=sys.argv[1:]
try: inst=json.load(open(f"{out}/ec2_instances.json"))
except Exception: inst=[]
res={}
for i in inst if isinstance(inst,list) else []:
    if i.get("State")!="running": continue
    p=subprocess.run(["aws","--profile",profile,"--region",region,"--output","json","cloudwatch","get-metric-statistics","--namespace","AWS/EC2","--metric-name","CPUUtilization","--dimensions",f"Name=InstanceId,Value={i['Id']}","--start-time",start,"--end-time",now,"--period","3600","--statistics","Average","Maximum"],capture_output=True,text=True)
    try:
        dp=json.loads(p.stdout)["Datapoints"]
        res[i["Id"]]={"avg":round(sum(d["Average"] for d in dp)/len(dp),2) if dp else None,"max":round(max(d["Maximum"] for d in dp),2) if dp else None,"samples":len(dp)}
    except Exception as e: res[i["Id"]]={"error":(p.stderr or str(e))[:200]}
json.dump(res,open(f"{out}/ec2_cpu.json","w"),indent=1); print(f"  ok   ec2_cpu ({len(res)} running instances)")
EOF

echo "== ALB request counts (${DAYS}d) =="
python3 - "$OUT" "$START" "$NOW" "$PROFILE" "$REGION" <<'EOF'
import json,sys,subprocess
out,start,now,profile,region=sys.argv[1:]
try: lbs=json.load(open(f"{out}/elbv2_load_balancers.json")).get("LoadBalancers",[])
except Exception: lbs=[]
res={}
for lb in lbs:
    arn=lb["LoadBalancerArn"]; dim=arn.split("loadbalancer/")[-1]
    ns="AWS/ApplicationELB" if lb.get("Type")=="application" else "AWS/NetworkELB"
    metric="RequestCount" if ns=="AWS/ApplicationELB" else "ActiveFlowCount"
    p=subprocess.run(["aws","--profile",profile,"--region",region,"--output","json","cloudwatch","get-metric-statistics","--namespace",ns,"--metric-name",metric,"--dimensions",f"Name=LoadBalancer,Value={dim}","--start-time",start,"--end-time",now,"--period","86400","--statistics","Sum"],capture_output=True,text=True)
    try: res[lb["LoadBalancerName"]]={"azs":len(lb.get("AvailabilityZones",[])),"type":lb.get("Type"),"sum":sum(d["Sum"] for d in json.loads(p.stdout)["Datapoints"])}
    except Exception as e: res[lb["LoadBalancerName"]]={"azs":len(lb.get("AvailabilityZones",[])),"error":(p.stderr or str(e))[:200]}
json.dump(res,open(f"{out}/elbv2_traffic.json","w"),indent=1); print(f"  ok   elbv2_traffic ({len(res)} load balancers)")
EOF

echo "== other regions (instance counts) =="
python3 - "$OUT" "$PROFILE" "$REGION" <<'EOF'
import json,sys,subprocess
out,profile,home=sys.argv[1:]
try: regions=json.load(open(f"{out}/regions.json"))
except Exception: regions=[]
res={}
for r in regions if isinstance(regions,list) else []:
    if r==home: continue
    p=subprocess.run(["aws","--profile",profile,"--region",r,"--output","json","ec2","describe-instances","--query","length(Reservations[].Instances[])"],capture_output=True,text=True)
    q=subprocess.run(["aws","--profile",profile,"--region",r,"--output","json","ec2","describe-addresses","--query","length(Addresses)"],capture_output=True,text=True)
    res[r]={"instances":json.loads(p.stdout) if p.returncode==0 else "error","eips":json.loads(q.stdout) if q.returncode==0 else "error"}
json.dump(res,open(f"{out}/other_regions.json","w"),indent=1)
nz={k:v for k,v in res.items() if v.get("instances") not in (0,"error") or v.get("eips") not in (0,"error")}
print(f"  ok   other_regions — non-empty: {nz or 'none'}")
EOF

echo "== digest =="
python3 - "$OUT" "$ACCOUNT" "$REGION" "$DAYS" <<'EOF'
import json,sys,os,datetime
out,acct,region,days=sys.argv[1:]
def L(n):
    try: return json.load(open(f"{out}/{n}.json"))
    except Exception: return None
def ok(x): return isinstance(x,(list,dict)) and not (isinstance(x,dict) and "error" in x)
md=[f"# Infra inventory — account {acct}, region {region} — {datetime.date.today()}",""]
ce=L("ce_by_service")
if ok(ce):
    md+=["## Cost by service (last 3 full months, unblended)",""]
    months=ce.get("ResultsByTime",[])
    svc={}
    for idx,m in enumerate(months):
        for g in m["Groups"]:
            row=svc.setdefault(g["Keys"][0],[0.0]*len(months)); row[idx]=float(g["Metrics"]["UnblendedCost"]["Amount"])
    md+=["| Service | "+" | ".join(m["TimePeriod"]["Start"][:7] for m in months)+" |","|---|"+"---:|"*len(months)]
    for k,v in sorted(svc.items(),key=lambda kv:-kv[1][-1])[:20]: md.append(f"| {k} | "+" | ".join(f"${x:,.2f}" for x in v)+" |")
    md+=["","**Total last full month:** $%s"%f"{sum(v[-1] for v in svc.values()):,.2f}",""]
ut=L("ce_by_usage_type")
if ok(ut):
    rows=sorted(((float(g["Metrics"]["UnblendedCost"]["Amount"]),g["Keys"][0]) for g in ut["ResultsByTime"][0]["Groups"]),reverse=True)[:15]
    md+=["## Top usage types (last full month)","","| Usage type | Cost |","|---|---:|"]+[f"| `{k}` | ${v:,.2f} |" for v,k in rows]+[""]
ls=L("lightsail_instances")
if ok(ls) and ls:
    stopped=[i for i in ls if i.get("State")!="running"]
    md+=[f"## Lightsail — {len(ls)} instances, **{len(stopped)} stopped (billing full bundle price)**","","| Name | Bundle | State | Created |","|---|---|---|---|"]+[f"| {i['Name']} | {i['Bundle']} | {'**'+i['State']+'**' if i['State']!='running' else i['State']} | {str(i['Created'])[:10]} |" for i in ls]+[""]
for n,t in [("lightsail_static_ips","Lightsail static IPs"),("lightsail_snapshots","Lightsail snapshots"),("lightsail_disks","Lightsail disks"),("lightsail_databases","Lightsail databases")]:
    x=L(n)
    if ok(x) and x:
        md+=[f"### {t} ({len(x)})","","```json",json.dumps(x,indent=1,default=str)[:4000],"```",""]
ec2=L("ec2_instances"); cpu=L("ec2_cpu") or {}
if ok(ec2):
    md+=[f"## EC2 — {len(ec2)} instances","","| Id | Name | Type | State | Launched | CPU avg/max (%sd) | Tags |"%days,"|---|---|---|---|---|---|---|"]
    for i in sorted(ec2,key=lambda i:(i["State"]!="running",i["Launch"])):
        tags={t["Key"]:t["Value"] for t in (i.get("Tags") or [])}; c=cpu.get(i["Id"],{})
        cputxt=f"{c.get('avg')}/{c.get('max')}" if c.get("avg") is not None else ("—" if i["State"]!="running" else "n/a")
        md.append(f"| {i['Id']} | {tags.get('Name','**(untagged)**')} | {i['Type']} | {i['State']} | {str(i['Launch'])[:10]} | {cputxt} | {len(tags)} |")
    md.append("")
ad=L("ec2_addresses")
if ok(ad):
    A=ad.get("Addresses",[]); idle=[a for a in A if not a.get("AssociationId")]
    md+=[f"## Elastic IPs — {len(A)} allocated, **{len(idle)} unassociated (billed idle)**",""]+[f"- {a['PublicIp']} ({a['AllocationId']}) tags={a.get('Tags')}" for a in idle]+[""]
    stopped_ids={i["Id"] for i in (ec2 or []) if ok(ec2) and i["State"]=="stopped"}
    on_stopped=[a for a in A if a.get("InstanceId") in stopped_ids]
    if on_stopped: md+=[f"**{len(on_stopped)} EIPs attached to stopped instances (billed):** "+", ".join(a['PublicIp'] for a in on_stopped),""]
va=L("ec2_volumes_available")
if ok(va) and va.get("Volumes"): md+=[f"## Unattached EBS volumes: {len(va['Volumes'])} — {sum(v['Size'] for v in va['Volumes'])} GB",""]
sn=L("ec2_snapshots")
if ok(sn) and sn:
    old=[s for s in sn if str(s["Start"])[:4] < str(datetime.date.today().year-2)]
    md+=[f"## EBS snapshots: {len(sn)} total, {sum(s['GB'] for s in sn)} GB; **{len(old)} older than 2 years**",""]
lb=L("elbv2_load_balancers"); tr=L("elbv2_traffic") or {}
if ok(lb) and lb.get("LoadBalancers"):
    md+=[f"## Load balancers — {len(lb['LoadBalancers'])}","","| Name | Type | AZs | Requests (%sd) |"%days,"|---|---|---:|---:|"]
    for l in lb["LoadBalancers"]:
        t=tr.get(l["LoadBalancerName"],{}); az=len(l.get("AvailabilityZones",[]))
        md.append(f"| {l['LoadBalancerName']} | {l.get('Type')} | {'**'+str(az)+'** (each AZ = 1 billed public IPv4)' if az>2 else az} | {t.get('sum','n/a')} |")
    md.append("")
nat=L("ec2_nat_gateways")
if ok(nat) and nat.get("NatGateways"): md+=[f"## NAT gateways: {len([n for n in nat['NatGateways'] if n['State']!='deleted'])} (billed hourly regardless of traffic)",""]
for n,t in [("rds_instances","RDS instances"),("docdb_clusters","DocumentDB clusters"),("elasticache_clusters","ElastiCache clusters"),("lambda_functions","Lambda functions"),("eb_environments","Elastic Beanstalk environments")]:
    x=L(n)
    if ok(x) and x: md+=[f"## {t} ({len(x)})","","```json",json.dumps(x,indent=1,default=str)[:3000],"```",""]
sg=L("ec2_security_groups")
if ok(sg):
    DBPORTS={27017:"MongoDB",5432:"PostgreSQL",3306:"MySQL",6379:"Redis",1433:"SQL Server",9200:"Elasticsearch",5984:"CouchDB",11211:"Memcached"}
    hits=[]
    for g in sg:
        for p in g.get("In",[]):
            fr,to=p.get("FromPort"),p.get("ToPort")
            world=any(r.get("CidrIp")=="0.0.0.0/0" for r in p.get("IpRanges",[]))
            if not world or fr is None: continue
            for port,name in DBPORTS.items():
                if fr<=port<=to: hits.append(f"- `{g['Id']}` ({g['Name']}): **{name} port {port} open to 0.0.0.0/0** — self-hosted-database smell; confirm what listens there")
    if hits: md+=["## Database ports open to the world",""]+hits+[""]
s3=L("s3_bucket_config")
if ok(s3):
    nolc=[b["Name"] for b in s3 if "error" in b.get("lifecycle",{})]
    md+=[f"## S3 — {len(s3)} buckets, **{len(nolc)} with no lifecycle rules**: "+", ".join(nolc[:12]),""]
lg=L("logs_groups")
if ok(lg):
    never=[g for g in lg if not g.get("RetentionDays")]
    md+=[f"## CloudWatch Logs — {len(lg)} groups, **{len(never)} with retention = never expire** ({sum(g.get('StoredBytes',0) for g in never)/1e9:.1f} GB)",""]
b=L("budgets"); am=L("ce_anomaly_monitors")
md+=["## Guardrails","",f"- Budgets: {'**none configured**' if not (ok(b) and b.get('Budgets')) else len(b['Budgets'])}",f"- Cost anomaly monitors: {'**none**' if not (ok(am) and am.get('AnomalyMonitors')) else len(am['AnomalyMonitors'])}"]
if ok(ec2):
    untag=[i for i in ec2 if not any(t['Key']=='Name' for t in (i.get('Tags') or []))]
    costtag=[i for i in ec2 if any(t['Key'].lower() in ('project','owner','environment','env','cost-center','costcenter') for t in (i.get('Tags') or []))]
    md+=[f"- EC2 without a Name tag: {len(untag)} / {len(ec2)}; with any cost-allocation tag (Project/Owner/Environment): {len(costtag)} / {len(ec2)}"]
orr=L("other_regions") or {}
nz={k:v for k,v in orr.items() if v.get("instances") not in (0,"error") or v.get("eips") not in (0,"error")}
md+=[f"- Resources outside {region}: {nz if nz else 'none found (EC2/EIP sweep only — check Cost Explorer by region for the rest)'}",""]
cr=L("ce_by_region")
if ok(cr):
    rows=[(float(g["Metrics"]["UnblendedCost"]["Amount"]),g["Keys"][0]) for g in cr["ResultsByTime"][0]["Groups"]]
    md+=["Cost by region (last full month): "+", ".join(f"{k} ${v:,.2f}" for v,k in sorted(rows,reverse=True) if v>0.01),""]
errs=[f for f in os.listdir(out) if f.endswith(".json") and isinstance(L(f[:-5]),dict) and "error" in L(f[:-5])]
if errs: md+=["## Probes that failed (permissions or service not enabled)",""]+[f"- `{e}`: {L(e[:-5])['error'][:160]}" for e in sorted(errs)]+[""]
md+=["---","Every number above is from a read-only API call saved next to this file. Target prices for recommendations are NOT here — pull them from the Price List API or the pricing page for this region and label them estimates."]
open(f"{out}/DIGEST.md","w").write("\n".join(md)); print(f"  wrote {out}/DIGEST.md")
EOF
echo "done → $OUT/DIGEST.md"
