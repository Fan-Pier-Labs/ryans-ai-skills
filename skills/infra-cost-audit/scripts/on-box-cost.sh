#!/usr/bin/env bash
# on-box-cost: READ-ONLY collector run on an EC2/Lightsail box by ec2-ssh-sweep.sh.
# Answers the questions CloudWatch cannot: is this box memory- or I/O-bound at low CPU, what is
# actually running, does anyone use it (real HTTP traffic, logins, deploys), and could it be
# smaller, scheduled, or gone. Prints sections; missing tools print "n/a". Never writes.
# $SUDO is "sudo -n " or empty; S runs a command with sudo if allowed, else without.
S(){ if [ -n "${SUDO:-}" ]; then ${SUDO} "$@" 2>/dev/null || "$@" 2>/dev/null; else "$@" 2>/dev/null; fi; }
H(){ printf '\n### %s\n' "$*"; }
TO(){ if command -v timeout >/dev/null; then timeout 40 "$@"; else "$@"; fi; }   # cap slow probes so one box cannot stall the sweep
export LC_ALL=C

H identity; hostname; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); uname -r; echo "uptime: $(uptime)"
echo "cpus: $(nproc 2>/dev/null || echo n/a)  arch: $(uname -m)"
T=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
echo "instance-type: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo n/a)"

H memory  # the number CloudWatch does not have
free -m 2>/dev/null || vm_stat 2>/dev/null || echo n/a
grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo 2>/dev/null
echo "-- top 12 by RSS (MB)"; ps -eo rss,pcpu,etimes,user,comm,args --sort=-rss 2>/dev/null | awk 'NR==1{print;next}{printf "%6.0f %5s %8s %-10s %s\n",$1/1024,$2,$3,$4,substr($0,index($0,$5),90)}' | head -13

H load-and-io  # vmstat: r=runnable, b=blocked on I/O, wa=I/O wait %
[ "$(uname)" = Linux ] && TO vmstat 1 5 2>/dev/null || echo "vmstat n/a"
command -v iostat >/dev/null && [ "$(uname)" = Linux ] && TO iostat -dx 1 3 2>/dev/null | tail -n +4 | grep -vE '^$' | tail -12
echo "-- sar history (if sysstat collects it): cpu/mem/io for the last few days"
for f in $(ls -t /var/log/sa/sa[0-9]* 2>/dev/null | head -3); do echo "-- $f"; sar -u -f "$f" 2>/dev/null | tail -2; sar -r -f "$f" 2>/dev/null | tail -1; done

H disk; df -hT 2>/dev/null | grep -vE 'tmpfs|devtmpfs|overlay|squashfs' ; echo "-- biggest dirs under / (depth 2)"; TO ${SUDO:-} du -xhd2 / 2>/dev/null | sort -rh | head -12

H network-bytes-since-boot; awk 'NR>2 && $2+$10>0 {printf "%-10s rx=%.1fGB tx=%.1fGB\n",$1,$2/1e9,$10/1e9}' /proc/net/dev 2>/dev/null
echo "-- established connections by remote port (who talks to this box)"; S ss -tn state established 2>/dev/null | awk 'NR>1{split($4,a,":");print a[length(a)]}' | sort | uniq -c | sort -rn | head -8

H listening-services; S ss -ltnpH 2>/dev/null | awk '{print $4, $6}' | sed 's/users:((//;s/,.*//' | sort -u || netstat -ltnp 2>/dev/null
echo "-- database processes (self-hosted DB = a finding for infra-audit, and a cost line if you move it)"
ps -eo pid,rss,etimes,args 2>/dev/null | grep -E 'mongod|postgres|mysqld|mariadb|redis-server|elasticsearch|memcached|influxd|clickhouse' | grep -v grep | awk '{printf "pid=%s rss=%.0fMB up=%ss %s\n",$1,$2/1024,$3,substr($0,index($0,$4),80)}'

H process-managers-and-containers
command -v docker >/dev/null && { S docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null; echo "-- docker stats (one sample)"; S docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null; echo "-- image/volume disk"; S docker system df 2>/dev/null; } || echo "docker: n/a"
command -v pm2 >/dev/null && { pm2 jlist 2>/dev/null | python3 -c 'import sys,json;[print(f"pm2 {p[\"name\"]} status={p[\"pm2_env\"][\"status\"]} restarts={p[\"pm2_env\"][\"restart_time\"]} mem={p[\"monit\"][\"memory\"]//1048576}MB") for p in json.load(sys.stdin)]' 2>/dev/null || pm2 ls 2>/dev/null; } || echo "pm2: n/a"
echo "-- systemd services running"; systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -vE '^(systemd|dbus|getty|ssh|sshd|cron|rsyslog|chrony|snapd|polkit|udisks|networkd|resolved|acpid|atd|multipathd|unattended|apparmor|irqbalance|lvm|cloud-|amazon-ssm|containerd|docker\.)' | head -30

H scheduled-work  # a box that exists only to run cron is a Lambda/scheduled-task candidate
for u in $(cut -d: -f1 /etc/passwd 2>/dev/null); do c=$(S crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*(#|$)'); [ -n "$c" ] && { echo "-- crontab $u"; echo "$c"; }; done
ls /etc/cron.d 2>/dev/null | grep -vE 'e2scrub|sysstat|popularity|mdadm|certbot' | sed 's/^/cron.d: /'
systemctl list-timers --no-pager --no-legend 2>/dev/null | awk '{print "timer:", $NF, $(NF-1)}' | grep -vE 'apt-|fstrim|logrotate|man-db|motd|e2scrub|snapd|sysstat|ua-|dpkg|update-notifier' | head -15

H real-traffic  # requests over the last 7 and 30 days, minus scanner noise; zero here = nobody uses it
for f in /var/log/nginx/access.log /var/log/apache2/access.log /var/log/httpd/access_log /opt/bitnami/apache/logs/access_log /opt/bitnami/nginx/logs/access.log /var/log/caddy/access.log; do
  [ -r "$f" ] || S test -r "$f" || continue
  echo "-- $f (current file; rotated files not included — check *.1/*.gz if this is thin)"
  S awk -v d7="$(date -d '-7 days' +%d/%b/%Y 2>/dev/null || date -v-7d +%d/%b/%Y)" -v d30="$(date -d '-30 days' +%d/%b/%Y 2>/dev/null || date -v-30d +%d/%b/%Y)" '
    { total++; scan = /\.env|wp-login|wp-admin|phpmyadmin|\.git\/|xmlrpc|\/cgi-bin|\.php|eval-stdin|HNAP1|boaform/ ? 1 : 0; if(scan) scanners++; else { ips[$1]++; real++ } }
    END { printf "lines=%d real=%d scanner-ish=%d distinct-real-ips=%d\n", total, real, scanners, length(ips) }' "$f" 2>/dev/null
  echo "   first/last line dates:"; S head -1 "$f" 2>/dev/null | grep -oE '\[[0-9]+/[A-Za-z]+/[0-9]+' ; S tail -1 "$f" 2>/dev/null | grep -oE '\[[0-9]+/[A-Za-z]+/[0-9]+'
  echo "   top real paths:"; S grep -vE '\.env|wp-login|wp-admin|phpmyadmin|xmlrpc|\.php' "$f" 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -rn | head -8
done
[ -d /var/log/nginx ] || [ -d /var/log/apache2 ] || [ -d /var/log/httpd ] || [ -d /opt/bitnami ] || echo "no web server access logs found"

H humans  # last logins and deploys: a box nobody has touched in months is a decommission candidate
last -n 15 -F 2>/dev/null | grep -vE '^(reboot|wtmp|$)' | head -15 || echo "last: n/a"
echo "-- newest app files (deploy recency); candidates: /var/www /srv /opt /home/*/*"
for d in /var/www /srv /opt/bitnami/apps /opt/app /opt /home/*/app /home/*/*; do [ -d "$d" ] && TO ${SUDO:-} find "$d" -maxdepth 3 -type f -newer /etc/hostname -printf '%TY-%Tm-%Td %p\n' 2>/dev/null | sort -r | head -3; done 2>/dev/null | sort -ru | head -8
echo "-- git checkouts and their last commit"; for g in $(TO ${SUDO:-} find /var/www /srv /opt /home -maxdepth 4 -name .git -type d 2>/dev/null | head -8); do echo "$(git -C "${g%/.git}" log -1 --format='%ci %s' 2>/dev/null)  ${g%/.git}"; done

H runtimes; for b in node python3 ruby php java go; do command -v $b >/dev/null && echo "$b: $($b --version 2>&1 | head -1)"; done
echo "### end"
