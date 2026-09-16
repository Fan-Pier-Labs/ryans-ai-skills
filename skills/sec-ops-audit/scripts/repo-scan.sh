#!/usr/bin/env bash
# sec-ops: read-only scan of a git checkout for the code/secret/identity questions (Q1, Q2, Q4, Q5, Q10).
#
#   scripts/repo-scan.sh [--repo <path>] [--out <dir>] [--since YYYY-MM-DD]
#
# Runs from inside the checkout (or --repo). Uses gitleaks / trufflehog when installed for a
# full-history secret scan; otherwise a grep over `git log -p` with VALUES MASKED. Never writes
# to the repo. Output under <out>/repo-scan-<name>/:
#   remotes.txt            where this repo lives (org vs personal account)
#   committers.txt         author emails by domain, commit count, first/last commit  (Q2)
#   blame-by-author.txt    lines in the current tree per author (who wrote what is running)
#   gitleaks.json | trufflehog.json | history-grep.txt   (Q4)
#   tracked-env.txt        .env-shaped files that are tracked
#   personal-deps.txt      git/npm/pip deps fetched from personal accounts or namespaces (Q1)
#   infra-targets.txt      hardcoded public IPs + ssh/rsync/scp deploy targets (Q3: whose server?)
#   submodules.txt, deploy-targets.txt, ci-secret-exposure.txt (Q2/Q5: a person's token as the deploy credential), docs-credentials.txt (Q10)
set -uo pipefail
REPO="."; OUT=""; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
cd "$REPO" || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$REPO is not a git checkout" >&2; exit 2; }
NAME=$(basename "$(git rev-parse --show-toplevel)")
[ -z "$OUT" ] && OUT="./secops-$(date +%Y-%m-%d)"
D="$OUT/repo-scan-$NAME"; mkdir -p "$D"
SINCEARG=(); [ -n "$SINCE" ] && SINCEARG=(--since="$SINCE")
echo "repo=$NAME out=$D"

echo "== remotes =="; { git remote -v; echo; echo "top-level: $(git rev-parse --show-toplevel)"; echo "branch: $(git branch --show-current)"; echo "head: $(git log -1 --format='%h %ci %ae')"; echo "branches: $(git branch -r | wc -l | tr -d ' ') remote"; } > "$D/remotes.txt"
git remote -v | grep -E 'github\.com[:/][^/]+/' | sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#' | sort -u | sed 's/^/  owner on github: /'

echo "== committers =="
COMMITTERS_PY=$(cat <<'PY'
import sys,collections
c=collections.defaultdict(lambda:[0,None,None,set()])
for l in sys.stdin:
    p=l.rstrip("\n").split("|")
    if len(p)<3: continue
    e,n,d=p[0].lower(),p[1],p[2][:10]; r=c[e]; r[0]+=1; r[1]=min(r[1] or d,d); r[2]=max(r[2] or d,d); r[3].add(n)
rows=sorted(c.items(),key=lambda x:-x[1][0])
print("%-42s%-24s%8s  first       last        names" % ("email","domain","commits"))
for e,(n,f,l,names) in rows: print("%-42s%-24s%8d  %s  %s  %s" % (e,e.split("@")[-1],n,f,l,"/".join(sorted(names))[:40]))
print(); print("domains:",", ".join("%s=%d" % (d,n) for d,n in collections.Counter(e.split("@")[-1] for e,_ in rows).most_common()))
PY
)
git log --all --format='%ae|%an|%ci' ${SINCEARG[@]+"${SINCEARG[@]}"} | python3 -c "$COMMITTERS_PY" > "$D/committers.txt"
head -15 "$D/committers.txt" | sed 's/^/  /'

echo "== blame by author (current tree, may take a minute) =="
{ git ls-files | grep -vE '\.(png|jpg|jpeg|gif|svg|ico|woff2?|ttf|pdf|lock|min\.js|min\.css)$|package-lock|yarn\.lock|pnpm-lock|node_modules/|vendor/|dist/|build/' | head -n 3000 \
  | while IFS= read -r f; do git blame --line-porcelain -- "$f" 2>/dev/null | grep -E '^author-mail '; done | sort | uniq -c | sort -rn | head -25; } > "$D/blame-by-author.txt"
head -8 "$D/blame-by-author.txt" | sed 's/^/  /'

echo "== secrets in history =="
if command -v gitleaks >/dev/null; then
  gitleaks detect --source . --no-banner --redact --report-format json --report-path "$D/gitleaks.json" >/dev/null 2>&1
  echo "  gitleaks: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d),"finding(s):",", ".join(sorted({x.get("RuleID","?") for x in d})[:12]))' "$D/gitleaks.json" 2>/dev/null || echo 'no report')"
elif command -v trufflehog >/dev/null; then
  trufflehog git "file://$(pwd)" --json --no-update 2>/dev/null > "$D/trufflehog.json"
  echo "  trufflehog: $(grep -c DetectorName "$D/trufflehog.json") finding(s) (values are in the report — treat the file as sensitive)"
else
  echo "  neither gitleaks nor trufflehog installed (brew install gitleaks) — grep fallback, values masked"
  git log --all -p ${SINCEARG[@]+"${SINCEARG[@]}"} --format='commit %h %ci %ae' 2>/dev/null | python3 -c '
import sys,re
pats={"aws-access-key":r"AKIA[0-9A-Z]{16}","aws-secret":r"(?i)aws_secret_access_key\s*[=:]\s*[A-Za-z0-9/+=]{40}","github-token":r"gh[pousr]_[A-Za-z0-9]{36,}","stripe-live":r"sk_live_[0-9a-zA-Z]{24,}","slack-token":r"xox[baprs]-[0-9A-Za-z-]{10,}","private-key":r"-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----","google-api":r"AIza[0-9A-Za-z_-]{35}","sendgrid":r"SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}","twilio":r"SK[0-9a-f]{32}","db-url":r"(?i)(postgres|mysql|mongodb(\+srv)?|redis)://[^:\s]+:[^@\s]{4,}@","generic":r"(?i)(api[_-]?key|secret|token|password|passwd)\s*[=:]\s*[\"\x27][A-Za-z0-9/+_\-\.]{16,}[\"\x27]"}
commit=None; hits={}
for l in sys.stdin:
    if l.startswith("commit "): commit=l.strip(); continue
    if not l.startswith("+") or l.startswith("+++"): continue
    for k,p in pats.items():
        m=re.search(p,l)
        if m:
            v=m.group(0); masked=v[:6]+"…"+v[-3:] if len(v)>12 else "…"
            hits.setdefault(k,[]).append((commit,masked))
for k,v in hits.items():
    print(f"{k}: {len(v)} added line(s)")
    for c,m in v[:5]: print(f"   {c}  {m}")
if not hits: print("no matches")' > "$D/history-grep.txt"
  head -20 "$D/history-grep.txt" | sed 's/^/  /'
fi

echo "== tracked .env-shaped files =="
git ls-files | grep -E '(^|/)\.env(\.[a-z]+)?$|(^|/)(credentials|secrets?)\.(json|ya?ml|txt)$|\.(pem|p12|pfx|key)$|id_rsa|\.npmrc$|\.pypirc$|\.netrc$' > "$D/tracked-env.txt"; sed 's/^/  /' "$D/tracked-env.txt"; [ -s "$D/tracked-env.txt" ] || echo "  none"

echo "== dependencies from personal accounts / namespaces =="
ORGS=$(git remote -v | grep -oE 'github\.com[:/][^/]+' | sed -E 's#.*[:/]##' | sort -u | tr '\n' '|' | sed 's/|$//')
{ grep -rhoE '(git\+)?(https?|ssh|git)://[^" ]*github\.com/[^/" ]+/[^" #]+|github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' package.json */package.json requirements*.txt pyproject.toml go.mod Gemfile Cargo.toml composer.json .gitmodules 2>/dev/null | sort -u | grep -vE "github\.com[:/](${ORGS:-__none__})/" | sed 's/^/  git-dep outside org: /'
  grep -rhoE '"@[a-z0-9_-]+/[a-z0-9_.-]+"\s*:' package.json */package.json 2>/dev/null | grep -oE '@[a-z0-9_-]+' | sort | uniq -c | sort -rn | head -15 | sed 's/^/  npm scope: /'
  grep -rhoE 'image:\s*[^\s"]+' docker-compose*.yml Dockerfile* .github/workflows/*.yml 2>/dev/null | grep -vE 'image:\s*(node|python|postgres|redis|nginx|alpine|ubuntu|debian|golang|ruby|php|mysql|mongo|amazon|public\.ecr|[0-9]+\.dkr\.ecr)' | sort -u | sed 's/^/  image: /'
  grep -rhoE '^FROM\s+[^\s]+' Dockerfile* */Dockerfile 2>/dev/null | grep -E 'docker\.io/[a-z0-9]+/|^FROM\s+[a-z0-9]+/[a-z0-9_.-]+' | sort -u | sed 's/^/  base image: /'; } > "$D/personal-deps.txt"
sed 's/^/  /' "$D/personal-deps.txt" | head -20; [ -s "$D/personal-deps.txt" ] || echo "  none found"
[ -f .gitmodules ] && grep -E 'url\s*=' .gitmodules > "$D/submodules.txt"

echo "== deploy targets =="
{ for f in render.yaml render.yml fly.toml vercel.json netlify.toml Procfile serverless.yml serverless.yaml app.yaml app.json railway.json railway.toml Dockerfile docker-compose.yml docker-compose.prod.yml cdk.json terraform.tf main.tf amplify.yml; do [ -e "$f" ] && echo "$f"; done
  ls .github/workflows/*.y*ml 2>/dev/null; ls terraform infra infrastructure cdk pulumi 2>/dev/null | sed 's#^#dir: #'
  grep -rhoE '(aws-actions/[a-z-]+|vercel/action|superfly/flyctl-actions|akhileshns/heroku-deploy|render|railway|netlify|appleboy/ssh-action|easingthemes/ssh-deploy|rsync)' .github/workflows 2>/dev/null | sort | uniq -c | sed 's/^/  uses: /'
  grep -rhoE '(role-to-assume|aws-access-key-id|AWS_ACCESS_KEY_ID)\s*:' .github/workflows 2>/dev/null | sort | uniq -c | sed 's/^/  aws auth in CI: /'; } > "$D/deploy-targets.txt"
sed 's/^/  /' "$D/deploy-targets.txt"

echo "== CI secrets that may be a person's token (Q2/Q5) =="
{ grep -lE 'pull_request_target' .github/workflows/*.y*ml 2>/dev/null | sed 's/^/  pull_request_target: /'
  for f in .github/workflows/*.y*ml; do [ -f "$f" ] || continue; grep -qE '^\s*pull_request:' "$f" && grep -qE 'secrets\.' "$f" && echo "  pull_request + secrets.* in $f (fork PRs get no secrets, but check the trigger)"; done
  grep -rhoE 'secrets\.[A-Z0-9_]+' .github/workflows 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo "  (secret names ending in _PAT/_TOKEN or containing a person's name are the candidates: they stop working, or keep working, when that person leaves)"; } > "$D/ci-secret-exposure.txt"
sed 's/^/  /' "$D/ci-secret-exposure.txt" | head -25

echo "== hardcoded IPs and ssh/rsync/scp deploy targets (Q3: whose server is that?) =="
{ git grep -hoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -- . ':!*.lock' ':!package-lock.json' ':!yarn.lock' ':!*.min.js' ':!*.svg' ':!*.map' ':!*test*' 2>/dev/null | grep -vE '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|255\.|224\.|8\.8\.8\.8|1\.1\.1\.1|[0-9]+\.[0-9]+\.[0-9]+\.0$)' | sort | uniq -c | sort -rn | head -20 | sed 's/^/  public ip literal: /'
  git grep -nE '^\s*(-\s*)?(run:\s*)?(ssh|scp|rsync|sftp)\s+(-[a-zA-Z]+\s+)*([a-z0-9_.-]+@)?[a-z0-9.-]+(\.[a-z]{2,}|:[0-9]+)|DEPLOY_HOST|SSH_HOST|REMOTE_HOST|ansible_host|appleboy/ssh-action|easingthemes/ssh-deploy|ssh-deploy|pm2 deploy|capistrano|^\s*host:\s*[a-z0-9.-]+\.[a-z]{2,}' -- .github Makefile* '*.sh' scripts deploy* bin ansible* .circleci .gitlab-ci.yml Procfile ecosystem.config.* 2>/dev/null | grep -vE '^\S+:\s*#|localhost|127\.0\.0\.1|example\.com|git@' | head -25 | sed 's/^/  deploy target: /'
  echo "  (a deploy target that is an IP, a hostname outside the company domain, or a host on a provider with no account in the inventory = backend running on someone's server)"; } > "$D/infra-targets.txt"
sed 's/^/  /' "$D/infra-targets.txt" | head -20

echo "== credentials in docs/READMEs (Q10) =="
grep -rniE '(password|passwd|api[_ -]?key|secret|token)\s*[:=]\s*[A-Za-z0-9/+_\-]{8,}|\.pem\b.*(drive|slack|download|dropbox|share)|(drive|slack|download|dropbox|share).*\.pem\b' --include='*.md' --include='*.txt' --include='*.rst' . 2>/dev/null | grep -vE 'node_modules|CHANGELOG|LICENSE|example|placeholder|<your|xxx|\$\{|=<masked>|\[A-Z' | sed -E 's/([:=]\s*)[A-Za-z0-9/+_-]{8,}/\1<masked>/' | head -30 > "$D/docs-credentials.txt"
sed 's/^/  /' "$D/docs-credentials.txt"; [ -s "$D/docs-credentials.txt" ] || echo "  none"
echo "done → $D"
