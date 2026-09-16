#!/usr/bin/env bash
# on-box-secops: READ-ONLY people-and-code collector run on a server by ec2-ssh-sweep.sh.
# Answers: who can log in here and are they on the roster (Q2, Q6), whose cloud keys sit on this
# box (Q2, Q11), and is the code running here the code in the repo (Q1). Prints SSH key
# FINGERPRINTS and comments (never keys), AWS access key IDs (never secrets), secret variable
# NAMES (never values). Never writes. $SUDO is "sudo -n " or empty.
S(){ if [ -n "${SUDO:-}" ]; then ${SUDO} "$@" 2>/dev/null || "$@" 2>/dev/null; else "$@" 2>/dev/null; fi; }
H(){ printf '\n### %s\n' "$*"; }
TO(){ if command -v timeout >/dev/null; then timeout 40 "$@"; else "$@"; fi; }
export LC_ALL=C

H identity; hostname; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); echo "uptime: $(uptime)"
T=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
echo "instance-id: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo n/a)  iam-role: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || echo none)"

H ssh-keys  # one line per authorized key: user, fingerprint, comment (the comment usually names a person/laptop)
awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1, $6}' /etc/passwd 2>/dev/null | while read -r u h; do
  for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
    S test -r "$f" || continue
    S grep -E '^(ssh|ecdsa|sk-)' "$f" | while read -r line; do
      fp=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $1" "$2}'); c=$(echo "$line" | awk '{ $1=""; $2=""; print }' | sed 's/^ *//')
      echo "  $u  ${fp:-?}  comment='${c:-(none)}'  opts=$(echo "$line" | grep -oE '^(from|command|restrict|no-[a-z-]+)[^ ]*' | head -1)"
    done
  done
done
echo "-- sshd: $(S sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin) ' | tr '\n' ' ')"
echo "-- host keys for outbound (known_hosts entries per user, = lateral reach):"; for h in /root /home/*; do n=$(S grep -c . "$h/.ssh/known_hosts" 2>/dev/null); [ -n "$n" ] && [ "$n" != 0 ] && echo "  $(basename "$h"): $n"; done
echo "-- private keys present (names only):"; for h in /root /home/*; do S ls "$h/.ssh" 2>/dev/null | grep -vE 'authorized_keys|known_hosts|\.pub$|config$' | sed "s#^#  $(basename "$h")/.ssh/#"; done
echo "-- ssh config hosts:"; for h in /root /home/*; do S grep -hE '^\s*Host ' "$h/.ssh/config" 2>/dev/null | sed "s#^#  $(basename "$h"): #"; done | head -10

H logins  # who actually logs in, from where
echo "-- last 25 logins:"; S last -F -a 2>/dev/null | grep -vE '^(reboot|wtmp|$)' | head -25 | sed 's/^/  /'
echo "-- accepted ssh (auth log, by user and source, current file):"; S grep -hE 'Accepted (publickey|password)' /var/log/auth.log /var/log/secure 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="for"){u=$(i+1)} else if($i=="from"){s=$(i+1)}; print u, s}' | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
echo "-- accepted ssh key fingerprints (ties a login to an authorized_keys line):"; S grep -hoE 'Accepted publickey for [^ ]+ from [^ ]+ .*(SHA256:[A-Za-z0-9+/=]+)' /var/log/auth.log /var/log/secure 2>/dev/null | awk '{print $4, $NF}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
echo "-- sudoers:"; S grep -hvE '^\s*(#|$|Defaults)' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | head -10 | sed 's/^/  /'; getent group sudo wheel admin 2>/dev/null | sed 's/^/  group /'
echo "-- users with a password set (shadow, names only):"; S awk -F: '$2 ~ /^\$/ {print "  "$1}' /etc/shadow 2>/dev/null

H aws-credentials-on-disk  # key IDs only — map each AKIA to an IAM user in members-aws.json
for f in /root/.aws/credentials /home/*/.aws/credentials; do S test -f "$f" || continue; echo "  $f  [$(S stat -c '%a %U %y' "$f" | cut -c1-30)]"; S grep -E '^\s*\[|aws_access_key_id' "$f" | sed -E 's/aws_access_key_id\s*=\s*/    key id: /' | sed 's/^\[/    profile /'; done
echo "-- AKIA ids in env files / process env (id only):"; { TO ${SUDO:-} grep -rhoE 'AKIA[0-9A-Z]{16}' /var/www /srv /opt /home /root /etc --include='.env*' --include='*.env' --include='*.json' --include='*.yml' --include='*.yaml' 2>/dev/null; TO ${SUDO:-} bash -c 'for p in /proc/[0-9]*; do tr "\0" "\n" < $p/environ 2>/dev/null | grep -oE "AKIA[0-9A-Z]{16}"; done' 2>/dev/null; } | grep -v EXAMPLE | sort | uniq -c | sed 's/^/  /'
echo "-- other cloud/SaaS credential files present:"; for f in /root/.config/gcloud /home/*/.config/gcloud /root/.npmrc /home/*/.npmrc /root/.docker/config.json /home/*/.docker/config.json /root/.netrc /home/*/.netrc /root/.git-credentials /home/*/.git-credentials /root/.config/gh/hosts.yml /home/*/.config/gh/hosts.yml /root/.vercel /home/*/.vercel /root/.fly /home/*/.fly /root/.config/op /home/*/.config/op; do S test -e "$f" && echo "  $f"; done

H git-identities  # who deploys / commits from this box
for h in /root /home/*; do e=$(S git config -f "$h/.gitconfig" user.email 2>/dev/null); [ -n "$e" ] && echo "  $(basename "$h"): $e"; done

H git-repos-on-disk  # Q1: is the code here the code in the repo?
TO ${SUDO:-} find /var/www /srv /opt /home /root /app /usr/src /data -xdev -maxdepth 5 -type d -name .git 2>/dev/null | while read -r g; do
  d=$(dirname "$g"); r=$(S git -C "$d" remote get-url origin 2>/dev/null || echo '(no remote)'); b=$(S git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
  un=$(S git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' '); up=$(S git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?'); last=$(S git -C "$d" log -1 --format='%h %cs %ae' 2>/dev/null)
  echo "  $d"; echo "    remote=$r branch=$b uncommitted=$un unpushed=$up last=$last"
done
echo "-- app dirs WITHOUT .git (code with no known source):"
TO ${SUDO:-} find /var/www /srv /opt /home /root /app /usr/src -xdev -maxdepth 4 -type f \( -name package.json -o -name requirements.txt -o -name pyproject.toml -o -name go.mod -o -name Gemfile -o -name composer.json -o -name pom.xml \) -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/site-packages/*' -not -path '*/.venv/*' 2>/dev/null | while read -r f; do d=$(dirname "$f"); S git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || echo "  $d  ($(basename "$f"), modified $(S stat -c %y "$f" | cut -c1-10))"; done | sort -u | head -20

H running-code  # what is actually serving, and from where
echo "-- process cwd (is it inside a git repo?):"; for p in $(S pgrep -f 'node|python|gunicorn|uvicorn|ruby|puma|java|php-fpm|dotnet|go|bun|deno' 2>/dev/null | head -15); do cwd=$(S readlink "/proc/$p/cwd" 2>/dev/null); [ -n "$cwd" ] && echo "  pid $p $(S cat /proc/$p/comm 2>/dev/null) cwd=$cwd git=$(S git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null || echo no)"; done | sort -u -k4 | head -10
command -v pm2 >/dev/null && { echo "-- pm2:"; S pm2 jlist 2>/dev/null | python3 -c 'import sys,json
try:
    for a in json.load(sys.stdin): e=a.get("pm2_env",{}); print("  %-20s cwd=%s  script=%s" % (a.get("name"),e.get("pm_cwd"),e.get("pm_exec_path")))
except Exception: pass' 2>/dev/null; }
echo "-- containers (image namespace = who controls the build):"; S docker ps --format '  {{.Names}}  {{.Image}}  up {{.RunningFor}}' 2>/dev/null | head -12
echo "-- systemd units pointing outside a repo:"; S grep -hE '^(ExecStart|WorkingDirectory)=' /etc/systemd/system/*.service 2>/dev/null | grep -vE '/usr/(s)?bin/(docker|node|python|nginx|redis|postgres)' | sort -u | head -10 | sed 's/^/  /'
echo "-- crontab scripts:"; for u in $(cut -d: -f1 /etc/passwd 2>/dev/null); do S crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*(#|$)' | sed -E 's/(password|token|secret)=[^ ]+/\1=<redacted>/Ig' | sed "s/^/  $u: /"; done | head -12
ls /etc/cron.d 2>/dev/null | grep -vE 'e2scrub|sysstat|popularity|mdadm' | sed 's/^/  cron.d: /'

H secrets-on-disk  # names + file + perms only
for f in $(TO ${SUDO:-} find /var/www /srv /opt /home /etc /root /app -xdev -maxdepth 5 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name 'secrets.yml' -o -name 'credentials.json' -o -name 'serviceAccountKey.json' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \) -not -path '*/node_modules/*' -not -path '/etc/ssl/*' -not -path '/etc/ssh/*' 2>/dev/null | head -40); do
  perm=$(S stat -c '%a %U %y' "$f" 2>/dev/null | cut -c1-30); case "$f" in *.p12) echo "  $f  [$perm]  pkcs12-bundle"; continue;; *.pem|*.key) S grep -q 'PRIVATE KEY' "$f" 2>/dev/null && echo "  $f  [$perm]  private-key-material"; continue;; esac
  n=$(S grep -cE '^\s*(export\s+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET|DATABASE_URL|MONGO_URI|MONGODB_URI|REDIS_URL)[A-Z0-9_]*\s*[=:]' "$f" 2>/dev/null); [ "${n:-0}" != 0 ] && echo "  $f  [$perm]  $n secret-shaped var(s): $(S grep -oE '^\s*(export\s+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|ACCESS_KEY|DATABASE_URL)[A-Z0-9_]*' "$f" 2>/dev/null | sed -E 's/^\s*(export\s+)?//' | head -6 | tr '\n' ' ')"
done
echo "### end"
