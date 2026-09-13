# The append-only CloudTrail requirement

Every audited account must have a CloudTrail whose logs **cannot be altered or deleted by
anyone in the account, including root, for a fixed retention period**. This is the one control
that turns "we think nobody touched prod" into evidence. Without it, an attacker with admin
credentials (or an engineer covering a mistake) deletes the log bucket and the incident never
happened. `scripts/aws-audit-inventory.sh` evaluates every rule below and prints a PASS/FAIL
table in `DIGEST.md`; this file is the rationale and the fix.

## Reference implementation

This is the shape to match, taken from a real account that passes every rule below (verified
2026-09-07 with the commands in §3).

| Component | Setting |
|---|---|
| Trail | `<company>-management-trail`, one home region, **multi-region**, **global service events on**, management events read+write, **log file validation on**, logging continuously since creation, digests delivering |
| Bucket | `<company>-cloudtrail-immutable` |
| Object Lock | **Enabled, default retention COMPLIANCE, 2 years** — every delivered object gets `RetainUntilDate = delivery + 2y`; not even root can shorten or delete before then |
| Versioning | Enabled (required by Object Lock) |
| Public access block | all four on |
| Bucket policy | `cloudtrail.amazonaws.com` may `GetBucketAcl` and `PutObject` under `AWSLogs/<account>/*` only with `aws:SourceAccount = <account>` and `bucket-owner-full-control`; **explicit Deny for `s3:DeleteBucket` and `s3:DeleteBucketPolicy` to `*`** |
| Encryption | SSE-S3 (AES256), SSE-C blocked |
| Not present (recommendations) | KMS key, lifecycle expiry after 2y, alarm on `StopLogging`/`DeleteTrail`, separate log-archive account |

## 1. Required rules (any FAIL = the account does not have an append-only trail)

| # | Rule | Why |
|---|---|---|
| R1 | A trail exists and `IsLogging` is true | Event History alone is 90 days and not exportable in bulk. |
| R2 | Delivered within the last 24 h | A trail pointing at a bucket whose policy was changed silently stops delivering; status shows it. |
| R3 | Multi-region | Single-region trails miss the region the attacker chose. |
| R4 | Global service events included | IAM, STS and CloudFront events are "global"; without this the credential-related events are missing. |
| R5 | Management events, read **and** write | Read-only events are how you see reconnaissance (`ListBuckets`, `GetSecretValue`). Write-only is a common cost-saving misconfiguration. |
| R6 | Log file validation enabled | Hourly SHA-256 digest chain, signed by CloudTrail. It is the only way to *prove* a log file was not modified; `aws cloudtrail validate-logs` checks it. |
| R7 | Bucket has **S3 Object Lock enabled** | Object Lock can only be turned on at bucket creation (or by AWS support on an existing bucket). It is the mechanism that makes "append-only" true rather than aspirational. |
| R8 | Default retention **COMPLIANCE** mode, ≥ 1 year | GOVERNANCE mode can be bypassed by anyone with `s3:BypassGovernanceRetention`, which every admin has. COMPLIANCE cannot be bypassed by root. One year is the floor because incidents are typically discovered months later. |
| R9 | A real log object carries a COMPLIANCE retention | A bucket can have Object Lock enabled with *no* default rule; the sample object check catches that. |
| R10 | Versioning enabled | Object Lock requires it; a delete becomes a delete marker with the locked version underneath. |
| R11 | All four public-access blocks | Logs contain ARNs, IPs, user names, and occasionally request parameters. |
| R12 | Bucket policy denies `s3:DeleteBucket` and `s3:DeleteBucketPolicy` to `*` | A locked object still lives in a bucket; you cannot delete a bucket with locked objects, but the explicit deny stops the policy itself from being loosened in one step. |
| R13 | Only the CloudTrail service may write, conditioned on `aws:SourceAccount` | Without the condition, a trail in *another* account can write into your bucket (confused deputy); without the restriction, anyone with `PutObject` can plant fake events. |
| R14 | Default encryption on the bucket | SSE-S3 is the floor. |

## 2. Recommended (WARN, not FAIL)

- **KMS CMK** for the logs with a key policy that only CloudTrail can encrypt with and only the
  security role can decrypt with. SSE-S3 means anyone with `s3:GetObject` reads them.
- **Lifecycle rule** expiring objects *after* the retention window. Object Lock prevents early
  deletion; nothing prevents infinite growth. ~$0.023/GB-month on Standard adds up over years;
  a transition to Glacier Instant Retrieval at 90 days is the cost-conscious version.
- **Alerting on tampering**: an EventBridge rule (or a CloudWatch Logs metric filter if the
  trail also ships to CloudWatch) on `StopLogging`, `DeleteTrail`, `UpdateTrail`,
  `PutEventSelectors`, `PutBucketPolicy`, `PutBucketLifecycle`, `DeleteBucketPolicy`,
  `PutObjectLockConfiguration` → SNS → a human. The lock protects what has been written; the
  alert is what tells you the trail was turned off *going forward*.
- **Organization trail into a separate log-archive account.** In a single account, an admin can
  `StopLogging`. The locked bucket still holds everything up to that moment, and the stop event
  itself is logged — but the *stream* is not protected. Delivery to an account where prod admins
  have no rights is the full answer. Correct to recommend for any company past ~5 engineers;
  overkill for a one-person startup, and say so.
- **Data events** for the buckets holding customer data (S3 `GetObject`/`PutObject`) and for
  DynamoDB tables with PII. Priced per event; only for the sensitive ones.

## 3. How to check by hand (all read-only)

```bash
P=<profile>; R=<home region of the trail>
aws --profile $P --region $R cloudtrail describe-trails
aws --profile $P --region $R cloudtrail get-trail-status --name <trail arn>
aws --profile $P --region $R cloudtrail get-event-selectors --trail-name <trail arn>
B=<S3BucketName>
aws --profile $P s3api get-object-lock-configuration --bucket $B     # ObjectLockEnabled + Rule.DefaultRetention.Mode
aws --profile $P s3api get-bucket-versioning --bucket $B
aws --profile $P s3api get-public-access-block --bucket $B
aws --profile $P s3api get-bucket-policy --bucket $B --query Policy --output text | python3 -m json.tool
aws --profile $P s3api get-bucket-encryption --bucket $B
aws --profile $P s3api get-bucket-lifecycle-configuration --bucket $B
K=$(aws --profile $P s3api list-objects-v2 --bucket $B --prefix AWSLogs/<account>/CloudTrail/ --max-keys 1 --query 'Contents[0].Key' --output text)
aws --profile $P s3api get-object-retention --bucket $B --key "$K"    # Mode=COMPLIANCE, RetainUntilDate
aws --profile $P --region $R events list-rules                        # anything on cloudtrail events?
```

To *prove* integrity for a window (slow, but the definitive answer if someone asks):
`aws cloudtrail validate-logs --trail-arn <arn> --start-time <ISO> --profile $P --region $R`.

## 4. The fix, when it fails

This is a create-new-bucket operation because Object Lock cannot be enabled on an existing
bucket without a support case. Recommend it in the report; run it only when the user asks,
and confirm the retention period explicitly first — **COMPLIANCE mode is irrevocable: the
storage bill for those objects is committed for the whole period, and a typo of `Years=20` is
20 years.**

```bash
P=<profile>; R=<region>; ACCT=$(aws --profile $P sts get-caller-identity --query Account --output text)
B=<company>-cloudtrail-immutable

# 1. bucket with Object Lock (must be at creation), versioning comes with it
aws --profile $P --region $R s3api create-bucket --bucket $B --object-lock-enabled-for-bucket \
  $( [ "$R" != us-east-1 ] && echo --create-bucket-configuration LocationConstraint=$R )
aws --profile $P s3api put-object-lock-configuration --bucket $B \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Years":2}}}'
aws --profile $P s3api put-public-access-block --bucket $B \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws --profile $P s3api put-bucket-encryption --bucket $B \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 2. bucket policy: CloudTrail writes, nobody deletes the bucket or the policy
cat > /tmp/ct-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::$B","Condition":{"StringEquals":{"aws:SourceAccount":"$ACCT"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::$B/AWSLogs/$ACCT/*",
  "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCT","s3:x-amz-acl":"bucket-owner-full-control"}}},
 {"Sid":"DenyDeleteActions","Effect":"Deny","Principal":"*",
  "Action":["s3:DeleteBucket","s3:DeleteBucketPolicy"],"Resource":"arn:aws:s3:::$B"}]}
EOF
aws --profile $P s3api put-bucket-policy --bucket $B --policy file:///tmp/ct-policy.json

# 3. the trail
aws --profile $P --region $R cloudtrail create-trail --name <company>-management-trail --s3-bucket-name $B \
  --is-multi-region-trail --include-global-service-events --enable-log-file-validation
aws --profile $P --region $R cloudtrail put-event-selectors --trail-name <company>-management-trail \
  --event-selectors '[{"ReadWriteType":"All","IncludeManagementEvents":true}]'
aws --profile $P --region $R cloudtrail start-logging --name <company>-management-trail

# 4. (recommended) alert when someone touches it
aws --profile $P --region $R sns create-topic --name security-alerts   # then subscribe an email
aws --profile $P --region $R events put-rule --name cloudtrail-tamper --event-pattern \
  '{"source":["aws.cloudtrail","aws.s3"],"detail":{"eventName":["StopLogging","DeleteTrail","UpdateTrail","PutEventSelectors","PutBucketPolicy","DeleteBucketPolicy","PutBucketLifecycle","PutObjectLockConfiguration"]}}'
aws --profile $P --region $R events put-targets --rule cloudtrail-tamper --targets Id=sns,Arn=<topic arn>
```

If a trail already exists but its bucket fails R7/R8: create the locked bucket as above and
`update-trail --s3-bucket-name`; leave the old bucket in place (its history is still evidence,
just not protected) and note the cutover date in the report. Re-run the inventory afterwards
and paste the PASS table — the fix is not done until R9 passes on a *newly delivered* object.

## 5. Rationalizations to catch yourself in

| Thought | Reality |
|---|---|
| "CloudTrail is on, we're covered." | Event History is 90 days and deletable by turning off the trail. On ≠ append-only. |
| "The bucket has versioning and MFA delete." | MFA delete protects against one path. Object Lock COMPLIANCE protects against all of them including root. |
| "GOVERNANCE mode is fine, only admins can bypass." | Admins are exactly who you are protecting the logs from (compromised admin creds are the common case). |
| "We'll just deny `s3:DeleteObject` in the bucket policy." | Whoever can edit the bucket policy removes the deny first. Lock is enforced by S3 below the policy layer. |
| "Retention of 10 years to be safe." | That is a 10-year committed storage bill on every byte. 1–2 years, plus a lifecycle transition to Glacier, is the sane default; go longer only for a regulatory reason you can name. |
| "It's a one-person startup, this is overkill." | The locked bucket costs cents a month and ten minutes. The org-trail / separate-account step is the part that is overkill at that size — recommend the bucket, defer the account. |
