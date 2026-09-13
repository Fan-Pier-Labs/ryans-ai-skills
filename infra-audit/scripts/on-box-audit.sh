#!/usr/bin/env bash
# on-box-audit: READ-ONLY collector run on an EC2/Lightsail box by ec2-ssh-sweep.sh.
# Answers what the AWS API cannot: patch state, what listens on which port, who can log in,
# where secrets sit on disk, whether the database is self-hosted, whether backups exist,
# and whether the box would survive a reboot. Secret VALUES are never printed — only the
# variable name, the file, and the value's length. Never writes. $SUDO is "sudo -n " or empty.
S(){ if [ -n "${SUDO:-}" ]; then ${SUDO} "$@" 2>/dev/null || "$@" 2>/dev/null; else "$@" 2>/dev/null; fi; }
H(){ printf '\n### %s\n' "$*"; }
TO(){ if command -v timeout >/dev/null; then timeout 40 "$@"; else "$@"; fi; }   # cap slow probes so one box cannot stall the sweep
export LC_ALL=C

H identity; hostname; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME (eol check: $VERSION_ID)"); uname -r; echo "uptime: $(uptime)"; echo "arch: $(uname -m)"
T=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
echo "instance-type: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo n/a)"
echo "iam-role: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || echo none)"
echo -n "imdsv1-reachable-without-token: "; curl -s -m 2 -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo n/a   # 200 = IMDSv1 still allowed (finding); 401 = v2 enforced

H patching  # the never-rebooted box: pending updates, reboot-required, automatic updates
[ -f /var/run/reboot-required ] && { echo "REBOOT REQUIRED:"; cat /var/run/reboot-required.pkgs 2>/dev/null | head -5; } || echo "reboot-required: no"
if command -v apt >/dev/null; then n=$(apt list --upgradable 2>/dev/null | grep -c upgradable); sec=$(apt list --upgradable 2>/dev/null | grep -ci security); echo "apt upgradable: $n (security: $sec)"; echo "last apt update: $(stat -c %y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || stat -c %y /var/cache/apt/pkgcache.bin 2>/dev/null)"; echo "unattended-upgrades: $(systemctl is-enabled unattended-upgrades 2>/dev/null || echo not-installed) ; config: $(grep -hE 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | wc -l | sed 's/^1$/on/;s/^0$/off/')"
elif command -v dnf >/dev/null; then echo "dnf check-update: $(dnf -q check-update 2>/dev/null | grep -cE '^[a-zA-Z0-9]')"; echo "dnf-automatic: $(systemctl is-enabled dnf-automatic.timer 2>/dev/null || echo not-installed)"
elif command -v yum >/dev/null; then echo "yum check-update: $(yum -q check-update 2>/dev/null | grep -cE '^[a-zA-Z0-9]')"; echo "yum-cron: $(systemctl is-enabled yum-cron 2>/dev/null || echo not-installed)"; fi
echo "last kernel/boot: $(uptime -s 2>/dev/null); installed kernels: $(ls /boot/vmlinuz-* 2>/dev/null | wc -l)"

H runtimes-eol  # compare against endoflife.date: Node <20, Python <3.9, PHP <8.1, Ruby <3.1 are past EOL in 2026
for b in node python3 python ruby php java go dotnet; do command -v $b >/dev/null && echo "$b: $($b --version 2>&1 | head -1)"; done
command -v nvm >/dev/null && echo "nvm present"; ls /usr/local/n/versions/node 2>/dev/null | sed 's/^/n: /'
[ -d /opt/bitnami ] && { echo "bitnami stack: $(cat /opt/bitnami/properties.ini 2>/dev/null | grep -iE 'name|version' | head -2 | tr '\n' ' ')"; ls -la /opt/bitnami 2>/dev/null | head -3 | tail -1 | awk '{print "installed:",$6,$7,$8}'; }

H listening-ports  # anything on 0.0.0.0/:: is reachable subject only to the security group
S ss -ltnpH 2>/dev/null | awk '{print $4, $6}' | sed 's/users:((//;s/,.*//' | sort -u || netstat -ltnp 2>/dev/null
echo "-- databases on this box (self-hosted DB = lead finding)"
ps -eo pid,etimes,args 2>/dev/null | grep -E 'mongod|postgres|mysqld|mariadb|redis-server|elasticsearch|memcached|influxd|clickhouse|couchdb' | grep -v grep | awk '{printf "pid=%s up=%ss %s\n",$1,$2,substr($0,index($0,$3),90)}'
for v in "mongod --version" "psql --version" "mysqld --version" "redis-server --version"; do command -v ${v%% *} >/dev/null && echo "$($v 2>&1 | head -1)"; done
echo "-- db auth/bind hints (values not printed)"; for f in /etc/mongod.conf /etc/mongodb.conf /etc/redis/redis.conf /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/main/pg_hba.conf /etc/mysql/mysql.conf.d/mysqld.cnf; do [ -r "$f" ] || S test -r "$f" || continue; echo "$f:"; S grep -hE '^\s*(bindIp|bind-address|bind |listen_addresses|requirepass|authorization|protected-mode|host\s+all)' "$f" 2>/dev/null | sed -E 's/(requirepass|password)\s+\S+/\1 <redacted>/' | head -6; done
echo "-- last database backup artifacts found (mtime)"; TO ${SUDO:-} find / -xdev \( -name '*.dump' -o -name '*.sql.gz' -o -name '*.sql' -o -name 'dump.rdb' -o -name '*.archive' -o -name '*.bson' \) -size +10k -printf '%TY-%Tm-%Td %s %p\n' 2>/dev/null | sort -r | head -6
echo "-- backup tooling"; for c in restic borg duplicity rclone pg_dump mongodump mysqldump litestream wal-g pgbackrest; do command -v $c >/dev/null && echo "  $c present"; done; grep -rlE 'pg_dump|mongodump|mysqldump|restic|rclone|aws s3 (cp|sync)' /etc/cron* /var/spool/cron 2>/dev/null | sed 's/^/  cron backup job: /'

H containers; command -v docker >/dev/null && { S docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null; echo "-- containers running as privileged / with docker.sock"; S docker ps -q 2>/dev/null | xargs -r -n1 docker inspect --format '{{.Name}} privileged={{.HostConfig.Privileged}} binds={{.HostConfig.Binds}}' 2>/dev/null | grep -E 'privileged=true|docker.sock'; echo "-- compose files"; TO ${SUDO:-} find / -xdev -maxdepth 4 \( -name 'docker-compose*.yml' -o -name 'compose*.yml' \) 2>/dev/null | head -5; } || echo "docker: n/a"

H ssh-and-users
echo "-- sshd effective config"; S sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication|permitemptypasswords|x11forwarding|port|allowusers|maxauthtries) ' || grep -hE '^\s*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|Port)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null
echo "-- login-capable users and their authorized_keys count"; awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1, $6}' /etc/passwd 2>/dev/null | while read -r u h; do echo "  $u  keys=$(S cat "$h/.ssh/authorized_keys" 2>/dev/null | grep -cE '^(ssh|ecdsa)')  last=$(last -1 -F "$u" 2>/dev/null | head -1 | awk '{print $5,$6,$7,$8}')"; done
echo "-- sudoers (who has root)"; S grep -hvE '^\s*(#|$|Defaults)' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | head -10; getent group sudo wheel admin 2>/dev/null
echo "-- failed ssh logins in auth log (current file)"; S grep -hcE 'Failed password|Invalid user' /var/log/auth.log /var/log/secure 2>/dev/null | awk '{s+=$1}END{print s+0}'; echo "accepted (last 10):"; S grep -hE 'Accepted (publickey|password)' /var/log/auth.log /var/log/secure 2>/dev/null | tail -10 | awk '{print $1,$2,$3,$9,$11}'
echo "-- fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo not-installed)"

H firewall  # host firewall in addition to the security group
S ufw status 2>/dev/null | head -12 || true; echo "iptables INPUT rules: $(S iptables -S INPUT 2>/dev/null | wc -l) ; nft: $(S nft list ruleset 2>/dev/null | wc -l) lines"

H secrets-on-disk  # names + file + value length only; the values themselves are never echoed
for f in $(TO ${SUDO:-} find /var/www /srv /opt /home /etc /root -xdev -maxdepth 5 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name 'config.js' -o -name 'config.json' -o -name 'application.yml' -o -name 'application.properties' -o -name 'secrets.yml' -o -name 'credentials' -o -name 'settings.py' -o -name 'wp-config.php' -o -name '*.pem' -o -name '*.key' -o -name '*service-account*.json' \) 2>/dev/null | grep -vE 'node_modules|/\.git/|/vendor/|\.example|\.sample|/ssl/certs/|/ssh_host_' | head -40); do
  perm=$(stat -c '%a %U' "$f" 2>/dev/null); case "$f" in *.pem|*.key) echo "$f  [$perm]  private-key-material"; continue;; esac
  hits=$(S grep -oiE '^\s*(export\s+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET|DATABASE_URL|MONGO_URI|MONGODB_URI|REDIS_URL)[A-Z0-9_]*\s*[=:]\s*.{4,}' "$f" 2>/dev/null | awk -F'[=:]' '{n=$1; gsub(/^[ \t]*(export[ \t]+)?/,"",n); v=$0; sub(/^[^=:]*[=:][ \t]*/,"",v); printf "%s(len %d) ", n, length(v)}')
  [ -n "$hits" ] && echo "$f  [$perm]  $hits"
done
echo "-- aws credentials files"; for f in /root/.aws/credentials /home/*/.aws/credentials; do S test -f "$f" && echo "  $f exists ($(S grep -c aws_access_key_id "$f" 2>/dev/null) keys)"; done
echo "-- secrets in process environments (names only)"; TO ${SUDO:-} bash -c 'for p in /proc/[0-9]*; do tr "\0" "\n" < $p/environ 2>/dev/null | grep -oE "^[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*" ; done' 2>/dev/null | sort | uniq -c | sort -rn | head -10

H tls  # certificates and how they renew
command -v certbot >/dev/null && S certbot certificates 2>/dev/null | grep -E 'Certificate Name|Expiry|Domains' | head -12
for f in /etc/letsencrypt/live/*/cert.pem /opt/bitnami/apache/conf/bitnami/certs/server.crt /etc/ssl/private/*.crt /etc/nginx/ssl/*.crt; do [ -r "$f" ] || S test -r "$f" || continue; echo "$f: $(S openssl x509 -in "$f" -noout -enddate -subject 2>/dev/null | tr '\n' ' ')"; done
echo "renewal: $(systemctl is-active certbot.timer 2>/dev/null || echo no-timer) / cron: $(grep -rlE 'certbot|acme|renew' /etc/cron* 2>/dev/null | head -2 | tr '\n' ' ')"

H web-server-and-app
for c in "nginx -v" "apachectl -v" "httpd -v" "caddy version"; do command -v ${c%% *} >/dev/null && echo "$($c 2>&1 | head -1)"; done
echo "-- server_tokens / exposed headers"; S grep -rhE 'server_tokens|ServerTokens|ServerSignature' /etc/nginx /etc/apache2 /etc/httpd /opt/bitnami/apache/conf 2>/dev/null | grep -v '#' | sort -u | head -4
command -v pm2 >/dev/null && { echo "-- pm2"; pm2 ls 2>/dev/null | head -12; echo "pm2 startup: $(systemctl is-enabled pm2-* 2>/dev/null | head -1 || echo not-configured — apps will not come back after reboot)"; }
echo "-- systemd services enabled (custom)"; systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -vE '^(systemd|dbus|getty|ssh|sshd|cron|rsyslog|chrony|snapd|polkit|udisks|networkd|resolved|acpid|atd|multipathd|unattended|apparmor|irqbalance|lvm|cloud-|amazon-ssm|containerd|docker|e2scrub|console-|getty|open-vm|hibinit|ec2|ufw|fail2ban|blk-|finalrd|grub|setvtrgb|secureboot|rsync|pollinate)' | head -20
echo "-- world-writable files under web roots"; TO ${SUDO:-} find /var/www /srv /opt/bitnami/apps -xdev -type f -perm -o+w 2>/dev/null | head -5

H disk-and-logs; df -hT 2>/dev/null | grep -vE 'tmpfs|devtmpfs|overlay|squashfs'; echo "swap: $(free -m 2>/dev/null | awk '/Swap/{print $2"MB total"}')"
echo "log shipping / monitoring agents:"; for c in amazon-cloudwatch-agent datadog-agent newrelic-infra filebeat vector fluent-bit node_exporter promtail; do systemctl is-active $c >/dev/null 2>&1 && echo "  $c active"; done; echo "  (none listed = logs live only on this disk)"
echo "logrotate: $(systemctl is-active logrotate.timer 2>/dev/null || ls /etc/cron.daily/logrotate 2>/dev/null || echo none)"

H scheduled-work; for u in $(cut -d: -f1 /etc/passwd 2>/dev/null); do c=$(S crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*(#|$)'); [ -n "$c" ] && { echo "-- crontab $u"; echo "$c" | sed -E 's/(password|token|secret)=[^ ]+/\1=<redacted>/Ig'; }; done
ls /etc/cron.d 2>/dev/null | grep -vE 'e2scrub|sysstat|popularity|mdadm' | sed 's/^/cron.d: /'

H time-sync; (timedatectl 2>/dev/null | grep -iE 'synchronized|NTP service') || (chronyc tracking 2>/dev/null | head -2) || echo n/a
echo "### end"
