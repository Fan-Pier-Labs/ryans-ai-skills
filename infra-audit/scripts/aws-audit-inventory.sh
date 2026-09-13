#!/usr/bin/env bash
# infra-audit: read-only AWS inventory for the infrastructure audit.
#
#   scripts/aws-audit-inventory.sh --profile <p> [--region us-east-1] [--out <dir>]
#
# Writes one JSON file per probe into <out>/ plus DIGEST.md, which ends with a CloudTrail
# append-only verdict (see references/cloudtrail-append-only.md for the rule set). Never
# mutates anything: every call is describe-/get-/list-. The one exception is
# `iam generate-credential-report`, which asks IAM to (re)build its own report — a standard
# audit call that changes nothing in the account. A missing permission becomes an "error"
# field in that probe's JSON instead of aborting the run.
#
# Env: AWS_PAGER is disabled; set INFRA_AUDIT_SKIP="iam s3" to skip probe families.
set -uo pipefail
export AWS_PAGER=""

PROFILE=""; REGION=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    --out)     OUT="$2";     shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$PROFILE" ] && { echo "--profile is required (never rely on the default profile)" >&2; exit 2; }
A=(aws --profile "$PROFILE" --output json)
[ -n "$REGION" ] && A+=(--region "$REGION")

IDENT=$("${A[@]}" sts get-caller-identity 2>&1) || { echo "cannot authenticate with profile $PROFILE:"; echo "$IDENT"; exit 1; }
ACCOUNT=$(echo "$IDENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Account"])')
[ -z "$REGION" ] && REGION=$(aws --profile "$PROFILE" configure get region 2>/dev/null || echo us-east-1)
[ -z "$OUT" ] && OUT="./infra-audit-${ACCOUNT}-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
echo "$IDENT" > "$OUT/identity.json"
echo "account=$ACCOUNT region=$REGION out=$OUT"
export PROFILE REGION OUT ACCOUNT

probe() {
  local name="$1"; shift
  case " ${INFRA_AUDIT_SKIP:-} " in *" ${name%%_*} "*) echo "  skip $name"; return;; esac
  if out=$("${A[@]}" "$@" 2>&1); then printf '%s\n' "$out" > "$OUT/$name.json"; echo "  ok   $name"
  else python3 -c 'import json,sys;print(json.dumps({"error":sys.argv[1].strip()[:800]}))' "$out" > "$OUT/$name.json"; echo "  ERR  $name: $(echo "$out" | head -c 160)"; fi
}

echo "== identity & access =="
probe iam_account_summary iam get-account-summary
probe iam_password_policy iam get-account-password-policy
probe iam_users iam list-users --query 'Users[].{Name:UserName,Created:CreateDate,PasswordLastUsed:PasswordLastUsed}'
probe iam_mfa_devices iam list-virtual-mfa-devices --query 'VirtualMFADevices[].{Serial:SerialNumber,User:User.UserName}'
probe iam_roles iam list-roles --query 'Roles[].{Name:RoleName,Created:CreateDate,LastUsed:RoleLastUsed.LastUsedDate}'
"${A[@]}" iam generate-credential-report >/dev/null 2>&1; sleep 3
probe iam_credential_report iam get-credential-report
probe accessanalyzer_analyzers accessanalyzer list-analyzers --query 'analyzers[].{Name:name,Type:type,Status:status}'
probe iam_users_with_inline_or_admin iam list-users --query 'Users[].UserName'

echo "== audit trail (the append-only CloudTrail check) =="
probe cloudtrail_trails cloudtrail describe-trails --include-shadow-trails
probe cloudtrail_event_data_stores cloudtrail list-event-data-stores
python3 - <<'PY'
import json,subprocess,os
out=os.environ["OUT"]; profile=os.environ["PROFILE"]; acct=os.environ["ACCOUNT"]
def aws(*args,region=None):
    cmd=["aws","--profile",profile,"--output","json"]+(["--region",region] if region else [])+list(args)
    p=subprocess.run(cmd,capture_output=True,text=True)
    if p.returncode!=0: return {"error":p.stderr.strip()[:300]}
    try: return json.loads(p.stdout) if p.stdout.strip() else {}
    except Exception: return {"raw":p.stdout[:300]}
try: trails=json.load(open(f"{out}/cloudtrail_trails.json")).get("trailList",[])
except Exception: trails=[]
res=[]
for t in trails:
    home=t.get("HomeRegion"); arn=t.get("TrailARN"); b=t.get("S3BucketName")
    r={"trail":t,"status":aws("cloudtrail","get-trail-status","--name",arn,region=home),
       "event_selectors":aws("cloudtrail","get-event-selectors","--trail-name",arn,region=home),
       "bucket":{}}
    if b:
        loc=aws("s3api","get-bucket-location","--bucket",b); breg=(loc.get("LocationConstraint") or "us-east-1") if isinstance(loc,dict) else None
        bk={"region":breg}
        for k,cmd in {"object_lock":["s3api","get-object-lock-configuration"],"versioning":["s3api","get-bucket-versioning"],
                      "public_access_block":["s3api","get-public-access-block"],"policy":["s3api","get-bucket-policy"],
                      "encryption":["s3api","get-bucket-encryption"],"lifecycle":["s3api","get-bucket-lifecycle-configuration"],
                      "logging":["s3api","get-bucket-logging"],"policy_status":["s3api","get-bucket-policy-status"]}.items():
            bk[k]=aws(*cmd,"--bucket",b,region=breg)
        if isinstance(bk.get("policy"),dict) and "Policy" in bk["policy"]:
            try: bk["policy"]=json.loads(bk["policy"]["Policy"])
            except Exception: pass
        # one real log object: does it carry a COMPLIANCE retention?
        objs=aws("s3api","list-objects-v2","--bucket",b,"--prefix",f"AWSLogs/{acct}/CloudTrail/","--max-keys","200",region=breg)
        key=next((o["Key"] for o in (objs.get("Contents") or []) if o["Key"].endswith(".json.gz")),None) if isinstance(objs,dict) else None
        bk["sample_object"]={"key":key,"retention":aws("s3api","get-object-retention","--bucket",b,"--key",key,region=breg) if key else {"error":"no CloudTrail objects found under AWSLogs/<account>/CloudTrail/"}}
        r["bucket"]=bk
    # alerting on tampering: a metric filter / EventBridge rule for StopLogging, DeleteTrail, UpdateTrail, PutBucketPolicy...
    r["tamper_alerting"]={"eventbridge_rules":aws("events","list-rules",region=home),
                          "metric_filters":aws("logs","describe-metric-filters",region=home) if t.get("CloudWatchLogsLogGroupArn") else {"note":"trail has no CloudWatch Logs group, so no metric filters can exist"}}
    res.append(r)
json.dump(res,open(f"{out}/cloudtrail_detail.json","w"),indent=1,default=str); print(f"  ok   cloudtrail_detail ({len(res)} trails)")
PY

echo "== detective controls =="
probe guardduty_detectors guardduty list-detectors
probe securityhub_hub securityhub describe-hub
probe config_recorders configservice describe-configuration-recorder-status
probe cloudwatch_alarms cloudwatch describe-alarms --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,NS:Namespace,State:StateValue,Actions:AlarmActions}'
probe sns_topics sns list-topics
probe budgets budgets describe-budgets --account-id "$ACCOUNT"

echo "== compute =="
probe ec2_instances ec2 describe-instances --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Launch:LaunchTime,PublicIp:PublicIpAddress,Key:KeyName,Platform:PlatformDetails,Profile:IamInstanceProfile.Arn,Imds:MetadataOptions.HttpTokens,Monitoring:Monitoring.State,Tags:Tags,SGs:SecurityGroups[].GroupId,Volumes:BlockDeviceMappings[].Ebs.VolumeId,Asg:Tags[?Key==`aws:autoscaling:groupName`]|[0].Value}'
probe ec2_security_groups ec2 describe-security-groups --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId,In:IpPermissions}'
probe ec2_ebs_encryption_default ec2 get-ebs-encryption-by-default
probe ec2_volumes ec2 describe-volumes --query 'Volumes[].{Id:VolumeId,Size:Size,Type:VolumeType,Encrypted:Encrypted,Attached:Attachments[0].InstanceId,State:State}'
probe ec2_snapshots ec2 describe-snapshots --owner-ids self --query 'Snapshots[].{Id:SnapshotId,Volume:VolumeId,Start:StartTime,Encrypted:Encrypted,Desc:Description}'
probe ec2_public_amis ec2 describe-images --owners self --query 'Images[?Public==`true`].{Id:ImageId,Name:Name}'
probe autoscaling_groups autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,HealthCheck:HealthCheckType,Instances:length(Instances)}'
probe elbv2_load_balancers elbv2 describe-load-balancers --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type,Scheme:Scheme,AZs:length(AvailabilityZones),Arn:LoadBalancerArn}'
probe elbv2_target_groups elbv2 describe-target-groups --query 'TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port,HC:HealthCheckPath,Type:TargetType}'
probe ecs_clusters ecs list-clusters
probe lambda_functions lambda list-functions --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Mem:MemorySize,Timeout:Timeout,Modified:LastModified,Role:Role,Env:length(Environment.Variables || `{}`)}'
probe eb_environments elasticbeanstalk describe-environments --query 'Environments[].{Name:EnvironmentName,App:ApplicationName,Status:Status,Health:Health,Platform:PlatformArn}'
probe apprunner_services apprunner list-services
probe lightsail_instances lightsail get-instances --query 'instances[].{Name:name,Bundle:bundleId,State:state.name,Created:createdAt,Ip:publicIpAddress,Blueprint:blueprintId}'
probe lightsail_databases lightsail get-relational-databases --query 'relationalDatabases[].{Name:name,Engine:engine,Version:engineVersion,BackupRetention:backupRetentionEnabled,Public:publiclyAccessible,State:state}'

echo "== ecs services / task definitions (crash resilience) =="
python3 - <<'PY'
import json,subprocess,os
out=os.environ["OUT"]; profile=os.environ["PROFILE"]; region=os.environ["REGION"]
def aws(*a):
    p=subprocess.run(["aws","--profile",profile,"--region",region,"--output","json"]+list(a),capture_output=True,text=True)
    try: return json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else {"error":p.stderr.strip()[:200]}
    except Exception as e: return {"error":str(e)}
try: clusters=json.load(open(f"{out}/ecs_clusters.json")).get("clusterArns",[])
except Exception: clusters=[]
res=[]
for c in clusters:
    svcs=aws("ecs","list-services","--cluster",c).get("serviceArns",[])
    if not svcs: res.append({"cluster":c,"services":[]}); continue
    d=aws("ecs","describe-services","--cluster",c,"--services",*svcs[:10])
    for s in d.get("services",[]):
        td=aws("ecs","describe-task-definition","--task-definition",s["taskDefinition"]).get("taskDefinition",{})
        res.append({"cluster":c,"service":s["serviceName"],"launchType":s.get("launchType") or [x.get("capacityProvider") for x in s.get("capacityProviderStrategy",[])],
                    "desired":s.get("desiredCount"),"running":s.get("runningCount"),"deploymentCircuitBreaker":s.get("deploymentConfiguration",{}).get("deploymentCircuitBreaker"),
                    "healthCheckGrace":s.get("healthCheckGracePeriodSeconds"),"loadBalancers":len(s.get("loadBalancers",[])),
                    "taskDef":{"cpu":td.get("cpu"),"memory":td.get("memory"),"containers":[{"name":k.get("name"),"image":(k.get("image") or "")[:80],"healthCheck":bool(k.get("healthCheck")),"secrets":len(k.get("secrets",[])),"plainEnv":len(k.get("environment",[])),"logDriver":(k.get("logConfiguration") or {}).get("logDriver")} for k in td.get("containerDefinitions",[])]}})
json.dump(res,open(f"{out}/ecs_services.json","w"),indent=1,default=str); print(f"  ok   ecs_services ({len(res)})")
PY

echo "== data stores (backups, exposure, secrets) =="
probe rds_instances rds describe-db-instances --query 'DBInstances[].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Version:EngineVersion,Status:DBInstanceStatus,MultiAZ:MultiAZ,Public:PubliclyAccessible,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,DeleteProtect:DeletionProtection,ManagedPassword:MasterUserSecret,AutoMinor:AutoMinorVersionUpgrade,GB:AllocatedStorage,MaxGB:MaxAllocatedStorage,Insights:PerformanceInsightsEnabled,Cluster:DBClusterIdentifier,SGs:VpcSecurityGroups[].VpcSecurityGroupId}'
probe rds_clusters rds describe-db-clusters --query 'DBClusters[].{Id:DBClusterIdentifier,Engine:Engine,Version:EngineVersion,Status:Status,MultiAZ:MultiAZ,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,DeleteProtect:DeletionProtection,ManagedPassword:MasterUserSecret,Serverless:ServerlessV2ScalingConfiguration,Members:DBClusterMembers[].DBInstanceIdentifier}'
probe rds_snapshots_manual rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].{Id:DBSnapshotIdentifier,Db:DBInstanceIdentifier,Created:SnapshotCreateTime}'
probe docdb_clusters docdb describe-db-clusters --query 'DBClusters[].{Id:DBClusterIdentifier,Version:EngineVersion,BackupDays:BackupRetentionPeriod,DeleteProtect:DeletionProtection,Encrypted:StorageEncrypted}'
probe dynamodb_tables dynamodb list-tables
probe elasticache_clusters elasticache describe-cache-clusters --query 'CacheClusters[].{Id:CacheClusterId,Node:CacheNodeType,Engine:Engine,Version:EngineVersion,SnapshotDays:SnapshotRetentionLimit,Encrypted:AtRestEncryptionEnabled,TransitEncrypted:TransitEncryptionEnabled}'
probe redshift_clusters redshift describe-clusters --query 'Clusters[].{Id:ClusterIdentifier,Node:NodeType,Nodes:NumberOfNodes,Public:PubliclyAccessible,Encrypted:Encrypted,SnapshotDays:AutomatedSnapshotRetentionPeriod}'
probe opensearch_domains opensearch list-domain-names
probe backup_plans backup list-backup-plans --query 'BackupPlansList[].{Name:BackupPlanName,Id:BackupPlanId,LastRun:LastExecutionDate}'
probe backup_vaults backup list-backup-vaults --query 'BackupVaultList[].{Name:BackupVaultName,Points:NumberOfRecoveryPoints,Locked:Locked}'
probe secretsmanager_secrets secretsmanager list-secrets --query 'SecretList[].{Name:Name,Rotation:RotationEnabled,RotationDays:RotationRules.AutomaticallyAfterDays,LastRotated:LastRotatedDate,LastAccessed:LastAccessedDate,Owner:OwningService}'
probe ssm_parameters ssm describe-parameters --query 'Parameters[].{Name:Name,Type:Type,Modified:LastModifiedDate}'
probe kms_keys kms list-aliases --query 'Aliases[?!starts_with(AliasName,`alias/aws/`)].{Alias:AliasName,Key:TargetKeyId}'

echo "== dynamodb per-table (PITR / backups) =="
python3 - <<'PY'
import json,subprocess,os
out=os.environ["OUT"]; profile=os.environ["PROFILE"]; region=os.environ["REGION"]
def aws(*a):
    p=subprocess.run(["aws","--profile",profile,"--region",region,"--output","json"]+list(a),capture_output=True,text=True)
    try: return json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else {"error":p.stderr.strip()[:200]}
    except Exception as e: return {"error":str(e)}
try: tables=json.load(open(f"{out}/dynamodb_tables.json")).get("TableNames",[])
except Exception: tables=[]
res={}
for t in tables[:40]:
    d=aws("dynamodb","describe-table","--table-name",t).get("Table",{})
    pitr=aws("dynamodb","describe-continuous-backups","--table-name",t).get("ContinuousBackupsDescription",{}).get("PointInTimeRecoveryDescription",{}).get("PointInTimeRecoveryStatus")
    res[t]={"billing":(d.get("BillingModeSummary") or {}).get("BillingMode","PROVISIONED"),"items":d.get("ItemCount"),"sizeMB":round((d.get("TableSizeBytes") or 0)/1e6,1),"gsis":len(d.get("GlobalSecondaryIndexes") or []),"pitr":pitr,"deleteProtect":d.get("DeletionProtectionEnabled")}
json.dump(res,open(f"{out}/dynamodb_detail.json","w"),indent=1,default=str); print(f"  ok   dynamodb_detail ({len(res)} tables)")
PY

echo "== storage & edge =="
probe s3_account_pab s3control get-public-access-block --account-id "$ACCOUNT"
probe s3_buckets s3api list-buckets --query 'Buckets[].{Name:Name,Created:CreationDate}'
probe cloudfront_distributions cloudfront list-distributions --query 'DistributionList.Items[].{Id:Id,Aliases:Aliases.Items,Enabled:Enabled,WebACL:WebACLId,Origins:Origins.Items[].DomainName,ViewerProtocol:DefaultCacheBehavior.ViewerProtocolPolicy}'
probe wafv2_webacls wafv2 list-web-acls --scope REGIONAL
probe route53_zones route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Records:ResourceRecordSetCount}'
probe acm_certificates acm list-certificates --query 'CertificateSummaryList[].{Domain:DomainName,Status:Status,NotAfter:NotAfter,Renewal:RenewalEligibility}'
probe logs_groups logs describe-log-groups --query 'logGroups[].{Name:logGroupName,RetentionDays:retentionInDays,StoredBytes:storedBytes}'
probe regions ec2 describe-regions --query 'Regions[].RegionName'

echo "== per-bucket exposure (read-only) =="
python3 - <<'PY'
import json,subprocess,os
out=os.environ["OUT"]; profile=os.environ["PROFILE"]
def aws(*a):
    p=subprocess.run(["aws","--profile",profile,"--output","json"]+list(a),capture_output=True,text=True)
    try: return json.loads(p.stdout) if p.returncode==0 and p.stdout.strip() else {"error":p.stderr.strip()[:160] or "none"}
    except Exception as e: return {"error":str(e)}
try: buckets=json.load(open(f"{out}/s3_buckets.json"))
except Exception: buckets=[]
res=[]
for b in buckets if isinstance(buckets,list) else []:
    n=b["Name"]; r={"Name":n}
    r["public_access_block"]=aws("s3api","get-public-access-block","--bucket",n)
    r["policy_status"]=aws("s3api","get-bucket-policy-status","--bucket",n)
    r["encryption"]=aws("s3api","get-bucket-encryption","--bucket",n)
    r["versioning"]=aws("s3api","get-bucket-versioning","--bucket",n)
    acl=aws("s3api","get-bucket-acl","--bucket",n)
    r["acl_public"]=any("AllUsers" in json.dumps(g.get("Grantee",{})) or "AuthenticatedUsers" in json.dumps(g.get("Grantee",{})) for g in acl.get("Grants",[])) if isinstance(acl,dict) else None
    res.append(r)
json.dump(res,open(f"{out}/s3_bucket_config.json","w"),indent=1); print(f"  ok   s3_bucket_config ({len(res)} buckets)")
PY

echo "== other regions (instances / RDS / trails sweep) =="
python3 - <<'PY'
import json,subprocess,os
out=os.environ["OUT"]; profile=os.environ["PROFILE"]; home=os.environ["REGION"]
def aws(r,*a):
    p=subprocess.run(["aws","--profile",profile,"--region",r,"--output","json"]+list(a),capture_output=True,text=True)
    try: return json.loads(p.stdout) if p.returncode==0 else "error"
    except Exception: return "error"
try: regions=json.load(open(f"{out}/regions.json"))
except Exception: regions=[]
res={}
for r in regions if isinstance(regions,list) else []:
    if r==home: continue
    res[r]={"instances":aws(r,"ec2","describe-instances","--query","length(Reservations[].Instances[])"),
            "rds":aws(r,"rds","describe-db-instances","--query","length(DBInstances)"),
            "lambda":aws(r,"lambda","list-functions","--query","length(Functions)")}
json.dump(res,open(f"{out}/other_regions.json","w"),indent=1)
nz={k:v for k,v in res.items() if any(x not in (0,"error") for x in v.values())}
print(f"  ok   other_regions — non-empty: {nz or 'none'}")
PY

echo "== digest =="
python3 "$(dirname "$0")/audit-digest.py" "$OUT" "$ACCOUNT" "$REGION"
echo "done → $OUT/DIGEST.md"
