#!/usr/bin/env bash
# ec2-ssh-sweep: discover every running EC2 instance, get the user's OK to log in, then run a
# READ-ONLY collector script on each box and save the output. Two subcommands:
#
#   scripts/ec2-ssh-sweep.sh discover --profile <p> --region <r> [--out <dir>]
#       Lists running instances (id, Name, public/private IP, key pair, platform, SSM-managed?)
#       and writes <out>/hosts.tsv for you to fill in access details. Nothing is contacted.
#
#   scripts/ec2-ssh-sweep.sh run --profile <p> --region <r> --hosts <out>/hosts.tsv \
#       --script scripts/on-box-<cost|audit>.sh [--out <dir>] [--sudo]
#       For each row: ssh (BatchMode, 15s timeout) or SSM RunCommand, feed the script on stdin,
#       save <out>/box-<instance-id>.txt. Never writes to the box: the collector scripts only
#       read /proc, ps, ss, df, logs and config; --sudo prefixes "sudo -n" so readable-by-root
#       files (auth.log, sudoers) are included when the user has passwordless sudo.
#
# hosts.tsv columns (tab-separated; lines starting with # are ignored):
#   instance_id  name  method  host  user  key  proxy
#     method: ssh | ssm | skip
#     host:   IP or DNS name to ssh to (blank for ssm)
#     user:   ssh login user (ubuntu / ec2-user / admin / bitnami / ...)
#     key:    path to private key, or "-" to use the ssh agent / ~/.ssh/config
#     proxy:  bastion as user@host, or "-"
#
# Lightsail: not covered here. `aws lightsail get-instance-access-details --instance-name X`
# returns a temporary key; add the box to hosts.tsv by hand with method=ssh.
set -uo pipefail
export AWS_PAGER=""
CMD="${1:-}"; shift || true
PROFILE=""; REGION=""; OUT=""; HOSTS=""; SCRIPT=""; SUDO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    --out)     OUT="$2";     shift 2;;
    --hosts)   HOSTS="$2";   shift 2;;
    --script)  SCRIPT="$2";  shift 2;;
    --sudo)    SUDO=1;       shift;;
    -h|--help) sed -n '2,26p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -z "$PROFILE" ] && { echo "--profile is required" >&2; exit 2; }
[ -z "$REGION" ] && REGION=$(aws --profile "$PROFILE" configure get region 2>/dev/null || echo us-east-1)
A=(aws --profile "$PROFILE" --region "$REGION" --output json)
[ -z "$OUT" ] && OUT="./ssh-sweep-$(date +%Y-%m-%d)"
mkdir -p "$OUT"

case "$CMD" in
discover)
  "${A[@]}" ec2 describe-instances --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,Type:InstanceType,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Key:KeyName,Platform:PlatformDetails,Profile:IamInstanceProfile.Arn,AZ:Placement.AvailabilityZone}' \
    > "$OUT/running-instances.json" || { echo "describe-instances failed" >&2; exit 1; }
  "${A[@]}" ssm describe-instance-information --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,OS:PlatformName}' \
    > "$OUT/ssm-managed.json" 2>/dev/null || echo '[]' > "$OUT/ssm-managed.json"
  python3 - "$OUT" <<'PY'
import json,sys
out=sys.argv[1]
inst=json.load(open(f"{out}/running-instances.json")); ssm={s["Id"]:s for s in json.load(open(f"{out}/ssm-managed.json"))}
print(f"{len(inst)} running instance(s)\n")
print(f"{'instance':<21}{'name':<28}{'type':<12}{'public ip':<17}{'private ip':<14}{'key pair':<22}{'platform':<14}ssm")
for i in inst:
    s=ssm.get(i["Id"]); print(f"{i['Id']:<21}{(i.get('Name') or '(no Name tag)')[:27]:<28}{i['Type']:<12}{str(i.get('PublicIp') or '-'):<17}{str(i.get('PrivateIp') or '-'):<14}{str(i.get('Key') or '(none)')[:21]:<22}{str(i.get('Platform') or '')[:13]:<14}{('yes ('+s['Ping']+')') if s else 'no'}")
with open(f"{out}/hosts.tsv","w") as f:
    f.write("# instance_id\tname\tmethod(ssh|ssm|skip)\thost\tuser\tkey\tproxy\n")
    for i in inst:
        m="ssm" if i["Id"] in ssm and ssm[i["Id"]]["Ping"]=="Online" else "ssh"
        f.write("\t".join([i["Id"],(i.get("Name") or "")[:40],m,i.get("PublicIp") or i.get("PrivateIp") or "","FILLME","-","-"])+"\n")
print(f"\nwrote {out}/hosts.tsv — fill in user/key/proxy (or method=skip), then run the `run` subcommand")
PY
  ;;
run)
  [ -f "${HOSTS:-}" ] || { echo "--hosts <hosts.tsv> is required" >&2; exit 2; }
  [ -f "${SCRIPT:-}" ] || { echo "--script <on-box script> is required" >&2; exit 2; }
  python3 - "$SCRIPT" <<'PY' || exit 3
import re,sys
bad=re.compile(r"(^|[;&|]\s*)(rm|mv|cp|chmod|chown|apt(-get)?|yum|dnf|kill|pkill|reboot|shutdown|truncate|tee|dd|mkfs|useradd|passwd|crontab -[re])(\s|$)|systemctl\s+(start|stop|restart|enable|disable|mask)|(\s|\d)>{1,2}\s*(?!/dev/null|&)[/~$\"'A-Za-z]")
for n,l in enumerate(open(sys.argv[1]),1):
    if l.strip() and not l.lstrip().startswith('#') and bad.search(l):
        print(f"refusing: {sys.argv[1]}:{n} could write to or change the box: {l.strip()[:100]}",file=sys.stderr); sys.exit(3)
PY
  SUDOPFX=""; [ "$SUDO" = 1 ] && SUDOPFX="sudo -n "
  while IFS=$'\t' read -r id name method host user key proxy; do
    [ -z "$id" ] || [ "${id:0:1}" = "#" ] && continue
    dest="$OUT/box-$id.txt"; echo "== $id ($name) via $method"
    case "$method" in
      skip) echo "   skipped";;
      ssh)
        [ "$user" = "FILLME" ] && { echo "   user not filled in — skipping"; continue; }
        opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
        [ "$key" != "-" ] && opts+=(-i "$key"); [ "$proxy" != "-" ] && opts+=(-o "ProxyJump=$proxy")
        { echo "# $id $name $host collected $(date -u +%FT%TZ) sudo=$SUDO"; ssh "${opts[@]}" "$user@$host" "SUDO='$SUDOPFX' bash -s" < "$SCRIPT"; } > "$dest" 2>&1 \
          && echo "   ok → $dest ($(wc -l < "$dest") lines)" || echo "   FAILED (exit $?) — see $dest";;
      ssm)
        b64=$(base64 < "$SCRIPT" | tr -d '\n')
        cid=$("${A[@]}" ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --comment "infra read-only sweep" \
              --parameters "commands=[\"echo $b64 | base64 -d > /tmp/.sweep.sh && SUDO='$SUDOPFX' bash /tmp/.sweep.sh; rm -f /tmp/.sweep.sh\"],executionTimeout=[\"600\"]" \
              --query Command.CommandId --output text 2>"$dest") || { echo "   send-command FAILED — see $dest"; continue; }
        for _ in $(seq 1 60); do
          st=$("${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
          case "$st" in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 5
        done
        { echo "# $id $name via SSM collected $(date -u +%FT%TZ) status=$st"; "${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text; echo "## stderr"; "${A[@]}" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardErrorContent --output text; } > "$dest" 2>&1
        echo "   $st → $dest";;
      *) echo "   unknown method '$method' — skipping";;
    esac
  done < "$HOSTS"
  echo "done → $OUT/box-*.txt"
  ;;
*) sed -n '2,26p' "$0"; exit 2;;
esac
